Disclaimer: I am not an expert in optimizing Elasticsearch for analytical workloads, so this benchmark uses a "naive" deployment of Elasticsearch with no attempt at any performance optimizations. I also used the Elasticsearch SQL API to generate the queries, which may not always utilize all the power of Elasticsearch aggregations framework. It is likely possible to achieve better results by tuning Elasticsearch as well as rewriting these queries using Elasticsearch native query DSL.

Methodology:
- Local install of Elasticsearch 8.3 on AWS EC2 instance c6a.4xlarge
- Per instructions, started with 500GB EBS gp2 per instructions, but ran out of space loading data in Elasticsearch abou a third in, and expanded to 1.5TB

Data loading process: 
- Create index mappings manually, mirroring data types after the ClickHouse benchmark, and using index sorting on the same fields ClickHouse chose for primary keys
- Split JSON file into smaller files and load them sequentially into Elasticsearch via Bulk API

Running the benchmark: 
- Benchmark run is semi-automated: Manually run through steps one by one in `benchmark.sh` in bash, but `run.sh` is provided to run the queries and produce results automatically
- Because OFFSET is not supported by Elasticsearch https://github.com/elastic/elasticsearch/issues/31549, the last 5 queries were modified to replace LIMIT x OFFSET y with LIMIT x+y 
- I ran into problems using the SQL API directly (some queries would inexplicably stall), but if I used the SQL Translate API and then passed the resulting JSON to Search API, queries completed. 
- Only one query did not run due to lack of support for REGEXP_REPLACE.

Budget some time to run the benchmark:
- Install and data prep process can take up to an hour.
- Data loading process takes a bit under 3 hours. 
- Running the benchmark takes about 2 hours, because of one long-running query which takes 25 minutes x 3 times. 
