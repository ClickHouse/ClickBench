Disclaimer: I am not an expert in optimizing Elasticsearch for analytical workloads, so this benchmark uses a "naive" deployment of Elasticsearch with no attempt at any performance optimizations. I also used the Elasticsearch SQL API to generate the queries, which may not always utilize all the power of Elasticsearch aggregations framework. It is likely possible to achieve better results by tuning Elasticsearch as well as rewriting these queries using Elasticsearch native query DSL.

Methodology

Infrastructure:
- Local single-node install of Elasticsearch 9.1 on AWS EC2 instance c6a.4xlarge

Data loading process: 
- Create index mappings manually, mirroring data types after the ClickHouse benchmark, and using index sorting on the same fields ClickHouse chose for primary keys
- Stream data directly from .gz file into Elasticsearch with a python script. Streaming directly from .gz likely slightly reduces the load time but is accepted as a trade off for a shorter and less complex overall benchmark run.  

Running the benchmark: 
- Benchmark run is semi-automated: Manually run through steps one by one in `benchmark.sh` in bash, but `run.sh` is provided to run the queries and produce results automatically
- Because OFFSET is not supported by Elasticsearch https://github.com/elastic/elasticsearch/issues/31549, the last 5 queries were modified to replace LIMIT x OFFSET y with LIMIT x+y 
- I ran into problems using the SQL API directly (some queries would inexplicably stall), but if I used the SQL Translate API and then passed the resulting JSON to Search API, queries completed. 
- Only one query did not run due to lack of support for REGEXP_REPLACE.
- The queries with `COUNT(DISTINCT)` (Q5, Q6, Q9, Q10, Q11, Q12, Q14, Q23) are written in the query DSL rather than SQL (`query` sends a line that starts with `{` to the Search API as it is): the SQL translates `COUNT(DISTINCT)` to the `cardinality` aggregation, which is approximate (HyperLogLog++). Instead, a `scripted_metric` collects the exact set of values: as a sub-aggregation where the groups are ordered by the count (Q10, Q23), and as one top-level `scripted_metric` with a set per group, sorted in its reduce script, where the groups are ordered by the distinct count (Q9, Q11, Q12, Q14). The requests are the same as in `../opensearch`.

Budget some time to run the benchmark:
- Install and data prep process can take up to an hour.
- Data loading process takes a bit under 3 hours. 
- Running the benchmark takes about 2 hours, because of one long-running query which takes 25 minutes x 3 times. 

UPDATE: Added a "tuned" result for Elasticsearch, after going through repeated benchmark to find the optimal Elasticsearch shard number and size for this resource type and workload. This type of tuning is recommended by Elastic ([example](https://www.elastic.co/blog/how-many-shards-should-i-have-in-my-elasticsearch-cluster)), but generally is considered an advanced task for experienced operators. More optimal number of shards (4 in my testing) resulted in 2x improvement in indexing speed and average query performance, at the trade-off of ~13% increase in storage size. 
