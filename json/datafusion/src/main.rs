//! DataFusion with `datafusion-functions-json` registered for JSONBench,
//! modeled after `../../datafusion-iceberg/src/main.rs`.
//!
//! Subcommands:
//!   jsonbench-datafusion load <data_dir> <num_files>
//!       Reads the first <num_files> `file_*.json.gz` files in parallel,
//!       validates each line as a strict UTF-8 JSON object (skipping broken
//!       >64 KiB split lines and >128-level pathological nesting), and writes
//!       a single `j` (Utf8) column into Zstd-compressed Parquet shards under
//!       `bluesky/` without flattening.
//!   jsonbench-datafusion query
//!       Reads one SQL query from stdin, executes it against `bluesky/*.parquet`
//!       with `datafusion-functions-json` registered, writes the full
//!       untruncated table to stdout (inside the timed window), and prints the
//!       elapsed seconds on stderr.
//!   jsonbench-datafusion count
//!       Prints the total row count of `bluesky`.
//!   jsonbench-datafusion version
//!       Prints `datafusion::DATAFUSION_VERSION`.

use std::env;
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use datafusion::arrow::array::{Int64Array, StringBuilder};
use datafusion::arrow::datatypes::{DataType, Field, Schema};
use datafusion::arrow::record_batch::RecordBatch;
use datafusion::arrow::util::pretty::pretty_format_batches;
use datafusion::error::{DataFusionError, Result};
use datafusion::parquet::arrow::ArrowWriter;
use datafusion::parquet::basic::{Compression, ZstdLevel};
use datafusion::parquet::file::properties::WriterProperties;
use datafusion::prelude::{ParquetReadOptions, SessionContext};
use flate2::read::MultiGzDecoder;
use rayon::prelude::*;

const TABLE_DIR: &str = "bluesky";
const BATCH_ROWS: usize = 65_536;

fn io_err(e: impl std::error::Error + Send + Sync + 'static) -> DataFusionError {
    DataFusionError::External(Box::new(e))
}

fn is_valid_json_object(line: &[u8]) -> Option<&str> {
    let trimmed = line.trim_ascii();
    if !trimmed.starts_with(b"{") {
        return None;
    }
    let s = std::str::from_utf8(trimmed).ok()?;
    serde_json::from_str::<serde::de::IgnoredAny>(s).ok()?;
    Some(s)
}

fn convert_one(idx: usize, path: &Path) -> Result<usize> {
    let schema = Arc::new(Schema::new(vec![Field::new("j", DataType::Utf8, false)]));
    let out_path = Path::new(TABLE_DIR).join(format!("part_{idx:04}.parquet"));
    let out_file = File::create(&out_path)?;
    let props = WriterProperties::builder()
        .set_compression(Compression::ZSTD(ZstdLevel::default()))
        .build();
    let mut writer = ArrowWriter::try_new(out_file, Arc::clone(&schema), Some(props))?;

    let in_file = File::open(path)?;
    let gz = MultiGzDecoder::new(in_file);
    let mut reader = BufReader::with_capacity(1 << 20, gz);

    let mut line_buf = Vec::with_capacity(64 * 1024);
    let mut builder = StringBuilder::with_capacity(BATCH_ROWS, BATCH_ROWS * 512);
    let mut buffered = 0usize;
    let mut skipped = 0usize;

    loop {
        line_buf.clear();
        let n = reader.read_until(b'\n', &mut line_buf)?;
        if n == 0 {
            break;
        }
        // Ignore completely empty trailing newline if any; count non-empty invalid lines.
        if line_buf.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        match is_valid_json_object(&line_buf) {
            Some(valid) => {
                builder.append_value(valid);
                buffered += 1;
                if buffered >= BATCH_ROWS {
                    let batch =
                        RecordBatch::try_new(Arc::clone(&schema), vec![Arc::new(builder.finish())])?;
                    writer.write(&batch)?;
                    builder = StringBuilder::with_capacity(BATCH_ROWS, BATCH_ROWS * 512);
                    buffered = 0;
                }
            }
            None => {
                skipped += 1;
            }
        }
    }

    if buffered > 0 {
        let batch = RecordBatch::try_new(Arc::clone(&schema), vec![Arc::new(builder.finish())])?;
        writer.write(&batch)?;
    }
    writer.close()?;
    Ok(skipped)
}

fn run_load(data_dir: &str, num_files: usize) -> Result<()> {
    let mut files: Vec<PathBuf> = fs::read_dir(data_dir)?
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("file_") && n.ends_with(".json.gz"))
        })
        .collect();
    files.sort();
    files.truncate(num_files);

    if files.is_empty() {
        return Err(DataFusionError::Execution(format!(
            "load: no file_*.json.gz found in {data_dir}"
        )));
    }

    let _ = fs::remove_dir_all(TABLE_DIR);
    fs::create_dir_all(TABLE_DIR)?;

    let cpus = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4);
    let workers = files.len().min(cpus).min(16).max(1);
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(workers)
        .build()
        .map_err(io_err)?;

    let results: Vec<Result<usize>> = pool.install(|| {
        files
            .par_iter()
            .enumerate()
            .map(|(i, path)| convert_one(i + 1, path))
            .collect()
    });

    let mut total_skipped = 0usize;
    for r in results {
        total_skipped += r?;
    }
    if total_skipped > 0 {
        eprintln!("load: skipped {total_skipped} invalid lines");
    }
    Ok(())
}

async fn make_context() -> Result<SessionContext> {
    let mut ctx = SessionContext::new();
    datafusion_functions_json::register_all(&mut ctx)?;
    ctx.register_parquet(
        "bluesky",
        TABLE_DIR,
        ParquetReadOptions::default().file_extension(".parquet"),
    )
    .await?;
    Ok(ctx)
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("load") => {
            let data_dir = args
                .get(2)
                .ok_or_else(|| DataFusionError::Execution("missing <data_dir>".into()))?;
            let num_files: usize = args
                .get(3)
                .ok_or_else(|| DataFusionError::Execution("missing <num_files>".into()))?
                .parse()
                .map_err(io_err)?;
            run_load(data_dir, num_files)?;
        }
        Some("query") => {
            let mut query = String::new();
            io::stdin().read_to_string(&mut query)?;
            let query = query.trim().trim_end_matches(';').trim();
            let ctx = make_context().await?;

            let start = Instant::now();
            let batches = ctx.sql(query).await?.collect().await?;
            let formatted = pretty_format_batches(&batches)?.to_string();
            let mut stdout = io::stdout().lock();
            stdout.write_all(formatted.as_bytes())?;
            stdout.write_all(b"\n")?;
            stdout.flush()?;
            let elapsed = start.elapsed().as_secs_f64();

            eprintln!("{elapsed:.6}");
        }
        Some("count") => {
            let ctx = make_context().await?;
            let batches = ctx.sql("SELECT COUNT(*) FROM bluesky").await?.collect().await?;
            let count = batches[0]
                .column(0)
                .as_any()
                .downcast_ref::<Int64Array>()
                .ok_or_else(|| DataFusionError::Internal("expected Int64Array".into()))?
                .value(0);
            println!("{count}");
        }
        Some("version") => {
            println!("{}", datafusion::DATAFUSION_VERSION);
        }
        _ => {
            eprintln!(
                "usage: jsonbench-datafusion load <data_dir> <num_files> | query | count | version"
            );
            std::process::exit(1);
        }
    }
    Ok(())
}
