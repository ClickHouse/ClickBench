// ClickBench harness for SlateDB (https://slatedb.io).
//
// SlateDB is an embedded LSM-tree key-value store that keeps all of its
// state in an object store; here the object store is the local filesystem.
// It has no query language, so this harness stores each row of the hits
// dataset as one key-value pair (key = 8-byte big-endian row index, value =
// a compact positional row encoding) and runs the ClickBench SQL through
// Apache DataFusion with a custom TableProvider whose partitions are
// parallel SlateDB range scans.
//
// Usage:
//   hits-slatedb load  <hits.parquet> <db-dir>
//   hits-slatedb query <db-dir> [create.sql]   # SQL statement on stdin

use std::io::Read;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use anyhow::{anyhow, bail, Context, Result};
use async_trait::async_trait;
use futures::stream::{self, StreamExt, TryStreamExt};

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

use slatedb::bytes::Bytes;
use slatedb::config::{CompressionCodec, ScanOptions, Settings, WriteOptions};
use slatedb::object_store::local::LocalFileSystem;
use slatedb::object_store::ObjectStore;
use slatedb::{Db, DbReader, SstBlockSize, WriteBatch};

// Row keys are 8-byte big-endian indexes, so they sort in row order and any
// key starting with 0xff sorts after all of them (the dataset has far fewer
// than 2^56 rows).
const META_SCHEMA: &[u8] = b"\xffschema";
const META_COUNT: &[u8] = b"\xffcount";
const BATCH_ROWS: usize = 8192;
const DB_PATH: &str = "hits";

fn row_key(i: u64) -> [u8; 8] {
    i.to_be_bytes()
}

fn object_store(db_dir: &str) -> Result<Arc<dyn ObjectStore>> {
    Ok(Arc::new(LocalFileSystem::new_with_prefix(db_dir)?))
}

fn db_settings() -> Settings {
    Settings {
        // The load is a bulk import with an explicit flush at the end;
        // writing a WAL on top of the SSTs would only double the I/O.
        wal_enabled: false,
        compression_codec: Some(CompressionCodec::Zstd),
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
                        // The dataset comes from ClickHouse where strings are
                        // raw bytes; reinterpret without validation, exactly
                        // like DataFusion's own `binary_as_string` option.
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
// DataFusion integration: TableProvider + ExecutionPlan over SlateDB scans.
// ---------------------------------------------------------------------------

fn ext_err(e: slatedb::Error) -> DataFusionError {
    DataFusionError::External(Box::new(e))
}

struct HitsTable {
    db: Arc<DbReader>,
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
        let partitions = (state.config().target_partitions() as u64).min(max_parts) as usize;
        Ok(Arc::new(SlateScanExec::new(
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

struct SlateScanExec {
    db: Arc<DbReader>,
    tags: Arc<Vec<ColType>>,
    projection: Vec<usize>,
    out_schema: SchemaRef,
    row_count: u64,
    partitions: usize,
    limit: Option<usize>,
    props: Arc<PlanProperties>,
}

impl SlateScanExec {
    #[allow(clippy::too_many_arguments)]
    fn new(
        db: Arc<DbReader>,
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
        SlateScanExec { db, tags, projection, out_schema, row_count, partitions, limit, props }
    }
}

impl std::fmt::Debug for SlateScanExec {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "SlateScanExec")
    }
}

impl DisplayAs for SlateScanExec {
    fn fmt_as(&self, _t: DisplayFormatType, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(
            f,
            "SlateScanExec: rows={}, partitions={}, projection={:?}",
            self.row_count, self.partitions, self.projection
        )
    }
}

impl ExecutionPlan for SlateScanExec {
    fn name(&self) -> &str {
        "SlateScanExec"
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

    fn execute(
        &self,
        partition: usize,
        _context: Arc<TaskContext>,
    ) -> DFResult<SendableRecordBatchStream> {
        let chunk = self.row_count.div_ceil(self.partitions as u64);
        let lo = (partition as u64) * chunk;
        let hi = ((partition as u64 + 1) * chunk).min(self.row_count);
        let db = self.db.clone();
        let mut remaining = self.limit.unwrap_or(usize::MAX);
        let decoder = Decoder::new(self.tags.clone(), &self.projection, self.out_schema.clone());

        let batches = stream::once(async move {
            let opts = ScanOptions {
                read_ahead_bytes: 4 << 20,
                max_fetch_tasks: 2,
                cache_blocks: false,
                ..Default::default()
            };
            let iter = if lo < hi {
                let range = Bytes::copy_from_slice(&row_key(lo))..Bytes::copy_from_slice(&row_key(hi));
                Some(db.scan_with_options(range, &opts).await.map_err(ext_err)?)
            } else {
                None
            };
            Ok::<_, DataFusionError>(stream::try_unfold(
                (iter, decoder),
                move |(mut iter, mut decoder)| async move {
                    let Some(it) = iter.as_mut() else {
                        return Ok(None);
                    };
                    while decoder.rows < BATCH_ROWS && remaining > 0 {
                        match it.next().await.map_err(ext_err)? {
                            Some(kv) => {
                                decoder.push_row(&kv.value);
                                remaining -= 1;
                            }
                            None => break,
                        }
                    }
                    if decoder.rows == 0 {
                        Ok(None)
                    } else {
                        let batch = decoder.finish()?;
                        Ok(Some((batch, (iter, decoder))))
                    }
                },
            ))
        })
        .try_flatten();

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

// ---------------------------------------------------------------------------
// Load: hits.parquet -> SlateDB.
// ---------------------------------------------------------------------------

async fn load(parquet_path: &str, db_dir: &str) -> Result<()> {
    std::fs::create_dir_all(db_dir)?;
    let db = Arc::new(
        Db::builder(DB_PATH, object_store(db_dir)?)
            .with_settings(db_settings())
            .with_sst_block_size(SstBlockSize::Block64Kib)
            .build()
            .await?,
    );

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

    let streams = df.execute_stream_partitioned().await?;
    let counter = Arc::new(AtomicU64::new(0));
    let mut handles = Vec::new();
    for mut s in streams {
        let db = db.clone();
        let tags = tags.clone();
        let counter = counter.clone();
        handles.push(tokio::spawn(async move {
            let wopts = WriteOptions { await_durable: false, ..Default::default() };
            while let Some(batch) = s.next().await {
                let batch = batch?;
                let rows = encode_rows(&batch, &tags)?;
                let base = counter.fetch_add(rows.len() as u64, Ordering::Relaxed);
                let mut wb = WriteBatch::new();
                for (i, row) in rows.iter().enumerate() {
                    wb.put(row_key(base + i as u64), row);
                }
                db.write_with_options(wb, &wopts).await?;
            }
            Ok::<_, anyhow::Error>(())
        }));
    }
    for h in handles {
        h.await??;
    }

    let total = counter.load(Ordering::Relaxed);
    let mut wb = WriteBatch::new();
    wb.put(META_COUNT, total.to_le_bytes());
    wb.put(META_SCHEMA, schema_txt.as_bytes());
    db.write_with_options(wb, &WriteOptions { await_durable: false, ..Default::default() })
        .await?;
    db.flush().await?;
    db.close().await?;
    println!("Loaded {total} rows");
    Ok(())
}

// ---------------------------------------------------------------------------
// Query: run one SQL statement from stdin via DataFusion.
// ---------------------------------------------------------------------------

async fn query(db_dir: &str, create_sql: Option<&str>) -> Result<()> {
    let reader = Arc::new(DbReader::builder(DB_PATH, object_store(db_dir)?).build().await?);

    let schema_txt = reader
        .get(META_SCHEMA)
        .await?
        .context("missing schema metadata; run `load` first")?;
    let count_raw = reader.get(META_COUNT).await?.context("missing row count metadata")?;
    let row_count = u64::from_le_bytes(count_raw.as_ref().try_into()?);

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
        Arc::new(HitsTable { db: reader, schema, tags: Arc::new(tags), row_count }),
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
// against the parquet file so results can be diffed against the SlateDB path.
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
        _ => {
            eprintln!("usage: hits-slatedb load <hits.parquet> <db-dir>");
            eprintln!("       hits-slatedb query <db-dir> [create.sql]  (SQL on stdin)");
            std::process::exit(2);
        }
    }
}
