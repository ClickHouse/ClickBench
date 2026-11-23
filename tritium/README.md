# tritium

tritium is a query engine, a personal research project: SQL is planned into physical operators, which are compiled
to machine code (x86-64, AArch64) for each query. The source is not public; the binaries are released at
https://github.com/xmaton/tritium-release under a license that allows benchmarking and publishing the results.

## How it runs here

- `install` downloads the release binary for the machine's architecture and checks it against the SHA-256 pinned in
  the script.
- `start` runs `tritium --serve 8000` over the directory: `hits.parquet` is read in place as the table `hits`, nothing
  is loaded or converted. `tables.sql` declares the types the file does not carry: `EventDate` (days) as a date and
  `EventTime` (seconds) as a timestamp.
- `query` sends a query over HTTP and reports curl's time from sending it to the last row received.
- The server is restarted and the caches dropped before each query's first run (true cold runs), and the concurrent
  test runs against the one server.
