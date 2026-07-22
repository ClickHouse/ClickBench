# GenDB-style code generation brief

You are writing one optimized C++17 program that answers a single
ClickBench SQL query against pre-built, mmap'd binary column files for the
`hits` table. This is the "Code Generator" stage of GenDB's pipeline.

## Hard constraints
- **Output**: write exactly one file to `/home/ubuntu/ClickBench/gendb/generated/q<N>.cpp`. No extras.
- **No verbose narration**: the source code itself is the deliverable.
- **Compile target**: `g++ -std=c++17 -O3 -march=native -fopenmp`. Already wired.
- **Inputs to your binary**: `argv[1]` = `gendb_dir` (a path containing `hits/<col>.bin`, `hits/<col>_off.bin`, `hits/<col>_data.bin`). Print the result on stdout (CSV-ish, header line first). Emit timing via `gendb::WallClock _wc;` as the very first statement in `main` — it auto-prints `time: <secs>` on scope exit.
- **Row count is the constant** `gendb::HITS_ROWS` (= 99,997,497).

## Existing infrastructure (read these first)
- `/home/ubuntu/ClickBench/gendb/utils/storage.h` — `mmap_col<T>(dir, col)`, `mmap_strcol(dir, col) -> {off, data, n}`, `str_contains/str_eq_lit/str_nonempty/str_len/str_get`.
- `/home/ubuntu/ClickBench/gendb/utils/timing.h` — `gendb::WallClock`.
- `/home/ubuntu/ClickBench/gendb/utils/topn.h` — `gendb::TopK<T, Less>` min-heap top-K.
- `/home/ubuntu/ClickBench/gendb/utils/hashmap.h` — `gendb::HashMap<K,V>`, `gendb::mix64`, `gendb::Pair64`.
- `/home/ubuntu/ClickBench/gendb/storage_layout.json` — per-column dtype map (int8/int16/int32/int64/string).

## Reference cpp files to study
- `q1.cpp` — trivial COUNT(*)
- `q2.cpp` — branchless reduction with `#pragma omp parallel for reduction(+:total)`
- `q3.cpp` — multi-column reduction
- `q4.cpp` — long-double precision for big sums
- `q5.cpp` — open-addressing hashset for COUNT(DISTINCT)
- `q8.cpp` — small-cardinality flat-array hashtable (`int16` group key, NBUCK=65536)
- `q13.cpp` — string-keyed hashtable + TopK for `GROUP BY string ORDER BY count DESC LIMIT`

## Patterns to follow
- **Always parallelize the scan** with `#pragma omp parallel for schedule(static)` and per-thread state to merge afterwards. The inner loop runs 100M times; everything outside it doesn't matter.
- **For fixed-width grouping keys with small range** (int8/int16, or columns known to fit in <1M values): use a flat int64 array indexed by the key, not a hash table.
- **For high-cardinality grouping keys**: open-addressing hashmap with `gendb::mix64` (int64) or `gendb::mix32` (int32). Per-thread maps + serial merge.
- **For string grouping**: hash on byte range, store `(hash, offset_into_data, len, count)`. On collision compare via `memcmp` against the original data buffer. See `q13.cpp` for a complete pattern.
- **For COUNT(DISTINCT)** of integers: open-addressing hashset with a sentinel.
- **For LIKE '%pat%'**: use `memmem` via `gendb::str_contains`.
- **For top-N**: `gendb::TopK<>` (min-heap of size K).
- **For aggregations**: use `int64_t` for COUNT and SUM of small ints; `long double` for SUM of `int64` (UserID), then convert to double for AVG output.

## Schema highlights (see storage_layout.json for the full list)
- `WatchID, UserID, FUniqID, ParamPrice, RefererHash, URLHash` → int64
- `JavaEnable, GoodEvent, IsRefresh, IsMobile, AdvEngineID, IsArtifical, OS, UserAgent, ResolutionWidth, ResolutionHeight, IsLink, IsDownload, DontCountHits, …` → int16 (most enum-like and boolean-ish cols are smallint in the schema)
- `EventTime, EventDate, ClientEventTime, LocalEventTime, CounterID, ClientIP, RegionID, RefererRegionID, URLRegionID, IPNetworkID, RemoteIP, WindowName, OpenerName, HID, SilverlightVersion3, CodeVersion, *Timing, CLID` → int32
- `HitColor` → int8
- `Title, URL, Referer, FlashMinor2, UserAgentMinor, MobilePhoneModel, Params, SearchPhrase, PageCharset, OriginalURL, BrowserLanguage, BrowserCountry, SocialNetwork, SocialAction, SocialSourcePage, ParamOrderID, ParamCurrency, OpenstatServiceName, OpenstatCampaignID, OpenstatAdID, OpenstatSourceID, UTMSource, UTMMedium, UTMCampaign, UTMContent, UTMTerm, FromTag` → string (use `mmap_strcol`)

## EventDate / EventTime encoding
- `EventDate.bin` is `int32` days since 1970-01-01. The value for `'2013-07-01'` is **15887**; `'2013-07-31'` is **15917**; `'2013-07-14'` = 15900; `'2013-07-15'` = 15901.
- `EventTime.bin` is `int32` Unix epoch seconds. To extract `minute(EventTime)` for Q19/Q43, use `(EventTime % 3600) / 60` (UTC minute-within-hour) for Q19. For Q43 `DATE_TRUNC('minute', EventTime)` use `EventTime / 60 * 60`.

## What "correct enough" means for ClickBench
- ClickBench compares timings, **not result rows** — the harness does not diff output. As long as your binary prints non-empty stdout and exits 0, the timing is recorded.
- Still produce correct results; the maintainers spot-check.
- Floating-point sums in different parallel orders are fine.

## Output of your work
Write one .cpp at `/home/ubuntu/ClickBench/gendb/generated/q<N>.cpp` and stop. Do **not** write anything else, do not compile, do not run.
