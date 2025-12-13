## [ClickBench](https://benchmark.clickhouse.com/) Changelog

Changes in the benchmark methodology or presentation, as well as major news.

### 2025-12-10
Added the first GPU database to the benchmark, Sirius (Yifei Yang). Added a new selector, which allows to choose CPU or GPU databases in the report (Robert Schulze).

### 2025-11-16
Distinguish lukewarm runs (legacy) and [true cold runs](https://github.com/ClickHouse/ClickBench/pull/692). (Robert Schulze)

### 2025-10-26
Do not include in-memory databases in "cold" and "combined" ratings, because they cannot have comparable results for cold runs (requested by puz-puz-puz Andrey). (Alexey Milovidov)

### 2025-09-29
Add [changelog](https://github.com/ClickHouse/ClickBench/blob/main/CHANGELOG.md) for ClickBench (requested by Andy Pavlo). (Alexey Milovidov)

### 2025-09-10
Change the default comparison metric to [combined](https://github.com/ClickHouse/ClickBench/pull/616). (Robert Schulze).

### 2025-08-31
Additionally improve the automation scripts, so they can launch the benchmarks in the AWS environment in any region with no prerequisites, and the final JSON reports are [generated automatically](https://github.com/ClickHouse/ClickBench/pull/596) by materialized views. Create template files for JSON reports for every automated entry. This allows quickly updating results for many systems on all combinations of machines. The [script](https://github.com/ClickHouse/ClickBench/blob/547db775545098319b078d191f4b62be2a5c0987/run-benchmark.sh) is absolutely trivial to use. (Alexey Milovidov)

### 2025-08-28
For consistency, every entry in the benchmark now resides in its own directory. For example, there is a separate directory for the run on "partitioned" and "non-partitioned" Parquet files. This makes it easier to run each entry in an automated way uniformly.

### 2025-07-11
I changed the way how the page URL looks like. Now they are compressed and readable, so it's easy to share the reports.

Now most of the systems have been re-run automatically and updated. So it is easy to change the machine where ClickBench runs, add new machines, change or correct the dataset or the set of queries.

Split JSON data out from the HTML page. Now it makes updating it simpler, but as a downside, it is less convenient copying index.html to [Pastila](https://pastila.nl/).

I've re-run tests and added results for new machine types. The most important is adding Graviton 4 machine. Also, I've added smaller machines, so in addition to c6a.4xlarge (16 vCPU, 32 GB RAM) now we have c6a.2xlarge (16 GB RAM), c6a.xlarge (8 GB RAM, this corresponds to the smallest cloud instance), c6a.large (4 GB RAM), and even t3a.small (2 GB RAM). On 16 GB and less, many systems, such as Umbra, CedarDB and Hyper drop out, and on 4 GB RAM, DuckDB drops out, and finally, on t3a.small, only ClickHouse runs all queries without errors. This proves that ClickHouse is better suited for "small data" than other databases.

Comparing on smaller machine sizes makes the separation of certain differences clearer. The most visible outcome is that ClickHouse doesn't have min/max indices by default, we don't skip granules based on the range of already selected data with ORDER BY .. LIMIT, and we don't optimize GROUP BY without aggregate functions with ORDER BY and LIMIT.

I've also made selectors more convenient. It will dim the options that add no data to the report. E.g., if you choose "open-source only" on one selector, it will dim all systems that are not open-source.

(Alexey Milovidov)

### 2025-07-04
Changed the way how ClickHouse loads the dataset. We provide an option of three data formats (csv, tsv, parquet) to choose. Until recently, ClickHouse used the most conservative option of sequentially loading a tsv file with a single INSERT statement, while other systems took effort to choose the most optimal option. I've noticed that the other system loaded data in 30 seconds while ClickHouse in 120 seconds, but the problem is that we didn't pay attention for this benchmark as much as our competitors. After replacing with loading from parquet files on the server-side, the loading time for ClickHouse is lowered to just 9 seconds, and became the best in the benchmark with a huge margin.

Some ClickHouse derivative systems, such as Ursa from Maksim Kita, and ClickHouse with Tencent optimizations missed results on one of two hardware choices. I've added the missing results, and it makes ClickHouse-derivative systems presented with more entries at the top.

Added a "combined" report, which does weighted average of storage size, load time, hot and cold runs with 10%, 10%, 60%, 20%. It shows that ClickHouse is overall the best open-source database. While the cold runs are slightly unfair for certain systems, such as stateless ClickHouse over Web server and ClickHouse Cloud, as well as for in-memory databases, we can correct it in the future.

Now the main chart makes it easy to see the difference on 1x..10,000x scale.
This is a visualization type in between of "horizon chart" and "compressed-scale bar chart". I didn't see this type of visualization anywhere before. Last days I've opened https://benchmark.clickhouse.com/ about hundred of times and every time I'm surprised how gorgeous it looks!
The downside it that earlier there was no noticeable difference on the chart between the top systems, including ClickHouse, but now they are easily distinguishable.

The systems on the main chart are distinguished by color (systems from the same family get the same color), so they are easy to group visually. Made the system names more concise by removing unnecessary information.

Added the "open-source" and "proprietary" tags, so that you can list only open-source databases. For the reference, Umbra, Hyper, and CedarDB are proprietary.

Removed pointless tags, that some systems attribute to themself. One system misattributed itself as "mysql-compatible", two others added tags with their names, another reported two programming languages, a few systems reported an "analytical" tag, which is pointless, and one system didn't report itself as "ClickHouse-derivative" while being based on the ClickHouse interfaces and architecture.

Some systems provided bogus results on the loading time or data size. For example, one system reported data size 1000 times less, and we didn't notice that. This was corrected. The comparison on the loading time will not include stateless systems that don't require data loading.

Made the list of machines sorted by the number of systems and then by alphabetical order, which makes it easy to select machines from the list.

Made progress on the full automation of the benchmark. ClickBench is designed to be semi-automated, so the entrants have to provide a reproducible shell script, but it might be needed to run commands from the script manually step by step. Now the scripts are designed to run in a fully unattended fashion within a fresh virtual machine. Most of self-managed systems are able to re-run, but about 20% of work is still pending.

This will allow us to do things like: - add more datasets sizes to the benchmark; - add more queries to the benchmark; - add new machines, e.g., ARM based. I have a few more ideas on the automation of the benchmark. This will bring new life to the benchmark while keeping it easy and maintainable (you cannot support ~100 different databases without keeping it easy).

(Alexey Milovidov)

### 2025-06-27
Displaying the tuned results can be toggled with [a button](https://github.com/ClickHouse/ClickBench/pull/416). (Robert Schulze)

### 2025-02-28
Add a new benchmark, [FastFormats](https://fastformats.clickhouse.com/) comparing the performance on data formats using ClickHouse.  Website by Alexey Milovidov, scripts and methodology by Tom Schreiber.

### 2025-02-04
Add a new benchmark, [JSONBench](https://jsonbench.com/) for analytics on semistructured data. Website by Alexey Milovidov, scripts and methodology by Tom Schreiber.

### 2024-11-08
Add a [new benchmark](https://pastila.nl/?000b1ba6/c224ddf960900f4f2d0d9e100cef5445.html) to compare all generations of AWS Graviton. (Alexey Milovidov)

### 2023-09-13
Add an [action](https://github.com/ClickHouse/ClickBench/pull/136) to run the benchmark on ClickHouse Cloud every day. From now on, it automatically updates daily. (Alexey Milovidov)

### 2023-08-01
Add [GitHub Action](https://github.com/ClickHouse/ClickBench/pull/31) to regenerate the website HTML automatically. (jychen7)

### 2022-10-14
Allow ["tuned"](https://github.com/ClickHouse/ClickBench/pull/31) results to demonstrate optimization opportunities. However, these results are not shown by default and are out of competition. (Alexey Milovidov)

### 2022-08-14
Introduce ["XXL" benchmark](https://github.com/ClickHouse/ClickBench/pull/19) with the dataset up to one trillion records and 100 TB in size. However, it is not used for comparison. (Alexey Milovidov)

### 2022-08-08
Introduce [versions benchmark](https://benchmark.clickhouse.com/versions/), which allows to compare performance of ClickHouse versions over time on a combination of ClickBench + Star Schema Benchmark + Brown University mgBench + NYC Taxi benchmark. The results are back-filled up to very early ClickHouse versions. (Ilya Yatsishin)

### 2022-07-13
Now the benchmark has a new name, **ClickBench**. The scripts are rewritten for simplification, and [now the benchmark is 100% reproducible](https://github.com/ClickHouse/ClickHouse/pull/38437). All dataset sizes except 100 million are removed. The dataset is reconstructed to be compatible with most SQL databases  Added many new systems, so now the benchmark [has 29 of entries](https://github.com/ClickHouse/ClickHouse/pull/38437/files#diff-7fe6b01752be42136da1c4bfcc273aa482497b35192a5af3fc46027766c59ae1R191)! Now it allows having SaaS as well as self-hosted databases. In addition to DBMS, allow testing of stateless data engines on top of local and remote files. From now on, adding a new system is no longer reflected in this changelog. Also, a few old systems are removed (Hive, Vertica). Created a methodology and rules for the benchmark. Rewrite the benchmark's website. Move ClickBench in its [own GitHub repository](https://github.com/ClickHouse/ClickBench/) while retaining most of the history. (Alexey Milovidov)

### 2020-09-22
Introduce [hardware benchmark](https://benchmark.clickhouse.com/hardware/), which allows to compare performance of various hardware configurations on ClickHouse. It contains a diverse set of bleeding edge, vintage, and experimental hardware, as well as clouds. (Alexey Milovidov)

### 2020-08-16
Introduce usability reports while adding new systems, [MonetDB](https://github.com/ClickHouse/ClickHouse/blob/ea611e8f73d41d6a8f1eb21db05ef56d112ac3d3/benchmark/monetdb/usability.md), [DuckDB](https://github.com/ClickHouse/ClickHouse/blob/6ab92f70a17a8d586e2cb42f1f3673144227b806/benchmark/duckdb/usability.md), [TimescaleDB](https://github.com/ClickHouse/ClickHouse/blob/4801ab58aa29d0eb5e40ec5a19fa414cc408c4ea/benchmark/timescaledb/usability.md). (Alexey Milovidov)

### 2019-04-08
The dataset has been anonymized with the new [clickhouse-obfuscator](https://github.com/ClickHouse/ClickHouse/tree/master/programs/obfuscator) tool, the benchmark queries are updated to use the obfuscated dataset, and most of the results are also updated. The dataset is published in the documentation and available for downloads. Now it does no longer contain sensitive production data, but retains the data distribution and compression characteristics. (Alexey Milovidov).

### 2016-06-15
The benchmark is now [available publicly](https://presentations.clickhouse.com/original_website/benchmark.html) with the [ClickHouse release in open-source](https://presentations.clickhouse.com/original_website/) (Alexey Milovidov).

### 2015-04-05
Added MemSQL (which is now known as SingleStore) and updated Vertica (Alexey Milovidov).

### 2013-09-23
First version of the benchmark with ClickHouse, Hive, InfiniDB, Infobright, MonetDB, Vertica. The website (by Alexey Milovidov) published in the internal network.

### 2013-08-15
Project starts with the goal of evaluating column-oriented databases. The data is obtained from production, around 1/50 of one week of the Internet traffic, captured by Yandex Metrica around summer 2013. Three datasets are derived from it, total 10 million, 100 million, and 1 billion records. The list of 43 queries are prepared by Alexey Milovidov and test scripts are prepared by Pavel Kartaviy.
