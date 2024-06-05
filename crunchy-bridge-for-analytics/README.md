
[Crunchy Bridge for Analytics](https://docs.crunchybridge.com/analytics) allows users to query parquet files on S3 directly. It also automatically downloads files accessed to a local disk to avoid network delays. 

To best represent the default production behavior of our system,  we benchmark the `(Parquet, Local)` scenario  where:
- 'Parquet' we directly use `hits.parquet` from `s3://clickhouse-public-datasets`
- 'Local': We load the `hits.parquet` file to a local disk drive on the machine running the service. In this scenario, it is expected that 'cold run' and 'hot run' results will be similar

1) Setup the cluster:

- Go to https://crunchybridge.com/
- Click `Create Cluster` -> `Create Analytics Cluster`
- Choose Region (`eu-central-1`) where `s3://clickhouse-public-datasets/hits_compatible/hits.parquet` is
- Click `Analytics-256`
- Click `Create Cluster`
- Step Two: Set Up Analytics Credentials: Click "Skip for now"
- Wait until the state of the machine becomes "Running"

2) Get the connection string:

- Click the "Connection" tab from the left menu
- Pick role: application, Format psql
- Click "Copy"

3) Set the `CONNCMD` that we are going to use with what you copied in (2): 
```bash
export CONNCMD='psql postgres://application:XXXX@XXXXX.postgresbridge.com:5432/postgres'
```

4) Create the table, load the data:
```bash
 $CONNCMD -c '\timing' -f create.sql
```


5) Run the script:
```bash
 ./run.sh 
 ```
