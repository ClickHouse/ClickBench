# Tablespace
Tablespace is a cloud-native Postgres database platform for running Hybrid Transactional and Analytic queries (HTAP) on Postgres using columnstore indexes.

* [Homepage](https://www.tablespace.io/)
* [Dashboard](https://cloud.tablespace.io)

## Running the benchmark
This benchmark is semi-automated
1. Navigate to https://cloud.tablespace.io and register.
2. Create a new `LARGE-1` database. The `LARGE-1` shape which has `16 CPUs` and `32GB of RAM` was used for this benchmark. 
This has similar specs to `c6a.4xlarge`. 
3. Make a note of the `hostname` and `password`. 
4. For your test client create a VM that is close to the database region in East US. e.g. Oracle Cloud `us-ashburn-1` (closest) or AWS `us-east-1`. 
5. Download the test scripts to this VM and install `psql`.
6. In the `benchmark.sh` and `run.sh` scripts, replace `<hostname>` and `<password>` with the values from step 3.
7. Run the `benchmark.sh` script. This will create a table, load data into it, and run a benchmark. Data is automatically loaded into the `csschema` in the `csdb` database.
