package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

// serverVersionsCmd enriches incoming events with the server versions found
// in their traces (from trace_id), which we query. This is done separate from
// run so that we can wait for a while until traces have been flushed and propagated, as
// well as to avoid slowing down the run command.
func serverVersionsCmd() command {
	fs := flag.NewFlagSet("server-versions", flag.ExitOnError)

	apiURL := fs.String(
		"api-url",
		firstNonZero(os.Getenv("AXIOM_URL"), "https://api.axiom.co/"),
		"Axiom API base URL [defaults to $AXIOM_URL when set]",
	)
	traceURL := fs.String("trace-url", "", "Axiom trace URL where traceId query argument will be added")
	org := fs.String("org", os.Getenv("AXIOM_ORG_ID"), "Axiom organization [defaults to $AXIOM_ORG_ID]")
	token := fs.String("token", os.Getenv("AXIOM_TOKEN"), "Axiom auth token [defaults to $AXIOM_TOKEN]")
	failfast := fs.Bool("failfast", false, "Exit on first error")

	return command{fs, func(args []string) error {
		fs.Parse(args)
		return serverVersions(*apiURL, *traceURL, *org, *token, *failfast)
	}}
}

func serverVersions(apiURL, traceURL, org, token string, failfast bool) error {
	if apiURL == "" {
		return fmt.Errorf("api-url cannot be empty")
	}

	if token == "" {
		return fmt.Errorf("token cannot be empty")
	}

	cli, err := newAxiomClient(http.DefaultClient, gitSha(), apiURL, org, token, traceURL)
	if err != nil {
		return fmt.Errorf("error creating axiom client: %w", err)
	}

	var (
		sc       = bufio.NewScanner(os.Stdin)
		ctx      = context.Background()
		results  []*QueryResult
		traceIDs []string
		earliest time.Time
	)

	for sc.Scan() {
		var r QueryResult
		if err := json.Unmarshal(sc.Bytes(), &r); err != nil {
			if failfast {
				return err
			}

			log.Printf("error: %v", err)
			continue
		}

		if earliest.IsZero() || r.Time.Before(earliest) {
			earliest = r.Time
		}

		if r.TraceID != "" {
			traceIDs = append(traceIDs, r.TraceID)
			results = append(results, &r)
		}
	}

	versions, err := cli.ServerVersions(ctx, earliest.Add(-30*time.Second), traceIDs)
	if err != nil {
		return fmt.Errorf("error getting server versions: %w", err)
	}

	var (
		buf bytes.Buffer
		enc = json.NewEncoder(os.Stdout)
	)

	for _, r := range results {
		buf.Reset()

		r.ServerVersions = versions[r.TraceID]
		for name, version := range r.ServerVersions {
			buf.WriteString(name + "=" + version + ",")
		}

		if buf.Len() > 0 {
			buf.Truncate(buf.Len() - 1)
		}

		r.ServerVersion = buf.String()

		if err := enc.Encode(r); err != nil {
			return err
		}
	}

	return nil
}
