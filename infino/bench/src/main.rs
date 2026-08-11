//! ClickBench harness for infino (Rust binding).
//!
//! infino is run as a persistent server, the same way ClickBench measures
//! daemon engines (ClickHouse, Postgres): `./start` launches `serve`, which
//! opens the table once and holds it warm; each `./query` is a thin client
//! that sends one SQL statement to the running server over a unix socket. The
//! shared ClickBench driver restarts the server before each query's cold try
//! (`BENCH_RESTARTABLE=yes`), so try 1 is cold and tries 2/3 hit the warm
//! server. Timing is taken inside the server around `query_sql` only, so the
//! socket round-trip is never counted.
//!
//! Subcommands:
//!   load   — ingest parquet (glob INFINO_SRC) into a persisted infino table.
//!   serve  — open the table once and answer queries on a unix socket (daemon).
//!   query  — client: read one SQL statement from stdin, send to the server,
//!            print row count to stdout and elapsed seconds to stderr.
//!   check  — client: ping the running server (used to detect up/down).
//!
//! Env: INFINO_URI (default ./data), INFINO_SRC (default hits.parquet),
//!      INFINO_MAX_ROWS (0 = all), INFINO_STORAGE_* (storage_options),
//!      INFINO_CACHE_DIR, INFINO_SOCK (default ./infino.sock).

use std::env;
use std::error::Error;
use std::fs::File;
use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use arrow::compute::cast;
use arrow_array::RecordBatch;
use arrow_schema::{DataType, Field, Schema, SchemaRef};
use parquet::arrow::arrow_reader::ParquetRecordBatchReaderBuilder;

use infino::{
    connect_with, CompactionSettings, ConnectOptions, Consistency, IndexSpec, OptimizeOptions,
};

type R<T> = Result<T, Box<dyn Error>>;

const BATCH_ROWS: usize = 1_000_000;

fn uri() -> String {
    env::var("INFINO_URI").unwrap_or_else(|_| "./data".to_string())
}

fn sock_path() -> String {
    env::var("INFINO_SOCK").unwrap_or_else(|_| "./infino.sock".to_string())
}

fn open() -> R<infino::Connection> {
    // Strong read consistency. infino 0.5 changed the default from strong to
    // BoundedStaleness(1s). ClickBench needs exact results, so pin strong everywhere.
    let mut opts = ConnectOptions::new().with_read_consistency(Consistency::Strong);

    for (k, v) in env::vars() {
        if let Some(key) = k.strip_prefix("INFINO_STORAGE_") {
            opts = opts.with_storage_option(key.to_lowercase(), v);
        }
    }
    if let Ok(dir) = env::var("INFINO_CACHE_DIR") {
        opts = opts.with_cache_dir(dir);
    }

    // Raise the disk-cache budget above the default so a large corpus (e.g.
    // 100M rows, tens of GB of superfiles) fits on a big disk instead of
    // thrashing / falling back to range-only reads. Bytes.
    if let Some(b) = env::var("INFINO_CACHE_BUDGET")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
    {
        opts = opts.with_cache_budget_bytes(b);
    }

    Ok(connect_with(uri(), opts)?)
}

/// Target arrow type for a source parquet field. infino queries its own table
/// (not an external parquet view), so we apply the same adjustments the
/// datafusion variant does inline at query time:
///   EventDate: integer day count -> DATE.
///   text (Binary): -> Utf8 so LIKE / REGEXP_REPLACE / length work.
fn target_type(f: &Field) -> DataType {
    if f.name() == "EventDate" {
        return DataType::Date32;
    }
    match f.data_type() {
        DataType::Binary | DataType::LargeBinary => DataType::Utf8,
        other => other.clone(),
    }
}

fn cast_batch(batch: &RecordBatch, target: &SchemaRef) -> R<RecordBatch> {
    let mut cols = Vec::with_capacity(target.fields().len());
    for (i, f) in target.fields().iter().enumerate() {
        let col = batch.column(i);
        let out = if f.name() == "EventDate" {
            // int -> int32 -> Date32, matching datafusion's CAST(CAST(.. AS INTEGER) AS DATE).
            cast(&cast(col, &DataType::Int32)?, &DataType::Date32)?
        } else if col.data_type() != f.data_type() {
            cast(col, f.data_type())?
        } else {
            col.clone()
        };
        cols.push(out);
    }
    Ok(RecordBatch::try_new(target.clone(), cols)?)
}

fn load() -> R<()> {
    let src = env::var("INFINO_SRC").unwrap_or_else(|_| "hits.parquet".to_string());
    let max_rows: Option<usize> = env::var("INFINO_MAX_ROWS")
        .ok()
        .and_then(|s| s.parse().ok())
        .filter(|&n| n > 0);

    let mut files: Vec<PathBuf> = glob::glob(&src)?.filter_map(Result::ok).collect();
    files.sort();
    if files.is_empty() {
        return Err(format!("no parquet files match {src:?}").into());
    }

    // Target schema from the first file's schema.
    let src_schema = ParquetRecordBatchReaderBuilder::try_new(File::open(&files[0])?)?
        .schema()
        .clone();
    let fields: Vec<Field> = src_schema
        .fields()
        .iter()
        .map(|f| Field::new(f.name(), target_type(f), f.is_nullable()))
        .collect();
    let target: SchemaRef = Arc::new(Schema::new(fields));

    let db = open()?;
    if db.list_tables()?.iter().any(|t| t == "hits") {
        db.drop_table("hits", true)?;
    }
    let table = db.create_table("hits", target.clone(), IndexSpec::new())?;

    let mut appended: usize = 0;
    'files: for path in &files {
        let reader = ParquetRecordBatchReaderBuilder::try_new(File::open(path)?)?
            .with_batch_size(BATCH_ROWS)
            .build()?;
        for batch in reader {
            let mut batch = batch?;
            if let Some(max) = max_rows {
                if appended + batch.num_rows() > max {
                    batch = batch.slice(0, max - appended);
                }
            }
            let n = batch.num_rows();
            if n == 0 {
                continue;
            }
            table.append(&cast_batch(&batch, &target)?)?;
            appended += n;
            if max_rows.is_some_and(|max| appended >= max) {
                break 'files;
            }
        }
    }

    // Compact per-batch superfiles into fewer, uniform segments. Part of the
    // honest load cost.
    table.optimize(&optimize_options())?;
    println!("ingested {appended} rows");
    Ok(())
}

/// INFINO_TARGET_SF_MB sizes the compacted superfiles. Unset = infino's own
/// default (~1 GiB target). Set it to size segments to the machine — e.g. 256
/// on an 8-core box yields several balanced segments for parallel scan instead
/// of one large file plus small leftovers. min_fill_percent is dropped to 1 so
/// a one-shot optimize actually merges the small tail rather than leaving it.
fn optimize_options() -> OptimizeOptions {
    match env::var("INFINO_TARGET_SF_MB")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
    {
        Some(mb) => OptimizeOptions::compact(CompactionSettings {
            target_superfile_size_mb: mb,
            min_fill_percent: 1,
            max_memory_mb: mb + 2048,
            ..Default::default()
        }),
        None => OptimizeOptions::default(),
    }
}

/// Daemon: open the table once and answer queries on a unix socket, one query
/// per connection, serially (the ClickBench sweep is serial). Holding the table
/// open for the life of the process is the whole point: the shared driver keeps
/// the server running across a query's warm tries (2 and 3), so they reuse this
/// handle and its caches, exactly as it does for ClickHouse and other daemons.
///
/// A per-connection failure (client hung up, broken pipe, a stop/start race)
/// must never take the server down mid-sweep — that would fail every later
/// query. So the accept loop logs and skips connection errors instead of
/// propagating them; only a fatal open/bind error (below) aborts startup.
fn serve() -> R<()> {
    let sock = sock_path();
    let _ = std::fs::remove_file(&sock);
    let db = open()?;
    let listener = UnixListener::bind(&sock)?;

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                if let Err(e) = handle_conn(&db, stream) {
                    eprintln!("connection error: {e}");
                }
            }
            Err(e) => eprintln!("accept error: {e}"),
        }
    }

    let _ = std::fs::remove_file(&sock);
    Ok(())
}

/// Handle one client. The response is a header line followed by the result:
///   `OK <rows> <seconds>\n<pretty-printed result table>`   on success
///   `ERR <message>`                                        on failure
/// The client sends the SQL then half-closes its write side; that EOF is what
/// lets `read_to_string` return. The read timeout bounds a client that never
/// does, so one stuck caller cannot wedge the single-threaded server.
///
/// Timing wraps `query_sql` only: the result is formatted AFTER `elapsed()`, so
/// the reported seconds stay pure query latency (unchanged from before). We
/// return the actual rows, not just a count, because the playground shows this
/// output to the user; a bounded preview keeps a huge result from blowing up.
fn handle_conn(db: &infino::Connection, mut stream: UnixStream) -> R<()> {
    stream.set_read_timeout(Some(Duration::from_secs(300)))?;
    let mut sql = String::new();
    stream.read_to_string(&mut sql)?;
    let sql = sql.trim();
    if sql.is_empty() {
        return Ok(());
    }
    let start = Instant::now();
    let resp = match db.query_sql(sql) {
        Ok(batches) => {
            let secs = start.elapsed().as_secs_f64();
            let rows: usize = batches.iter().map(|b| b.num_rows()).sum();

            format!("OK {rows} {secs:.6}\n{}", format_preview(&batches))
        }
        Err(e) => format!("ERR {e}\n"),
    };

    stream.write_all(resp.as_bytes())?;

    Ok(())
}

/// Byte cap on the result the server sends back, matching the playground's
/// `CLICKBENCH_OUTPUT_LIMIT` (its in-VM agent truncates at the same bound).
fn output_limit() -> usize {
    env::var("CLICKBENCH_OUTPUT_LIMIT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(262_144)
}

/// Pretty-print a bounded preview of the result as a text table (the boxed
/// style datafusion-cli / duckdb use). Caps both the number of rows rendered
/// and the byte size, so formatting never touches more than a preview even if
/// the query returns millions of rows.
fn format_preview(batches: &[RecordBatch]) -> String {
    const MAX_PREVIEW_ROWS: usize = 1000;
    let mut preview = Vec::new();
    let mut taken = 0;

    for b in batches {
        if taken >= MAX_PREVIEW_ROWS {
            break;
        }
        let n = (MAX_PREVIEW_ROWS - taken).min(b.num_rows());
        preview.push(b.slice(0, n));
        taken += n;
    }

    let mut s = match arrow::util::pretty::pretty_format_batches(&preview) {
        Ok(t) => t.to_string(),
        Err(e) => format!("<could not format result: {e}>"),
    };

    let cap = output_limit();

    if s.len() > cap {
        let mut c = cap;
        while c > 0 && !s.is_char_boundary(c) {
            c -= 1;
        }
        s.truncate(c);
        s.push_str("\n... (truncated)");
    }
    s
}

/// Send `sql` to the running server and return its full response: a header line
/// (`OK <rows> <seconds>` or `ERR <message>`) followed, on success, by the
/// result table. The `shutdown(Write)` signals end-of-request (EOF) so the
/// server's `read_to_string` returns; without it both sides would block forever.
fn ask(sql: &str) -> R<String> {
    let mut stream = UnixStream::connect(sock_path())?;
    stream.write_all(sql.as_bytes())?;
    stream.shutdown(Shutdown::Write)?;

    let mut resp = String::new();
    stream.read_to_string(&mut resp)?;

    // Do not trim: the response body is the result table, whose whitespace and
    // newlines are meaningful. Only the header line is parsed by the caller.
    Ok(resp)
}

/// Client: read one SQL statement from stdin, send it to the server, print the
/// result table to stdout and the elapsed seconds to stderr (the ClickBench
/// query-script contract: stdout is the query result, the last stderr line is
/// fractional seconds). The result on stdout is also what the playground shows
/// the user.
fn query() -> R<()> {
    let mut sql = String::new();
    std::io::stdin().read_to_string(&mut sql)?;
    let resp = ask(&sql)?;
    let (header, body) = resp.split_once('\n').unwrap_or((resp.as_str(), ""));

    if let Some(rest) = header.strip_prefix("OK ") {
        // header: "OK <rows> <seconds>". `rows` is the full count; the body
        // table is a preview (up to MAX_PREVIEW_ROWS), so the footer shows the
        // real total, which also signals when the table was row-capped.
        let mut fields = rest.split_whitespace();
        let rows = fields.next().unwrap_or("0");
        let secs = fields.next().unwrap_or("0");
        print!("{body}");
        if !body.is_empty() && !body.ends_with('\n') {
            println!();
        }
        println!("({rows} rows)");
        eprintln!("{secs}");
        Ok(())
    } else {
        Err(header
            .strip_prefix("ERR ")
            .unwrap_or(header)
            .trim()
            .to_string()
            .into())
    }
}

/// Client: ping the server. Succeeds only when `serve` is up and answering, so
/// the shared driver can poll for the server coming up (after ./start) and
/// going down (after ./stop).
fn check() -> R<()> {
    let resp = ask("SELECT 1")?;
    if resp.starts_with("OK") {
        println!("ok");
        Ok(())
    } else {
        Err(format!("server not ready: {resp}").into())
    }
}

fn main() {
    let cmd = env::args().nth(1).unwrap_or_default();
    let result = match cmd.as_str() {
        "load" => load(),
        "serve" => serve(),
        "query" => query(),
        "check" => check(),
        other => Err(format!("unknown subcommand {other:?} (want load|serve|query|check)").into()),
    };
    if let Err(e) = result {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
