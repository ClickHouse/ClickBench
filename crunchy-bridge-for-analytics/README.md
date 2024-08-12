
[Crunchy Bridge for Analytics](https://docs.crunchybridge.com/analytics) allows users to query parquet files on S3 directly.


1) Setup the cluster:

- Go to https://crunchybridge.com/
- Click `Create Cluster` -> `Create Analytics Cluster`
- Choose Region (`eu-central-1`) where `s3://clickhouse-public-datasets/hits_compatible/hits.parquet` is
- Click `Analytics-256`
- Click `Create Cluster`
- Step Two: Set Up Analytics Credentials: Click "Skip for now"
- Wait until the state of the machine becomes "Running"

2) Setup a VM on `aws` in the same region as the cluster `eu-central-1`.

This is to make sure the latency between the server and the client is not high. We are going to need `psql` on this VM, so you should install `sudo yum install -y postgresql16` etc. depending on the linux distro.


3) Get the application connection strings:

3.1) Application connection
- Click the "Connection" tab from the left menu
- Pick role: application, Format psql
- Click "Copy"

 Set the `APPCONNCMD` that we are going to use with what you copied above:
```bash
export APPCONNCMD='psql postgres://application:XXXX@XXXXX.postgresbridge.com:5432/postgres'
```

3.2) Get the postgres connection string:

- Click the "Connection" tab from the left menu
- Pick role: postgres, Format psql
- Click "Copy"

Set the `SUPERUSERCONNCMD` that we are going to use with what you copied above:
```bash
export SUPERUSERCONNCMD='psql postgres://postgres:XXXX@XXXX.postgresbridge.com:5432/postgres'
```

4) Run the script:
```bash
 ./run.sh 
 ```

For the cold run, we directly access to S3 while running the queries. For the warm runs, we first download the file from S3 to a local cache drive, then run the queries. This logic is coded into `run.sh ` script.
