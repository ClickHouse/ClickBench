package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/axiomhq/axiom-go/axiom/query"
)

func runCmd() command {
	fs := flag.NewFlagSet("run", flag.ExitOnError)

	apiURL := fs.String(
		"api-url",
		firstNonZero(os.Getenv("AXIOM_URL"), "https://api.axiom.co/"),
		"Axiom API base URL [defaults to $AXIOM_URL when set]",
	)
	traceURL := fs.String("trace-url", "", "Axiom trace URL where traceId query argument will be added")
	org := fs.String("org", os.Getenv("AXIOM_ORG_ID"), "Axiom organization [defaults to $AXIOM_ORG_ID]")
	token := fs.String("token", os.Getenv("AXIOM_TOKEN"), "Axiom auth token [defaults to $AXIOM_TOKEN]")
	iters := fs.Int("iters", 3, "Number of iterations to run each query")
	failfast := fs.Bool("failfast", false, "Exit on first error")
	noCache := fs.Bool("no-cache", true, "Do not use axiom results caching")
	version := fs.String("version", firstNonZero(gitSha(), "dev"), "Version of the benchmarking client code")

	return command{fs, func(args []string) error {
		fs.Parse(args)
		return run(*version, *apiURL, *traceURL, *org, *token, *iters, *failfast, *noCache)
	}}
}

func run(version, apiURL, traceURL, org, token string, iters int, failfast, noCache bool) error {
	if apiURL == "" {
		return fmt.Errorf("api-url cannot be empty")
	}

	if token == "" {
		return fmt.Errorf("token cannot be empty")
	}

	if iters <= 0 {
		return fmt.Errorf("iters must be greater than 0")
	}

	cli, err := newAxiomClient(http.DefaultClient, version, apiURL, org, token, traceURL)
	if err != nil {
		return fmt.Errorf("error creating axiom client: %w", err)
	}

	var (
		sc  = bufio.NewScanner(os.Stdin)
		ctx = context.Background()
		enc = json.NewEncoder(os.Stdout)
		id  = 0
	)

	for sc.Scan() {
		if err := benchmark(ctx, cli, id, sc.Text(), iters, noCache, enc); err != nil {
			if failfast {
				return err
			}
			log.Printf("benchmark error: %v", err)
		}
		id++
	}

	return nil
}

func gitSha() string {
	sha, err := exec.Command("git", "rev-parse", "--short", "HEAD").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(sha))
}

func benchmark(ctx context.Context, cli *axiomClient, id int, query string, iters int, noCache bool, enc *json.Encoder) error {
	for i := 1; i <= iters; i++ {
		result, err := cli.Query(ctx, id, query, noCache)
		if err != nil {
			return fmt.Errorf("failed query #%d, iter %d: %w", id, i, err)
		}

		if err = enc.Encode(result); err != nil {
			return fmt.Errorf("failed to encode result of query #%d, iter %d: %w", id, i, err)
		}

		// We want to encode out results with errors, but still return early if there was
		// one.
		if result.Error != "" {
			return fmt.Errorf("failed query #%d, iter %d: %s", id, i, result.Error)
		}
	}

	return nil
}

type axiomClient struct {
	cli      *http.Client
	apiURL   *url.URL
	traceURL *url.URL
	version  string
	token    string
	org      string
}

func newAxiomClient(cli *http.Client, version, apiURL, org, token, traceURL string) (*axiomClient, error) {
	parsedTraceURL, err := url.Parse(traceURL)
	if err != nil && traceURL != "" {
		return nil, fmt.Errorf("error parsing trace url: %w", err)
	}

	parsedAPIURL, err := url.Parse(apiURL)
	if err != nil {
		return nil, fmt.Errorf("error parsing url: %w", err)
	}

	return &axiomClient{
		cli:      cli,
		apiURL:   parsedAPIURL,
		traceURL: parsedTraceURL,
		version:  version,
		token:    token,
		org:      org,
	}, nil
}

type QueryResult struct {
	// Query is the APL query submitted
	Query string `json:"query"`
	// ID is the clickbench query number [1-43]
	ID int `json:"id"`
	// URL of the query request. May include query arguments like nocache=true
	URL string `json:"url"`
	// Time is the time the query was submitted
	Time time.Time `json:"_time"`
	// LatencyNanos is the total latency of the query in nanoseconds, including network round-trips.
	LatencyNanos time.Duration `json:"latency_nanos"`
	// LatencySeconds is the total latency of the query in seconds, including network round-trips.
	LatencySeconds float64 `json:"latency_seconds"`
	// ServerVersions is a dictionary of service name to git sha that was under test
	ServerVersions map[string]string `json:"server_versions"`
	// ServerVersion is a concatenation all the ServerVersions map entries in a stable order
	ServerVersion string `json:"server_version"`
	// Version is the git sha of the benchmarking client code
	Version string `json:"version"`
	// TraceID is the trace ID of the query request
	TraceID string `json:"trace_id"`
	// TraceURL is the URL to the trace in Axiom
	TraceURL string `json:"trace_url"`
	// Status of the query result
	Status query.Status `json:"status"`
	// Columns is the list of columns returned by the query
	Columns [][]any `json:"columns"`
	// Error is the error if the query failed
	Error string `json:"error"`
}

type httpError struct {
	code int
	msg  string
}

func (e httpError) Error() string {
	return fmt.Sprintf("HTTP %d: %s", e.code, e.msg)
}

func (c *axiomClient) do(ctx context.Context, rawURL string, id int, body, v any) (*http.Response, error) {
	var bodyBytes bytes.Buffer
	if err := json.NewEncoder(&bodyBytes).Encode(body); err != nil {
		return nil, fmt.Errorf("error encoding request body: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", rawURL, &bodyBytes)
	if err != nil {
		return nil, fmt.Errorf("error creating request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "axiom-clickbench/"+c.version)
	req.Header.Set("X-Axiom-Org-Id", c.org)

	if id >= 0 {
		req.Header.Set("X-Axiom-Trace-Label", fmt.Sprintf("clickbench-%d", id))
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("error executing request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp, fmt.Errorf("error reading response body: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return resp, &httpError{code: resp.StatusCode, msg: string(respBody)}
	}

	if err := json.Unmarshal(respBody, v); err != nil {
		return resp, fmt.Errorf("error decoding response: %w", err)
	}

	return resp, nil
}

func (c *axiomClient) query(ctx context.Context, id int, aplQuery string, noCache bool) (*aplQueryResponse, *http.Response, error) {
	uri := *c.apiURL
	uri.Path = path.Join(uri.Path, "v1/datasets/_apl")
	uri.RawQuery = fmt.Sprintf("nocache=%t&format=legacy", noCache)

	body := struct {
		APL string `json:"apl"`
	}{
		APL: aplQuery,
	}

	var r aplQueryResponse
	resp, err := c.do(ctx, uri.String(), id, body, &r)
	if err != nil {
		return nil, resp, err
	}

	return &r, resp, nil
}

func (c *axiomClient) Query(ctx context.Context, id int, aplQuery string, noCache bool) (*QueryResult, error) {
	began := time.Now().UTC()

	result := &QueryResult{
		Query:   aplQuery,
		ID:      id,
		Time:    began,
		Version: c.version,
	}

	var httpErr *httpError
	r, httpResp, err := c.query(ctx, id, aplQuery, noCache)
	if err != nil && !errors.As(err, &httpErr) {
		return nil, err
	}

	result.LatencyNanos = time.Since(began)
	result.LatencySeconds = result.LatencyNanos.Seconds()

	if httpResp != nil {
		result.URL = httpResp.Request.URL.String()
		result.TraceID = httpResp.Header.Get("X-Axiom-Trace-Id")
		result.TraceURL = c.buildTraceURL(began, result.TraceID)
	}

	if r != nil {
		result.Status = r.Status
		result.Columns = columns(r)
	}

	if httpErr != nil {
		result.Error = httpErr.Error()
	}

	return result, nil
}

func (c *axiomClient) ServerVersions(ctx context.Context, began time.Time, traceIDs []string) (map[string]map[string]string, error) {
	traceDataset := c.traceURL.Query().Get("traceDataset")
	if traceDataset == "" {
		return nil, nil
	}

	from := began.Add(-30 * time.Second).Format(time.RFC3339Nano)

	var buf bytes.Buffer
	for _, traceID := range traceIDs {
		buf.WriteString(`"` + traceID + `",`)
	}

	if buf.Len() > 0 {
		buf.Truncate(buf.Len() - 1)
	}

	aplQuery := fmt.Sprintf(`
    ['%s']
    | where trace_id in (%s) and _time >= datetime('%s')
    | distinct trace_id, ['service.name'], ['service.version']
  `, traceDataset, buf.String(), from)

	var cols [][]any
	r, _, err := c.query(ctx, -1, aplQuery, true)
	if err != nil {
		return nil, err
	}

	cols = columns(r)
	if len(cols) != 4 {
		return nil, fmt.Errorf("server versions not found")
	}

	// traceID -> serverName -> serverVersion
	serverVersions := make(map[string]map[string]string, len(cols[0]))
	for i, name := range cols[1] {
		traceID := cols[0][i].(string)
		versions := serverVersions[traceID]
		if versions == nil {
			versions = make(map[string]string)
			serverVersions[traceID] = versions
		}
		versions[name.(string)] = cols[2][i].(string)
	}

	return serverVersions, nil
}

type aplLegacyQueryRequest struct {
	GroupBy []string `json:"groupBy"`
}

type aplQueryResponse struct {
	query.Result
	Request aplLegacyQueryRequest `json:"request"`
}

func columns(r *aplQueryResponse) [][]any {
	colMap := make(map[string][]any)
	colTypes := map[string]func(any) any{}
	var colNames []string

	add := func(name string, values ...any) {
		if _, ok := colMap[name]; !ok {
			colNames = append(colNames, name)
		}

		colType := colTypes[name]
		for _, v := range values {
			if colType == nil {
				// Ensure JSON encoding matches that of Clickhouse --format=JSONCompactColumns
				// so that we can diff the results of the two.
				switch n := v.(type) {
				case float64:
					if n != math.Trunc(n) {
						// n is a float number with decimal places
						colType = func(v any) any { return strconv.FormatFloat(v.(float64), 'f', 13, 64) }
					} else {
						colType = func(v any) any { return strconv.FormatInt(int64(v.(float64)), 10) }
					}
				default:
					colType = func(v any) any { return v }
				}

				colTypes[name] = colType
			}

			colMap[name] = append(colMap[name], colType(v))
		}
	}

	for _, match := range r.Matches {
		for colName, values := range match.Data {
			add(colName, values)
		}
	}

	for _, total := range r.Buckets.Totals {
		if len(total.Group) > 0 {
			// Order matters, but total.Group is a map, so get the keys
			// from r.GroupBy and use them to index into total.Group.
			if len(r.Request.GroupBy) != len(total.Group) {
				panic(fmt.Sprintf("GroupBy: %v, total.Group: %v", r.Request.GroupBy, total.Group))
			}

			for _, name := range r.Request.GroupBy {
				add(name, total.Group[name])
			}
		}

		for _, agg := range total.Aggregations {
			add(agg.Alias, agg.Value)
		}
	}

	cols := make([][]any, len(colNames))
	for i, name := range colNames {
		cols[i] = colMap[name]
	}

	return cols
}

func (c *axiomClient) buildTraceURL(timestamp time.Time, traceID string) string {
	if c.traceURL == nil {
		return ""
	}

	uri := *c.traceURL
	qs := uri.Query()
	qs.Set("traceId", traceID)
	qs.Set("traceStart", timestamp.Format(time.RFC3339Nano))
	uri.RawQuery = qs.Encode()

	return uri.String()
}

func firstNonZero[T comparable](vs ...T) T {
	var zero T
	for _, v := range vs {
		if v != zero {
			return v
		}
	}
	return zero
}
