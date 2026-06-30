# Disclaimer

The test is done on Tinybird Free trial. 

Benchmarking a database often requires deep expertise and fine-tuning. Here, our goal is merely to test the default experience of a new
user, i.e. someone who does not invest the time to optimize performance.

Testing is semi-automated.

The system has a timeout of 10s; after that, it recommends to optimize (rewrite) the query.

Load time and data size in the results are set to 0, as Tinybird did not indicate these resources.

# Creating an account

Head to https://www.tinybird.co and create an account.

Install the Tinybird CLI and authenticate it against the workspace you want to use for the benchmark:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install tinybird-cli
tb auth -i
```

`tb auth -i` asks for the Tinybird region and an admin token. You can copy the admin token from the "Tokens" page in the Tinybird UI.
The command writes credentials to a local `.tinyb` file, so do not commit that file.

# Inserting data

Tinybird supports data inserts from various sources. We are going to use S3 to load a Parquet file into Tinybird. Since Tinybird limits the
file size to 1 GB, and the test data set is larger than that, we split it into smaller chunks using ClickHouse:

```bash
clickhouse-client --query "
INSERT INTO FUNCTION s3(
    'https://<bucket>.s3.<region>.amazonaws.com/<prefix>/hits_{_partition_id}.parquet',
    '<aws_access_key_id>',
    '<aws_secret_access_key>',
    'Parquet'
)
PARTITION BY rand() % 50
SELECT * FROM hits
"
```

Run this from a ClickHouse instance where the ClickBench `hits` table has already been loaded. Replace the S3 URL and credentials with a
bucket/prefix that Tinybird can read. After the `INSERT` finishes, create a Tinybird Data Source named `hits` from the generated
`hits_*.parquet` files, choose Parquet as the format, and use auto mode so all files in the prefix are imported.

Importing files with sizes a little bit less than 1 GB did not always work. We instead used 50 files of around 280 MB each. You will need to
use the auto mode to make sure all the files are read.

# Querying the data

Once the data is inserted you can create the endpoints needed to run the benchmark using pipes. `run.sh` will iterate through each endpoint.

Create one Tinybird Pipe endpoint for each query in `clickhouse/queries.sql`. The endpoint names must be `Q1`, `Q2`, ..., `Q43`, because
`run.sh` calls `/v0/pipes/Q${i}.json`. You can create them in the UI, or generate them with the CLI from this directory:

```bash
i=1
while IFS= read -r query; do
    tb pipe generate "Q${i}" "$query" --force
    i=$((i + 1))
done < ../clickhouse/queries.sql

tb push pipes/*.pipe
```

Create and copy a token for the benchmark runner. In a dedicated benchmark workspace, the simplest CLI command is:

```bash
tb token create static clickbench_read --scope WORKSPACE:READ_ALL
tb token copy clickbench_read
```

Alternatively, create a more restrictive token in the Tinybird UI with `PIPES:READ` access to the `Q1` through `Q43` pipes. Then run the
benchmark from this directory:

```bash
TINYBIRD_TOKEN='<copied token>' ./run.sh 2>&1 | tee log.txt
```
