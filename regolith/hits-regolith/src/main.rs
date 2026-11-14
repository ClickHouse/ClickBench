// ClickBench harness for regolith (https://github.com/sourcenetwork/regolith).
//
// regolith is an embedded LSM-tree key-value store with a synchronous API.
// It has no query language, so this harness stores each row of the hits
// dataset as one key-value pair (key = 8-byte big-endian row index, value =
// a compact positional row encoding) and runs the ClickBench SQL through
// Apache DataFusion with a custom TableProvider whose partitions are
// parallel regolith range scans.
//
// The row codec, the DataFusion integration and the partitioning below are
// deliberately byte-for-byte the same as the SlateDB entry's, so a
// comparison between the two isolates the storage engine and nothing else.
//
// Usage:
//   hits-regolith load  <hits.parquet> <db-dir>
//   hits-regolith query <db-dir> [create.sql]   # SQL statement on stdin

use std::io::Read;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use anyhow::{anyhow, bail, Context, Result};
use async_trait::async_trait;
use futures::stream::StreamExt;

use datafusion::arrow::array::{
    ArrayRef, AsArray, Int16Array, Int32Array, Int64Array, RecordBatch, RecordBatchOptions,
    StringBuilder, UInt16Array, UInt32Array, UInt64Array,
};
use datafusion::arrow::datatypes::{
    DataType, Field, Int16Type, Int32Type, Int64Type, Schema, SchemaRef, UInt16Type, UInt32Type,
    UInt64Type,
};
use datafusion::arrow::util::pretty::pretty_format_batches;
use datafusion::catalog::Session;
use datafusion::common::stats::{Precision, Statistics};
use datafusion::common::tree_node::TreeNodeRecursion;
use datafusion::datasource::{TableProvider, TableType};
use datafusion::error::{DataFusionError, Result as DFResult};
use datafusion::execution::TaskContext;
use datafusion::logical_expr::Expr;
use datafusion::physical_expr::{EquivalenceProperties, PhysicalExpr};
use datafusion::physical_plan::execution_plan::{Boundedness, EmissionType};
use datafusion::physical_plan::stream::RecordBatchStreamAdapter;
use datafusion::physical_plan::{
    DisplayAs, DisplayFormatType, ExecutionPlan, Partitioning, PlanProperties,
    SendableRecordBatchStream,
};
use datafusion::prelude::{ParquetReadOptions, SessionContext};

use regolith::{CompressionType, Db, Options, WriteBatch, WriteOptions};

#[global_allocator]
static ALLOC: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

// Row keys are 8-byte big-endian indexes, so they sort in row order and any
// key starting with 0xff sorts after all of them (the dataset has far fewer
// than 2^56 rows).
const META_SCHEMA: &[u8] = b"\xffschema";
const META_COUNT: &[u8] = b"\xffcount";
const BATCH_ROWS: usize = 8192;

fn row_key(i: u64) -> [u8; 8] {
    i.to_be_bytes()
}

// Every knob below is read from the environment so the configuration sweep
// can vary one axis at a time without a rebuild. The defaults ARE the
// measured configuration this entry reports; the environment exists for the
// sweep that chose them (see sweep.sh) and for anyone reproducing it.
fn env_usize(name: &str, default: usize) -> usize {
    match std::env::var(name) {
        Ok(v) => v.parse().unwrap_or(default),
        Err(_) => default,
    }
}

fn env_u64(name: &str, default: u64) -> u64 {
    match std::env::var(name) {
        Ok(v) => v.parse().unwrap_or(default),
        Err(_) => default,
    }
}

fn compression() -> CompressionType {
    match std::env::var("REGOLITH_COMPRESSION").as_deref() {
        Ok("none") => CompressionType::None,
        Ok("snappy") => CompressionType::Snappy,
        _ => CompressionType::Lz4,
    }
}

const MIB: usize = 1024 * 1024;

// Bytes the load may hold across all of its buffers. The machine has 32 GiB
// and no swap headroom worth relying on, and an OOM kill mid-load is a lost
// run, so the budget is stated once here and every buffer below is sized as
// a share of it rather than picked independently.
//
//   memtables      MEMTABLE_MIB * MEMTABLE_COUNT
//   write batches  WRITE_BATCH_BYTES * parquet partitions (= cpus)
//   block cache    BLOCK_CACHE_MIB
//
// At the defaults on a 16 vCPU host that is 4 + 1 + 1 = 6 GiB against 32,
// which leaves room for compaction buffers, the Arrow side of the parquet
// read, and the page cache the scan wants.
const MEMTABLE_MIB: usize = 1024;
const MEMTABLE_COUNT: usize = 4;
const BLOCK_CACHE_MIB: usize = 1024;

fn base_options() -> Options {
    let cpus = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    Options {
        compression: compression(),
        // 64 KiB data blocks: this workload only ever reads whole ranges, so
        // a larger block amortizes the per-block header, checksum and
        // decompression call over more rows than the 16 KiB default.
        block_size: env_usize("REGOLITH_BLOCK_SIZE_KIB", 64) * 1024,
        // No point lookup in the benchmark touches a user row: the 43
        // queries are range scans and the two metadata keys are read once
        // per process. A bloom filter would only add bytes to every SSTable
        // and hashing to every compaction, so this sits at the floor the
        // options allow (`bloom_bits_per_key` must be in 1..=64).
        bloom_bits_per_key: env_usize("REGOLITH_BLOOM_BITS", 1),
        block_cache_size: env_usize("REGOLITH_BLOCK_CACHE_MIB", BLOCK_CACHE_MIB) * MIB,
        write_buffer_size: env_usize("REGOLITH_WRITE_BUFFER_MIB", MEMTABLE_MIB) * MIB,
        max_write_buffer_number: env_usize("REGOLITH_MAX_WRITE_BUFFERS", MEMTABLE_COUNT),
        target_file_size: env_u64("REGOLITH_TARGET_FILE_MIB", 256) * MIB as u64,
        level_base_bytes: env_u64("REGOLITH_LEVEL_BASE_MIB", 2048) * MIB as u64,
        // Low, so compaction keeps L0 shallow as the load runs rather than
        // letting it pile up into runs every later scan has to merge.
        l0_compaction_trigger: env_usize("REGOLITH_L0_TRIGGER", 2),
        max_background_compactions: env_usize("REGOLITH_MAX_BG_COMPACTIONS", cpus),
        max_subcompactions: env_usize("REGOLITH_MAX_SUBCOMPACTIONS", cpus),
        ..Default::default()
    }
}

// ---------------------------------------------------------------------------
// Row encoding: fixed-width integers little-endian, strings varint-length
// prefixed, all columns concatenated in schema order. The dataset has no
// NULLs (all parquet fields are REQUIRED), which the loader verifies.
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum ColType {
    I16,
    I32,
    I64,
    U16,
    U32,
    U64,
    Str,
}

impl ColType {
    fn tag(self) -> &'static str {
        match self {
            ColType::I16 => "i16",
            ColType::I32 => "i32",
            ColType::I64 => "i64",
            ColType::U16 => "u16",
            ColType::U32 => "u32",
            ColType::U64 => "u64",
            ColType::Str => "str",
        }
    }

    fn from_tag(s: &str) -> Result<Self> {
        Ok(match s {
            "i16" => ColType::I16,
            "i32" => ColType::I32,
            "i64" => ColType::I64,
            "u16" => ColType::U16,
            "u32" => ColType::U32,
            "u64" => ColType::U64,
            "str" => ColType::Str,
            other => bail!("unknown column tag {other:?}"),
        })
    }

    fn from_arrow(dt: &DataType) -> Result<Self> {
        Ok(match dt {
            DataType::Int16 => ColType::I16,
            DataType::Int32 => ColType::I32,
            DataType::Int64 => ColType::I64,
            DataType::UInt16 => ColType::U16,
            DataType::UInt32 => ColType::U32,
            DataType::UInt64 => ColType::U64,
            DataType::Utf8
            | DataType::LargeUtf8
            | DataType::Utf8View
            | DataType::Binary
            | DataType::LargeBinary
            | DataType::BinaryView => ColType::Str,
            other => bail!("unsupported column type {other:?}"),
        })
    }

    fn arrow_type(self) -> DataType {
        match self {
            ColType::I16 => DataType::Int16,
            ColType::I32 => DataType::Int32,
            ColType::I64 => DataType::Int64,
            ColType::U16 => DataType::UInt16,
            ColType::U32 => DataType::UInt32,
            ColType::U64 => DataType::UInt64,
            ColType::Str => DataType::Utf8,
        }
    }
}

fn write_varint(buf: &mut Vec<u8>, mut v: u64) {
    loop {
        let b = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            buf.push(b);
            break;
        }
        buf.push(b | 0x80);
    }
}

fn read_varint(data: &[u8], pos: &mut usize) -> u64 {
    let mut v = 0u64;
    let mut shift = 0;
    loop {
        let b = data[*pos];
        *pos += 1;
        v |= ((b & 0x7f) as u64) << shift;
        if b & 0x80 == 0 {
            return v;
        }
        shift += 7;
    }
}

fn put_bytes(row: &mut Vec<u8>, b: &[u8]) {
    write_varint(row, b.len() as u64);
    row.extend_from_slice(b);
}

fn encode_str_col(arr: &ArrayRef, rows: &mut [Vec<u8>]) -> Result<()> {
    match arr.data_type() {
        DataType::Utf8 => {
            let a = arr.as_string::<i32>();
            for (i, row) in rows.iter_mut().enumerate() {
                put_bytes(row, a.value(i).as_bytes());
            }
        }
        DataType::LargeUtf8 => {
            let a = arr.as_string::<i64>();
            for (i, row) in rows.iter_mut().enumerate() {
                put_bytes(row, a.value(i).as_bytes());
            }
        }
        DataType::Utf8View => {
            let a = arr.as_string_view();
            for (i, row) in rows.iter_mut().enumerate() {
                put_bytes(row, a.value(i).as_bytes());
            }
        }
        DataType::Binary => {
            let a = arr.as_binary::<i32>();
            for (i, row) in rows.iter_mut().enumerate() {
                put_bytes(row, a.value(i));
            }
        }
        DataType::LargeBinary => {
            let a = arr.as_binary::<i64>();
            for (i, row) in rows.iter_mut().enumerate() {
                put_bytes(row, a.value(i));
            }
        }
        DataType::BinaryView => {
            let a = arr.as_binary_view();
            for (i, row) in rows.iter_mut().enumerate() {
                put_bytes(row, a.value(i));
            }
        }
        other => bail!("unsupported string column type {other:?}"),
    }
    Ok(())
}

fn encode_rows(batch: &RecordBatch, tags: &[ColType]) -> Result<Vec<Vec<u8>>> {
    let n = batch.num_rows();
    let mut rows: Vec<Vec<u8>> = (0..n).map(|_| Vec::with_capacity(1024)).collect();
    for (ci, tag) in tags.iter().enumerate() {
        let arr = batch.column(ci);
        if arr.null_count() > 0 {
            bail!("NULL values are not supported (column {ci})");
        }
        match tag {
            ColType::I16 => {
                let a = arr.as_primitive::<Int16Type>();
                for (i, row) in rows.iter_mut().enumerate() {
                    row.extend_from_slice(&a.value(i).to_le_bytes());
                }
            }
            ColType::I32 => {
                let a = arr.as_primitive::<Int32Type>();
                for (i, row) in rows.iter_mut().enumerate() {
                    row.extend_from_slice(&a.value(i).to_le_bytes());
                }
            }
            ColType::I64 => {
                let a = arr.as_primitive::<Int64Type>();
                for (i, row) in rows.iter_mut().enumerate() {
                    row.extend_from_slice(&a.value(i).to_le_bytes());
                }
            }
            ColType::U16 => {
                let a = arr.as_primitive::<UInt16Type>();
                for (i, row) in rows.iter_mut().enumerate() {
                    row.extend_from_slice(&a.value(i).to_le_bytes());
                }
            }
            ColType::U32 => {
                let a = arr.as_primitive::<UInt32Type>();
                for (i, row) in rows.iter_mut().enumerate() {
                    row.extend_from_slice(&a.value(i).to_le_bytes());
                }
            }
            ColType::U64 => {
                let a = arr.as_primitive::<UInt64Type>();
                for (i, row) in rows.iter_mut().enumerate() {
                    row.extend_from_slice(&a.value(i).to_le_bytes());
                }
            }
            ColType::Str => encode_str_col(arr, &mut rows)?,
        }
    }
    Ok(rows)
}

// ---------------------------------------------------------------------------
// Row decoding into Arrow arrays, skipping columns outside the projection.
// ---------------------------------------------------------------------------

const SKIP: usize = usize::MAX;

enum ColBuf {
    I16(Vec<i16>),
    I32(Vec<i32>),
    I64(Vec<i64>),
    U16(Vec<u16>),
    U32(Vec<u32>),
    U64(Vec<u64>),
    Str(StringBuilder),
}

impl ColBuf {
    fn new(tag: ColType) -> Self {
        match tag {
            ColType::I16 => ColBuf::I16(Vec::with_capacity(BATCH_ROWS)),
            ColType::I32 => ColBuf::I32(Vec::with_capacity(BATCH_ROWS)),
            ColType::I64 => ColBuf::I64(Vec::with_capacity(BATCH_ROWS)),
            ColType::U16 => ColBuf::U16(Vec::with_capacity(BATCH_ROWS)),
            ColType::U32 => ColBuf::U32(Vec::with_capacity(BATCH_ROWS)),
            ColType::U64 => ColBuf::U64(Vec::with_capacity(BATCH_ROWS)),
            ColType::Str => ColBuf::Str(StringBuilder::new()),
        }
    }

    fn finish(&mut self) -> ArrayRef {
        match self {
            ColBuf::I16(v) => Arc::new(Int16Array::from(std::mem::take(v))),
            ColBuf::I32(v) => Arc::new(Int32Array::from(std::mem::take(v))),
            ColBuf::I64(v) => Arc::new(Int64Array::from(std::mem::take(v))),
            ColBuf::U16(v) => Arc::new(UInt16Array::from(std::mem::take(v))),
            ColBuf::U32(v) => Arc::new(UInt32Array::from(std::mem::take(v))),
            ColBuf::U64(v) => Arc::new(UInt64Array::from(std::mem::take(v))),
            ColBuf::Str(b) => Arc::new(b.finish()),
        }
    }
}

struct Decoder {
    tags: Arc<Vec<ColType>>,
    // Output slot per source column; SKIP when the column is not projected.
    slots: Vec<usize>,
    bufs: Vec<ColBuf>,
    out_schema: SchemaRef,
    rows: usize,
}

impl Decoder {
    fn new(tags: Arc<Vec<ColType>>, projection: &[usize], out_schema: SchemaRef) -> Self {
        let mut slots = vec![SKIP; tags.len()];
        for (slot, &ci) in projection.iter().enumerate() {
            slots[ci] = slot;
        }
        let bufs = projection.iter().map(|&ci| ColBuf::new(tags[ci])).collect();
        Decoder { tags, slots, bufs, out_schema, rows: 0 }
    }

    fn push_row(&mut self, data: &[u8]) {
        let mut pos = 0usize;
        for (ci, tag) in self.tags.iter().enumerate() {
            let slot = self.slots[ci];
            match tag {
                ColType::I16 => {
                    if slot != SKIP {
                        let v = i16::from_le_bytes(data[pos..pos + 2].try_into().unwrap());
                        match &mut self.bufs[slot] {
                            ColBuf::I16(b) => b.push(v),
                            _ => unreachable!(),
                        }
                    }
                    pos += 2;
                }
                ColType::I32 => {
                    if slot != SKIP {
                        let v = i32::from_le_bytes(data[pos..pos + 4].try_into().unwrap());
                        match &mut self.bufs[slot] {
                            ColBuf::I32(b) => b.push(v),
                            _ => unreachable!(),
                        }
                    }
                    pos += 4;
                }
                ColType::I64 => {
                    if slot != SKIP {
                        let v = i64::from_le_bytes(data[pos..pos + 8].try_into().unwrap());
                        match &mut self.bufs[slot] {
                            ColBuf::I64(b) => b.push(v),
                            _ => unreachable!(),
                        }
                    }
                    pos += 8;
                }
                ColType::U16 => {
                    if slot != SKIP {
                        let v = u16::from_le_bytes(data[pos..pos + 2].try_into().unwrap());
                        match &mut self.bufs[slot] {
                            ColBuf::U16(b) => b.push(v),
                            _ => unreachable!(),
                        }
                    }
                    pos += 2;
                }
                ColType::U32 => {
                    if slot != SKIP {
                        let v = u32::from_le_bytes(data[pos..pos + 4].try_into().unwrap());
                        match &mut self.bufs[slot] {
                            ColBuf::U32(b) => b.push(v),
                            _ => unreachable!(),
                        }
                    }
                    pos += 4;
                }
                ColType::U64 => {
                    if slot != SKIP {
                        let v = u64::from_le_bytes(data[pos..pos + 8].try_into().unwrap());
                        match &mut self.bufs[slot] {
                            ColBuf::U64(b) => b.push(v),
                            _ => unreachable!(),
                        }
                    }
                    pos += 8;
                }
                ColType::Str => {
                    let len = read_varint(data, &mut pos) as usize;
                    if slot != SKIP {
                        // The dataset is ClickHouse's, where a string column
                        // is raw bytes. Reinterpreted without validation, on
                        // purpose: validating would cost a pass over every
                        // string of every row, and this harness exists to
                        // measure the storage engine rather than to police
                        // its input. Nothing but this loader writes the
                        // store.
                        let s = unsafe { std::str::from_utf8_unchecked(&data[pos..pos + len]) };
                        match &mut self.bufs[slot] {
                            ColBuf::Str(b) => b.append_value(s),
                            _ => unreachable!(),
                        }
                    }
                    pos += len;
                }
            }
        }
        self.rows += 1;
    }

    fn finish(&mut self) -> DFResult<RecordBatch> {
        let arrays: Vec<ArrayRef> = self.bufs.iter_mut().map(|b| b.finish()).collect();
        let opts = RecordBatchOptions::new().with_row_count(Some(self.rows));
        self.rows = 0;
        RecordBatch::try_new_with_options(self.out_schema.clone(), arrays, &opts)
            .map_err(DataFusionError::from)
    }
}

// ---------------------------------------------------------------------------
// DataFusion integration: TableProvider + ExecutionPlan over regolith scans.
// ---------------------------------------------------------------------------

fn ext_err(e: regolith::Error) -> DataFusionError {
    DataFusionError::External(Box::new(e))
}

struct HitsTable {
    db: Arc<Db>,
    schema: SchemaRef,
    tags: Arc<Vec<ColType>>,
    row_count: u64,
}

impl std::fmt::Debug for HitsTable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "HitsTable(rows={})", self.row_count)
    }
}

#[async_trait]
impl TableProvider for HitsTable {
    fn schema(&self) -> SchemaRef {
        self.schema.clone()
    }

    fn table_type(&self) -> TableType {
        TableType::Base
    }

    async fn scan(
        &self,
        state: &dyn Session,
        projection: Option<&Vec<usize>>,
        _filters: &[Expr],
        limit: Option<usize>,
    ) -> DFResult<Arc<dyn ExecutionPlan>> {
        let projection: Vec<usize> = match projection {
            Some(p) => p.clone(),
            None => (0..self.schema.fields().len()).collect(),
        };
        let out_schema = Arc::new(self.schema.project(&projection)?);
        // One partition per target partition, but keep at least 64k rows in
        // each so tiny scans don't fan out for nothing.
        let max_parts = self.row_count.div_ceil(65536).max(1);
        // Reader-side knob: more partitions than cores can pay off when the
        // scan is waiting on the disk rather than on the CPU.
        let target = env_usize("REGOLITH_SCAN_PARTITIONS", state.config().target_partitions());
        let partitions = (target as u64).min(max_parts).max(1) as usize;
        Ok(Arc::new(RegolithScanExec::new(
            self.db.clone(),
            self.tags.clone(),
            projection,
            out_schema,
            self.row_count,
            partitions,
            limit,
        )))
    }

    fn statistics(&self) -> Option<Statistics> {
        Some(
            Statistics::new_unknown(&self.schema)
                .with_num_rows(Precision::Exact(self.row_count as usize)),
        )
    }
}

struct RegolithScanExec {
    db: Arc<Db>,
    tags: Arc<Vec<ColType>>,
    projection: Vec<usize>,
    out_schema: SchemaRef,
    row_count: u64,
    partitions: usize,
    limit: Option<usize>,
    props: Arc<PlanProperties>,
}

impl RegolithScanExec {
    #[allow(clippy::too_many_arguments)]
    fn new(
        db: Arc<Db>,
        tags: Arc<Vec<ColType>>,
        projection: Vec<usize>,
        out_schema: SchemaRef,
        row_count: u64,
        partitions: usize,
        limit: Option<usize>,
    ) -> Self {
        let props = Arc::new(PlanProperties::new(
            EquivalenceProperties::new(out_schema.clone()),
            Partitioning::UnknownPartitioning(partitions),
            EmissionType::Incremental,
            Boundedness::Bounded,
        ));
        RegolithScanExec { db, tags, projection, out_schema, row_count, partitions, limit, props }
    }
}

impl std::fmt::Debug for RegolithScanExec {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "RegolithScanExec")
    }
}

impl DisplayAs for RegolithScanExec {
    fn fmt_as(&self, _t: DisplayFormatType, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(
            f,
            "RegolithScanExec: rows={}, partitions={}, projection={:?}",
            self.row_count, self.partitions, self.projection
        )
    }
}

impl ExecutionPlan for RegolithScanExec {
    fn name(&self) -> &str {
        "RegolithScanExec"
    }

    fn properties(&self) -> &Arc<PlanProperties> {
        &self.props
    }

    fn apply_expressions(
        &self,
        _f: &mut dyn FnMut(&Arc<dyn PhysicalExpr>) -> DFResult<TreeNodeRecursion>,
    ) -> DFResult<TreeNodeRecursion> {
        Ok(TreeNodeRecursion::Continue)
    }

    fn children(&self) -> Vec<&Arc<dyn ExecutionPlan>> {
        vec![]
    }

    fn with_new_children(
        self: Arc<Self>,
        _children: Vec<Arc<dyn ExecutionPlan>>,
    ) -> DFResult<Arc<dyn ExecutionPlan>> {
        Ok(self)
    }

    // regolith's IO is synchronous, so a partition is drained by a dedicated
    // OS thread that decodes into Arrow and hands finished batches over a
    // bounded channel. Bounded at two batches per partition: what the plan
    // holds is a page per partition, never the range.
    fn execute(
        &self,
        partition: usize,
        _context: Arc<TaskContext>,
    ) -> DFResult<SendableRecordBatchStream> {
        let chunk = self.row_count.div_ceil(self.partitions as u64);
        let lo = (partition as u64) * chunk;
        let hi = ((partition as u64 + 1) * chunk).min(self.row_count);
        let db = self.db.clone();
        let limit = self.limit.unwrap_or(usize::MAX);
        let mut decoder =
            Decoder::new(self.tags.clone(), &self.projection, self.out_schema.clone());

        let (tx, rx) = tokio::sync::mpsc::channel::<DFResult<RecordBatch>>(2);

        // The producer runs on its own thread because regolith's IO is
        // synchronous. A thread that panics drops its sender, the receiver
        // sees a closed channel, and DataFusion reads that as a complete
        // stream: the query would return a wrong answer and report success.
        // The guard turns an unwound thread into an error on the channel
        // instead. It only fires on the panic path, where the sender is
        // still open precisely because nothing sent on it.
        struct AbortOnPanic(Option<tokio::sync::mpsc::Sender<DFResult<RecordBatch>>>);
        impl Drop for AbortOnPanic {
            fn drop(&mut self) {
                if !std::thread::panicking() {
                    return;
                }
                if let Some(tx) = self.0.take() {
                    let _ = tx.blocking_send(Err(DataFusionError::Execution(
                        "the scan thread panicked; this result is incomplete".into(),
                    )));
                }
            }
        }

        std::thread::spawn(move || {
            let _guard = AbortOnPanic(Some(tx.clone()));
            if lo >= hi {
                return;
            }
            // The cursor rather than `Db::scan_stream`: the stream adapter
            // copies every key into a fresh Vec, and this scan never looks
            // at a key beyond the range bound. Values come straight out of
            // the block the cursor holds, so a row is decoded without a
            // single allocation of its own.
            let mut cursor = db.snapshot().into_owned_iter();
            let end = row_key(hi);
            cursor.seek(&row_key(lo));
            let mut remaining = limit;
            while remaining > 0 && cursor.valid() {
                match cursor.key() {
                    Some(k) if k < &end[..] => {}
                    _ => break,
                }
                let Some(value) = cursor.value() else { break };
                decoder.push_row(value);
                remaining -= 1;
                if decoder.rows >= BATCH_ROWS {
                    let batch = decoder.finish();
                    if tx.blocking_send(batch).is_err() {
                        return;
                    }
                }
                cursor.next();
            }
            // A cursor that stopped on an I/O error reports it here rather
            // than looking like a range that simply ended.
            if let Err(e) = cursor.status() {
                let _ = tx.blocking_send(Err(ext_err(e)));
                return;
            }
            if decoder.rows > 0 {
                let _ = tx.blocking_send(decoder.finish());
            }
        });

        let batches = tokio_stream_from(rx);
        Ok(Box::pin(RecordBatchStreamAdapter::new(self.out_schema.clone(), batches)))
    }

    fn partition_statistics(&self, partition: Option<usize>) -> DFResult<Arc<Statistics>> {
        let mut stats = Statistics::new_unknown(&self.out_schema);
        if self.limit.is_none() {
            let rows = match partition {
                None => self.row_count,
                Some(p) => {
                    let chunk = self.row_count.div_ceil(self.partitions as u64);
                    let lo = (p as u64) * chunk;
                    let hi = ((p as u64 + 1) * chunk).min(self.row_count);
                    hi.saturating_sub(lo)
                }
            };
            stats = stats.with_num_rows(Precision::Exact(rows as usize));
        }
        Ok(Arc::new(stats))
    }
}

// A receiver as a Stream, without pulling in tokio-stream for one adapter.
fn tokio_stream_from(
    rx: tokio::sync::mpsc::Receiver<DFResult<RecordBatch>>,
) -> impl futures::Stream<Item = DFResult<RecordBatch>> {
    futures::stream::unfold(rx, |mut rx| async move {
        rx.recv().await.map(|item| (item, rx))
    })
}

// ---------------------------------------------------------------------------
// Load: hits.parquet -> regolith.
// ---------------------------------------------------------------------------

// Bytes a loader thread buffers before crossing into the engine. Peak
// footprint of the load is this times the number of parquet partitions.
const WRITE_BATCH_BYTES: usize = 64 * MIB;

// regolith's write path is synchronous: hand the blocking work to a thread
// the runtime can spare rather than stalling a worker other partitions need.
async fn flush_batch(db: &Arc<Db>, wopts: &WriteOptions, wb: &mut WriteBatch) -> Result<()> {
    let batch = std::mem::take(wb);
    let db = db.clone();
    let wopts = *wopts;
    tokio::task::spawn_blocking(move || db.write_opt(&wopts, batch)).await??;
    Ok(())
}

async fn load(parquet_path: &str, db_dir: &str) -> Result<()> {
    let db = Arc::new(Db::open(db_dir, base_options())?);

    let ctx = SessionContext::new();
    let df = ctx.read_parquet(parquet_path, ParquetReadOptions::default()).await?;
    let schema: SchemaRef = Arc::new(df.schema().as_arrow().clone());
    let tags: Vec<ColType> = schema
        .fields()
        .iter()
        .map(|f| ColType::from_arrow(f.data_type()))
        .collect::<Result<_>>()?;
    let tags = Arc::new(tags);
    let schema_txt: String = schema
        .fields()
        .iter()
        .zip(tags.iter())
        .map(|(f, t)| format!("{}\t{}\n", f.name(), t.tag()))
        .collect();

    // The load is a bulk import that ends with an explicit flush and a clean
    // close, so a WAL would only double the write volume for durability the
    // close already provides.
    let wopts = WriteOptions::disable_wal();

    let streams = df.execute_stream_partitioned().await?;
    let counter = Arc::new(AtomicU64::new(0));
    let mut handles = Vec::new();
    for mut s in streams {
        let db = db.clone();
        let tags = tags.clone();
        let counter = counter.clone();
        handles.push(tokio::spawn(async move {
            let mut wb = WriteBatch::new();
            while let Some(batch) = s.next().await {
                let batch = batch?;
                let rows = encode_rows(&batch, &tags)?;
                let base = counter.fetch_add(rows.len() as u64, Ordering::Relaxed);
                for (i, row) in rows.into_iter().enumerate() {
                    wb.put_owned(&row_key(base + i as u64), row);
                }
                // One crossing into the engine per WRITE_BATCH_BYTES, not
                // one per parquet batch: what bounds memory here is the
                // bytes buffered, not a row count, and the peak is this
                // budget times the number of parquet partitions.
                if wb.buffered_bytes() >= WRITE_BATCH_BYTES {
                    flush_batch(&db, &wopts, &mut wb).await?;
                }
            }
            if wb.buffered_bytes() > 0 {
                flush_batch(&db, &wopts, &mut wb).await?;
            }
            Ok::<_, anyhow::Error>(())
        }));
    }
    for h in handles {
        h.await??;
    }

    let total = counter.load(Ordering::Relaxed);
    let mut wb = WriteBatch::new();
    wb.put(META_COUNT, &total.to_le_bytes());
    wb.put(META_SCHEMA, schema_txt.as_bytes());
    db.write(wb)?;
    db.flush()?;

    // Settle the store before any query runs: drain L0, and no more.
    //
    // What a scan pays for is the number of sorted runs it must merge, and
    // L0 is the only level whose files overlap each other. Emptying it takes
    // the merge from one source per L0 file down to one per populated level,
    // which here is one. Rewriting everything below L0 as well buys nothing
    // further: measured on this machine, a full `compact_range` cost 1239
    // extra seconds of load and returned 10.5% on warm queries and 0.4% on
    // cold, which is a net loss once load time is weighed at its 10% share
    // of the combined metric.
    //
    // The loop has to distinguish two things `compact_step` does not.
    // It returns `false` both when there is nothing left to do and when
    // another worker holds the files it would have picked, so a plain
    // `while db.compact_step()? {}` exits on contention and closes with L0
    // still deep. That is what left fifteen L0 files behind and charged
    // every later scan for a sixteen-way merge. Watching the level itself
    // is the way to tell: keep going while L0 is non-empty, and treat a
    // step that did nothing as contention worth waiting out rather than as
    // completion.
    fn l0_files(db: &Db) -> u64 {
        db.get_int_property("regolith.num-files-at-level0").unwrap_or(0)
    }

    match std::env::var("REGOLITH_COMPACT").as_deref() {
        Ok("none") => {}
        Ok("full") => db.compact_range(None, None)?,
        _ => {
            // Drain until no L0 compaction is pending.
            //
            // The condition has to be the trigger, not zero. Compaction does
            // not touch L0 until it holds `l0_compaction_trigger` files, so
            // waiting for an empty L0 waits for something that will never
            // happen: the first version of this loop asked for zero, found
            // the level already below the trigger, and returned having done
            // nothing at all, which is the same fail-quiet shape as the
            // `compact_step` drain it replaced.
            //
            // A `false` from `compact_step` still means either "nothing
            // pending" or "another worker holds it", so the two are told
            // apart by looking at the level: below the trigger there is
            // genuinely nothing to pick, and at or above it a `false` is
            // contention worth waiting out.
            let trigger = env_usize("REGOLITH_L0_TRIGGER", 2) as u64;
            let deadline = Instant::now() + std::time::Duration::from_secs(3600);
            let mut idle_rounds = 0u32;
            loop {
                if db.compact_step()? {
                    idle_rounds = 0;
                    continue;
                }
                let l0 = l0_files(&db);
                if l0 < trigger {
                    break;
                }
                if Instant::now() > deadline {
                    bail!("L0 still holds {l0} files after an hour of draining");
                }
                idle_rounds += 1;
                if idle_rounds > 600 {
                    bail!("L0 holds {l0} files and no compaction can be picked");
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
    }

    db.close()?;

    println!("Loaded {total} rows");
    Ok(())
}

// ---------------------------------------------------------------------------
// Query: run one SQL statement from stdin via DataFusion.
// ---------------------------------------------------------------------------

async fn query(db_dir: &str, create_sql: Option<&str>) -> Result<()> {
    let db = Arc::new(Db::open_read_only(db_dir, base_options())?);

    let schema_txt = db
        .get(META_SCHEMA)?
        .context("missing schema metadata; run `load` first")?;
    let count_raw = db.get(META_COUNT)?.context("missing row count metadata")?;
    let row_count = u64::from_le_bytes(count_raw.as_slice().try_into()?);

    let mut fields = Vec::new();
    let mut tags = Vec::new();
    for line in std::str::from_utf8(&schema_txt)?.lines() {
        let (name, tag) = line
            .split_once('\t')
            .ok_or_else(|| anyhow!("malformed schema line {line:?}"))?;
        let tag = ColType::from_tag(tag)?;
        fields.push(Field::new(name, tag.arrow_type(), false));
        tags.push(tag);
    }
    let schema = Arc::new(Schema::new(fields));

    let ctx = SessionContext::new();
    ctx.register_table(
        "hits_raw",
        Arc::new(HitsTable { db, schema, tags: Arc::new(tags), row_count }),
    )?;

    if let Some(path) = create_sql {
        let ddl = std::fs::read_to_string(path)?;
        for stmt in ddl.split(';') {
            let stmt = stmt.trim();
            if !stmt.is_empty() {
                ctx.sql(stmt).await?.collect().await?;
            }
        }
    }

    let mut sql = String::new();
    std::io::stdin().read_to_string(&mut sql)?;
    let sql = sql.trim();
    if sql.is_empty() {
        bail!("no query on stdin");
    }

    let start = Instant::now();
    let results = ctx.sql(sql).await?.collect().await?;
    let elapsed = start.elapsed().as_secs_f64();

    if !results.is_empty() {
        println!("{}", pretty_format_batches(&results)?);
    }
    eprintln!("{elapsed:.6}");
    Ok(())
}

// Validation helper (not used by the benchmark): run the same SQL directly
// against the parquet file so results can be diffed against the regolith path.
async fn query_parquet(parquet_path: &str, create_sql: Option<&str>) -> Result<()> {
    let ctx = SessionContext::new();
    {
        let state = ctx.state_ref();
        let mut state = state.write();
        state.config_mut().options_mut().execution.parquet.binary_as_string = true;
    }
    ctx.register_parquet("hits_raw", parquet_path, ParquetReadOptions::default()).await?;

    if let Some(path) = create_sql {
        let ddl = std::fs::read_to_string(path)?;
        for stmt in ddl.split(';') {
            let stmt = stmt.trim();
            if !stmt.is_empty() {
                ctx.sql(stmt).await?.collect().await?;
            }
        }
    }

    let mut sql = String::new();
    std::io::stdin().read_to_string(&mut sql)?;
    let start = Instant::now();
    let results = ctx.sql(sql.trim()).await?.collect().await?;
    let elapsed = start.elapsed().as_secs_f64();
    if !results.is_empty() {
        println!("{}", pretty_format_batches(&results)?);
    }
    eprintln!("{elapsed:.6}");
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("load") if args.len() == 4 => load(&args[2], &args[3]).await,
        Some("query") if args.len() >= 3 => query(&args[2], args.get(3).map(String::as_str)).await,
        Some("queryp") if args.len() >= 3 => {
            query_parquet(&args[2], args.get(3).map(String::as_str)).await
        }
        Some("compact") if args.len() == 3 => {
            let db = Db::open(&args[2], base_options())?;
            db.compact_range(None, None)?;
            db.close()?;
            println!("compacted {}", args[2]);
            Ok(())
        }
        Some("state") if args.len() == 3 => {
            let db = Db::open_read_only(&args[2], base_options())?;
            for prop in ["regolith.levelstats", "regolith.stats"] {
                if let Some(v) = db.get_property(prop) {
                    println!("== {prop} ==\n{v}");
                }
            }
            Ok(())
        }
        _ => {
            eprintln!("usage: hits-regolith load <hits.parquet> <db-dir>");
            eprintln!("       hits-regolith query <db-dir> [create.sql]  (SQL on stdin)");
            std::process::exit(2);
        }
    }
}
