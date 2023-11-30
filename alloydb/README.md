
  
# AlloyDB

Note: As of current date, AlloyDB can only be accessed by setting up Alloy Auth Proxy on an EC2 instance or similar.

  
## Setup and benchmark

1. In GCP, setup up AlloyDB Cluster, with a 8 vcpu 64gb primary

2. Setup a EC2 instance with 30gb disk
	a. SSH in and download Alloy Auth Proxy https://cloud.google.com/alloydb/docs/auth-proxy/overview
	```bash
	wget https://storage.googleapis.com/alloydb-auth-proxy/v1.5.0/alloydb-auth-proxy.linux.amd64 -O alloydb-auth-proxy

	chmod +x alloydb-auth-proxy
	```

	b. Grant your Service Account AlloyDB Admin IAM Role.
	c. 5.Restart the VM.

3. Setup Alloy Auth Proxy to connect to the AlloyDB Cluster
	a. Run
	```bash
	./alloydb-auth-proxy projects/PROJECT_ID/locations/REGION_ID/clusters/CLUSTER_ID/instances/INSTANCE_ID
	```
	  
4. Download public dataset and required scripts
```bash
 wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
```
Load scripts in this repo

5. Install PSQL Client and connect to AlloyDB to setup schema and table and load dataset into table
```bash
sudo apt-get install -y postgresql-client
psql -h 127.0.0.1 -p 5432 -U postgres -c 'create database clickbench;'
psql -h 127.0.0.1 -p 5432 -U postgres -d clickbench -a -f create.sql
psql -h 127.0.0.1 -p 5432 -U postgres
\copy hits FROM PROGRAM 'gzip -dc hits.tsv.gz' with (format csv, DELIMITER E'\t', HEADER TRUE);
```

 5. Apply AlloyDB Columnar DB flags
  ```bash
  - google_columnar_engine.enabled
  - google_columnar_engine.enable_columnar_scan
  - google_columnar_engine.enable_vectorized_join
  - google_columnar_engine.memory_size_in_mb -> 32000
  ```

6. Add table to columnar store
```sql
SELECT google_columnar_engine_add(relation => 'hits');
```

7. Add your AlloyDB password in `run.sh`, run `benchmark.sh`

## Tuning

Note: Seems some queries are slower after tuning, especially those that require full table scan

1. Partitioning of table by month of `EventDate` column
2. Indexes on certain columns e.g.  `UserID` and `SearchPhrase`
3. Adjust columnar flags
```bash
- increase columnar memory to 70% of total memory
- increase `max_parallel_workers_per_job` to 8
- increase `vectorized_join_threads` to 4
```
