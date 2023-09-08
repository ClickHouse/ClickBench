package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"time"
)

func reportCmd() command {
	fs := flag.NewFlagSet("report", flag.ExitOnError)
	typ := fs.String("type", "clickbench-json", "Report type to generate [clickbench-json]")

	return command{fs, func(args []string) error {
		fs.Parse(args)
		return report(*typ)
	}}
}

func report(typ string) error {
	switch typ {
	case "clickbench-json":
		return reportClickbenchJSON(os.Stdin)
	default:
		return fmt.Errorf("unknown report type: %s", typ)
	}
}

type ClickBenchReport struct {
	System      string       `json:"system"`
	Date        string       `json:"date"`
	Machine     string       `json:"machine"`
	ClusterSize string       `json:"cluster_size"`
	Comment     string       `json:"comment"`
	Tags        []string     `json:"tags"`
	LoadTime    *int         `json:"load_time"`
	DataSize    *int64       `json:"data_size"`
	Result      [][3]latency `json:"result"`
}

type latency float64

func (n latency) MarshalJSON() ([]byte, error) {
	if n == 0.0 {
		return []byte("null"), nil
	}
	return []byte(strconv.FormatFloat(float64(n), 'f', 3, 64)), nil
}

func reportClickbenchJSON(input io.Reader) error {
	minDate := time.Now().Add(100 * 24 * time.Hour)
	results := make(map[int][]QueryResult)
	sc := bufio.NewScanner(input)

	for sc.Scan() {
		var result QueryResult
		if err := json.Unmarshal(sc.Bytes(), &result); err != nil {
			return fmt.Errorf("error unmarshaling query result: %w", err)
		}

		if result.Time.Before(minDate) {
			minDate = result.Time
		}

		results[result.ID] = append(results[result.ID], result)
	}

	rep := ClickBenchReport{
		System:      "Axiom",
		Date:        minDate.Format("2006-01-02"),
		Machine:     "serverless",
		ClusterSize: "serverless",
		Tags:        []string{"managed", "column-oriented", "serverless", "time-series"},
		LoadTime:    nil, // TODO(tsenart)
		DataSize:    nil, // TODO(tsenart)
		Result:      make([][3]latency, len(results)),
	}

	for id, qr := range results {
		sort.Slice(qr, func(i, j int) bool {
			if qr[i].Time.Equal(qr[j].Time) {
				return qr[i].ID < qr[j].ID
			}
			return qr[i].Time.Before(qr[j].Time)
		})

		for i, r := range qr {
			if r.Error == "" {
				rep.Result[id-1][i] = latency(r.LatencySeconds)
			}
		}
	}

	return json.NewEncoder(os.Stdout).Encode(rep)
}
