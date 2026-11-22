// HoloDb ClickBench service-mode tool (holodb-server\tool). Built from the existing holodb\tool loader plus the client.
//   load    <db dir> <hits.parquet> <create.sql> [rows]   the official loader, unchanged: writes <db dir>/holo and <db dir>/holo.tables
//                                                         (paged layout) and closes the database cleanly. Offline: the server must be stopped.
//   query   --port P --pin-file F --token-file T           reads one SQL statement on stdin, prints the rows on stdout, and the
//                                                         client-timed round trip in seconds as the LAST stderr line. Connection not timed.
//   check   --port P --pin-file F --token-file T           exit 0 when the server answers a Ping over TLS with the token.
//   version
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using DuckDB.NET.Native;
using HoloDb;
using HoloDb.Client;

return args.Length == 0 ? Usage() : args[0] switch
{
    "load" when args.Length >= 4 => Loader.Run(args[1], args[2], args[3], args.Length > 4 ? long.Parse(args[4], CultureInfo.InvariantCulture) : long.MaxValue),
    "query" => await Remote.QueryAsync(args),
    "check" => await Remote.CheckAsync(args),
    "version" => Version(),
    _ => Usage()
};

static int Usage() { Console.Error.WriteLine("load <db dir> <hits.parquet> <create.sql> [rows] | query --port P --pin-file F --token-file T < sql | check --port P --pin-file F --token-file T | version"); return 2; }
static int Version() { Console.WriteLine("holodb " + typeof(Database).Assembly.GetName().Version + "  client " + typeof(HoloDbClient).Assembly.GetName().Version); return 0; }

// The client side of the benchmark. One process per call, like the ClickBench query script expects.
internal static class Remote
{
    static (int port, string pinFile, string tokenFile) Parse(string[] args)
    {
        int port = 5432; string pin = "", token = "";
        for (int i = 1; i + 1 < args.Length; i += 2)
            switch (args[i])
            {
                case "--port": port = int.Parse(args[i + 1], CultureInfo.InvariantCulture); break;
                case "--pin-file": pin = args[i + 1]; break;
                case "--token-file": token = args[i + 1]; break;
                default: throw new ArgumentException("unknown option " + args[i]);
            }
        return (port, pin, token);
    }

    // TLS on, the dev certificate pinned by the thumbprint the server printed at start (no trust-all). The read timeout is
    // raised above the server's statement limit: a 60 s default would poison the session on a long statement.
    static Task<HoloDbClient> ConnectAsync(string[] args)
    {
        var (port, pin, token) = Parse(args);
        var options = new HoloDbClientOptions
        {
            AuthToken = File.ReadAllText(token).Trim(),
            PinnedThumbprint = File.ReadAllText(pin).Trim(),
            ReadTimeout = TimeSpan.FromMinutes(15),
        };
        return HoloDbClient.ConnectAsync("127.0.0.1", port, options, TimeSpan.FromSeconds(10));
    }

    public static async Task<int> QueryAsync(string[] args)
    {
        try
        {
            // The official text says STRLEN, which DuckDB defines as the byte length; the standard spelling is OCTET_LENGTH (same bytes, same answers).
            string sql = (await Console.In.ReadToEndAsync()).Trim().Replace("STRLEN(", "OCTET_LENGTH(");
            await using var db = await ConnectAsync(args);   // not timed: connection setup and the TLS handshake
            var sw = Stopwatch.StartNew();
            var r = await db.ExecuteAsync(sql);
            sw.Stop();   // the statement round trip (send, execute, receive, decode the result); printing the rows is the tool's presentation and is not timed
            var sb = new StringBuilder();
            int nc = r.Columns.Count;
            for (int i = 0; i < r.RowCount; i++)
            {
                for (int c = 0; c < nc; c++)
                {
                    if (c > 0) sb.Append('\t');
                    var v = r.GetValue(i, c);
                    sb.Append(v switch { null => "NULL", DBNull => "NULL", double d => d.ToString("R", CultureInfo.InvariantCulture), IFormattable f => f.ToString(null, CultureInfo.InvariantCulture), _ => v.ToString() ?? "" });
                }
                sb.Append('\n');
            }
            Console.Out.Write(sb.ToString());
            Console.Error.WriteLine(sw.Elapsed.TotalSeconds.ToString("F3", CultureInfo.InvariantCulture));
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("query failed: " + e.Message);
            return 1;
        }
    }

    public static async Task<int> CheckAsync(string[] args)
    {
        try
        {
            await using var db = await ConnectAsync(args);
            return await db.PingAsync() ? 0 : 1;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("check failed: " + e.Message);
            return 1;
        }
    }
}

internal static unsafe class Loader
{
    sealed record Col(string Name, string Type);

    static List<Col> ParseCreate(string sql)
    {
        int a = sql.IndexOf('('), b = sql.LastIndexOf(')');
        var cols = new List<Col>();
        foreach (var part in sql.Substring(a + 1, b - a - 1).Split(','))
        {
            var t = part.Trim(); if (t.Length == 0) continue;
            int sp = t.IndexOfAny(new[] { ' ', '\t', '\r', '\n' });
            cols.Add(new Col(t[..sp], t[(sp + 1)..].Trim()));
        }
        return cols;
    }

    sealed class ByteBuf
    {
        public byte[] B = new byte[1 << 16]; public int N;
        public void Add(byte* p, int len)
        {
            if (N + len > B.Length) Array.Resize(ref B, (int)Math.Max((long)B.Length * 2, (long)N + len));
            new ReadOnlySpan<byte>(p, len).CopyTo(B.AsSpan(N)); N += len;
        }
    }

    sealed class Block { public int Rows; public object[] Data = null!; }

    sealed class Source : IDisposable
    {
        readonly DuckDBDatabase _db; readonly DuckDBNativeConnection _con; readonly string _from; readonly List<Col> _cols;
        public Source(string parquet, List<Col> cols)
        {
            _cols = cols; _from = parquet.Replace('\\', '/');
            if (NativeMethods.Startup.DuckDBOpen(null, out _db) != DuckDBState.Success) throw new Exception("duckdb open failed");
            if (NativeMethods.Startup.DuckDBConnect(_db, out _con) != DuckDBState.Success) throw new Exception("duckdb connect failed");
            // The parquet reader must not take what the loader needs (DuckDB's default limit is 80 percent of RAM): 12 percent of physical memory, at most 4 GB; threads = cores, at most 8.
            long mb = Math.Max(256, Math.Min(4L << 30, GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / 100 * 12) >> 20);
            // a streaming read holds a row group per reader thread (about 100 MB each): DuckDB fails with an out-of-memory error when the limit is below that; threads = the limit / 192 MB, at most min(cores, 8)
            int threads = (int)Math.Max(1, Math.Min(Math.Min(Environment.ProcessorCount, 8), mb / 192));
            Console.WriteLine($"duckdb memory_limit {mb} MB, threads {threads}");
            foreach (var s in new[] { $"SET memory_limit='{mb}MB'", $"SET threads={threads}" })
            {
                if (NativeMethods.Query.DuckDBQuery(_con, s, out var r0) != DuckDBState.Success) throw new Exception("duckdb: " + s);
                r0.Close();
            }
        }
        public void Dispose() { _con.Dispose(); _db.Dispose(); }

        public long Count()
        {
            if (NativeMethods.Query.DuckDBQuery(_con, $"SELECT COUNT(*) FROM read_parquet('{_from}')", out var r) != DuckDBState.Success) throw new Exception("count failed");
            try { var ch = NativeMethods.Query.DuckDBFetchChunk(r); var v = NativeMethods.DataChunks.DuckDBDataChunkGetVector(ch, 0); long n = *(long*)NativeMethods.Vectors.DuckDBVectorGetData(v); ch.Dispose(); return n; }
            finally { r.Close(); }
        }

        string SelectList()
        {
            var sb = new StringBuilder();
            foreach (var c in _cols)
            {
                if (sb.Length > 0) sb.Append(", ");
                string e = c.Name switch
                {
                    "EventDate" => "make_date(EventDate)",
                    "EventTime" => "epoch_ms(EventTime * 1000)",
                    "ClientEventTime" => "epoch_ms(ClientEventTime * 1000)",
                    "LocalEventTime" => "epoch_ms(LocalEventTime * 1000)",
                    _ => c.Name
                };
                sb.Append($"CAST({e} AS {CastType(c.Type)}) AS {c.Name}");
            }
            return sb.ToString();
        }
        static string CastType(string t)
        {
            t = t.ToUpperInvariant().Replace("NOT NULL", "").Trim();
            return t.StartsWith("TEXT") || t.StartsWith("VARCHAR") || t.StartsWith("CHAR") ? "VARCHAR" : t;
        }

        // Accumulates DuckDB chunks into typed arrays; a few chunks are held and every column is copied by its own worker (a text column's bytes stay in order inside one worker).
        sealed class Builder
        {
            readonly List<Col> _cols; readonly object[] _data; readonly ByteBuf?[] _bufs; readonly int[][] _offs; readonly int _cap;
            public int Row;
            public Builder(List<Col> cols, int cap)
            {
                _cols = cols; _cap = cap; int nc = cols.Count;
                _data = new object[nc]; _bufs = new ByteBuf?[nc]; _offs = new int[nc][];
                for (int c = 0; c < nc; c++)
                {
                    string ty = cols[c].Type.ToUpperInvariant();
                    if (ty.StartsWith("SMALLINT")) _data[c] = new short[cap];
                    else if (ty.StartsWith("INTEGER") || ty.StartsWith("INT ") || ty == "INT" || ty.StartsWith("DATE")) _data[c] = new int[cap];
                    else if (ty.StartsWith("BIGINT") || ty.StartsWith("TIMESTAMP")) _data[c] = new long[cap];
                    else { _offs[c] = new int[cap + 1]; _bufs[c] = new ByteBuf(); }
                }
            }
            public void Absorb(List<DuckDBDataChunk> chunks, List<int> sizes)
            {
                int start = Row, total = 0; foreach (int s in sizes) total += s;
                if (start + total > _cap) throw new Exception("block capacity exceeded");
                Parallel.For(0, _cols.Count, c => { int row = start; for (int k = 0; k < chunks.Count; k++) { Fill(c, chunks[k], sizes[k], row); row += sizes[k]; } });
                Row = start + total;
                foreach (var ch in chunks) ch.Dispose();
                chunks.Clear(); sizes.Clear();
            }
            void Fill(int c, DuckDBDataChunk ch, int n, int row)
            {
                var vec = NativeMethods.DataChunks.DuckDBDataChunkGetVector(ch, c);
                void* p = NativeMethods.Vectors.DuckDBVectorGetData(vec);
                ulong* valid = NativeMethods.Vectors.DuckDBVectorGetValidity(vec);
                if (valid != null) for (int i = 0; i < n; i++) if ((valid[i >> 6] & (1UL << (i & 63))) == 0) throw new Exception($"NULL in column {_cols[c].Name}");
                switch (_data[c])
                {
                    case short[] s: new ReadOnlySpan<short>(p, n).CopyTo(s.AsSpan(row, n)); break;
                    case int[] iv: new ReadOnlySpan<int>(p, n).CopyTo(iv.AsSpan(row, n)); break;
                    case long[] l: new ReadOnlySpan<long>(p, n).CopyTo(l.AsSpan(row, n)); break;
                    default:
                        {
                            var bb = _bufs[c]!; var of = _offs[c]; byte* sp = (byte*)p;
                            for (int i = 0; i < n; i++)
                            {
                                byte* e = sp + (long)i * 16; uint len = *(uint*)e;
                                byte* chars = len <= 12 ? e + 4 : *(byte**)(e + 8);
                                bb.Add(chars, (int)len); of[row + i + 1] = bb.N;
                            }
                            break;
                        }
                }
            }
            public Block Finish()
            {
                var data = (object[])_data.Clone();
                for (int c = 0; c < data.Length; c++) if (data[c] == null) data[c] = new Utf8Column(_bufs[c]!.B, _offs[c]);
                return new Block { Rows = Row, Data = data };
            }
        }

        // ONE streaming query for the whole load (duckdb_query would materialise the whole result first): blocks of about blockRows rows in file order. No per-range query, no row group read twice.
        public IEnumerable<Block> Stream(long total, int blockRows)
        {
            string sql = $"SELECT {SelectList()} FROM read_parquet('{_from}', binary_as_string=True) LIMIT {total}";
            if (NativeMethods.PreparedStatements.DuckDBPrepare(_con, sql, out var stmt) != DuckDBState.Success) throw new Exception("duckdb prepare failed: " + sql);
            try
            {
                if (NativeMethods.PreparedStatements.DuckDBExecutePreparedStreaming(stmt, out var result) != DuckDBState.Success) throw new Exception("duckdb streaming execute failed: " + NativeMethods.Query.DuckDBResultError(ref result));
                try
                {
                    bool eof = false;
                    while (!eof)
                    {
                        var b = new Builder(_cols, blockRows + 2048);   // a chunk is at most 2048 rows
                        var chunks = new List<DuckDBDataChunk>(); var sizes = new List<int>(); int held = 0;
                        while (b.Row + held < blockRows)
                        {
                            var ch = NativeMethods.StreamingResult.DuckDBStreamFetchChunk(result);
                            int n = ch.IsInvalid ? 0 : (int)NativeMethods.DataChunks.DuckDBDataChunkGetSize(ch);
                            if (n == 0)
                            {
                                if (!ch.IsInvalid) ch.Dispose();
                                string? err = NativeMethods.Query.DuckDBResultError(ref result);   // a failed streaming fetch also returns no chunk: never read it as the end of the data
                                if (!string.IsNullOrEmpty(err)) throw new Exception("duckdb read failed: " + err);
                                eof = true; break;
                            }
                            chunks.Add(ch); sizes.Add(n); held += n;
                            if (held >= 16384) { b.Absorb(chunks, sizes); held = 0; }
                        }
                        if (chunks.Count > 0) b.Absorb(chunks, sizes);
                        var blk = b.Finish();
                        if (blk.Rows > 0) yield return blk;
                    }
                }
                finally { result.Close(); }
            }
            finally { stmt.Dispose(); }
        }
    }

    public static int Run(string dir, string parquet, string createFile, long maxRows)
    {
        const int range = 1 << 18;
        var create = File.ReadAllText(createFile);
        var cols = ParseCreate(create);
        if (Directory.Exists(dir)) { Console.Error.WriteLine($"{dir} exists: delete it first"); return 1; }
        Directory.CreateDirectory(dir);
        var sw = Stopwatch.StartNew();
        var db = Database.Open(Path.Combine(dir, "holo"), 8L * 1024 * 1024, paged: true);
#if HOLODB_DIALECT
        db.Dialect = SqlDialect.Extended;   // LIMIT, DATE_TRUNC and REGEXP_REPLACE are Extended; needs a HoloDb that has Database.Dialect (define HOLODB_DIALECT)
#endif
        db.Execute(create);
        var names = cols.Select(c => c.Name).ToArray();
        using var ds = new Source(parquet, cols);
        long total = Math.Min(ds.Count(), maxRows);
        Console.WriteLine($"loading {total:N0} rows x {cols.Count} columns");
        var q = new BlockingCollection<Block>(1);
        var prod = new Thread(() =>
        {
            try { foreach (var blk in ds.Stream(total, range)) q.Add(blk); }
            catch (Exception ex) { Console.Error.WriteLine("reader failed: " + ex); Environment.Exit(1); }
            finally { q.CompleteAdding(); }
        }) { IsBackground = true };
        prod.Start();
        long done = 0;
#if HOLODB_MULTIBLOCK
        // package versions with BulkLoadColumns(table, cols, IEnumerable<ColumnBlock>): the whole load is ONE atomic bulk load, one commit, the seal summed on every core
        IEnumerable<ColumnBlock> Pull()
        {
            foreach (var blk in q.GetConsumingEnumerable())
            {
                yield return new ColumnBlock(blk.Data, blk.Rows);
                done += blk.Rows;
                if ((done / range) % 40 == 0) Console.WriteLine($"  {done:N0} rows  {sw.Elapsed.TotalSeconds:F1}s");
            }
        }
        db.BulkLoadColumns("hits", names, Pull());
#else
        foreach (var blk in q.GetConsumingEnumerable())
        {
            db.BulkLoadColumns("hits", names, blk.Data, blk.Rows);
            done += blk.Rows;
            if ((done / range) % 40 == 0) Console.WriteLine($"  {done:N0} rows  {sw.Elapsed.TotalSeconds:F1}s");
        }
#endif
        db.Close();
        Console.WriteLine($"loaded {done:N0} rows in {sw.Elapsed.TotalSeconds:F1}s");
        return 0;
    }
}
