# Disclaimer

Benchmarking a database often requires deep expertise and fine-tuning. Here, our goal is merely to test the default experience of a new
user, i.e. someone who does not invest the time to optimize performance.

Testing is semi-automatized.

The system as a timeout of 10s, after that it recommends to optimize (rewrite) the query.

Load time and data size in the results are set to 0 as Tinybird did not indicate these resources.

# Creating an account

Head to https://www.tinybird.co and create an account.

# Inserting data

Tinybird supports data inserts from various sources. We are going to use S3 to load a Parquet file into Tinybird. Since Tinybird limits the
file size to 1 GB and the test data set is larger than that, we split it into smaller chunks using ClickHouse:

```sql
INSERT INTO FUNCTION s3('https://hitsparquet.s3.eu-west-3.amazonaws.com/data/hits_{_partition_id}.parquet', '', '', 'Parquet')
PARTITION BY rand() % 50
SELECT * FROM hits
```

Import of files with sizes a little bit less than 1 GB did not always work. We instead used 50 files of around 280 MB each. You will need to
use the auto mode to make sure all the files are read.

# Querying the data

Once the data is inserted you can create the endpoints needed to run the benchmark using pipes. `run.sh` will iterate through each endpoint.
