package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path"
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
	version := fs.String("version", firstNonZero(gitSha(), "dev"), "Version of the benchmarking client code")

	return command{fs, func(args []string) error {
		fs.Parse(args)
		return run(*version, *apiURL, *traceURL, *org, *token, *iters, *failfast)
	}}
}

func run(version, apiURL, traceURL, org, token string, iters int, failfast bool) error {
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
		if err := benchmark(ctx, cli, id, sc.Text(), iters, enc); err != nil {
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

func benchmark(ctx context.Context, cli *axiomClient, id int, query string, iters int, enc *json.Encoder) error {
	for i := 1; i <= iters; i++ {
		result, err := cli.Query(ctx, id, query)
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
	// Version is the git sha of the benchmarking client code
	Version string `json:"version"`
	// TraceID is the trace ID of the query request
	TraceID string `json:"trace_id"`
	// TraceURL is the URL to the trace in Axiom
	TraceURL string `json:"trace_url"`
	// Result is the query result
	Result *query.Result `json:"result"`
	// Error is the error if the query failed
	Error string `json:"error"`
}

func (c *axiomClient) Query(ctx context.Context, id int, aplQuery string) (*QueryResult, error) {
	uri := *c.apiURL
	uri.Path = path.Join(uri.Path, "v1/datasets/_apl")
	uri.RawQuery = "nocache=true&format=legacy"

	type aplQueryRequest struct {
		APL string `json:"apl"`
	}

	var body bytes.Buffer
	if err := json.NewEncoder(&body).Encode(aplQueryRequest{APL: aplQuery}); err != nil {
		return nil, fmt.Errorf("error encoding request body: %w", err)
	}

	rawURL := uri.String()
	req, err := http.NewRequestWithContext(ctx, "POST", rawURL, &body)
	if err != nil {
		return nil, fmt.Errorf("error creating request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "axiom-clickbench/"+c.version)
	req.Header.Set("X-Axiom-Org-Id", c.org)

	began := time.Now().UTC()
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("error executing request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("error reading response body: %w", err)
	}

	latency := time.Since(began)
	traceID := resp.Header.Get("x-axiom-trace-id")

	result := &QueryResult{
		Query:          aplQuery,
		ID:             id,
		URL:            rawURL,
		Time:           began,
		LatencyNanos:   latency,
		LatencySeconds: latency.Seconds(),
		// TODO(tsenart): Figure out how to fill this in.
		ServerVersions: map[string]string{},
		Version:        c.version,
		TraceID:        traceID,
		TraceURL:       c.buildTraceURL(began, traceID),
	}

	if resp.StatusCode != http.StatusOK {
		result.Error = fmt.Sprintf("HTTP %d: %s", resp.StatusCode, respBody)
		return result, nil
	}

	result.Result = &query.Result{}
	if err := json.Unmarshal(respBody, result.Result); err != nil {
		return nil, fmt.Errorf("error decoding response: %w", err)
	}

	return result, nil
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
