Bytehouse is a derivative of ClickHouse.
It is based on very old ClickHouse version (20.4.54418) and many features are unsupported.

https://bytehouse.cloud/signup

Sign Up. Only Asia-Pacific South-East 1 AWS region is available. Verify email.

Create virtual warehouse. Size L.

Go to "Databases" and create database "test".

Go to "SQL Worksheet" and copy-paste create.sql query there.

Note: S3 import does not support public buckets. And it requires pasting secret access key, which we are not going to do. So, switch to using CLI.

Create a machine in ap-southeast-1 region and install Bytehouse CLI:

```
wget https://github.com/bytehouse-cloud/cli/releases/download/v1.5.34/bytehouse-cli_1.5.34_Linux_x86_64.tar.gz
tar xvf bytehouse-cli_1.5.34_Linux_x86_64.tar.gz
```

```
export user='...'
export password='...'
export account='AWS...'
export warehouse='test'
```

```
wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
gzip -d hits.csv.gz
```

Load the data:

```
time ./bytehouse-cli --user "$user" --account "$account" --password "$password" --region ap-southeast-1 --secure --warehouse "$warehouse" --query "INSERT INTO test.hits FORMAT CSV" < hits.csv
```

```
99,997,497 total rows sent, 0 rows/s (81.14 GB, 0.00 B/s)
total rows sent: 99,997,497, average speed = 134,320 rows/s
Elapsed: 12m24.754608947s. 81.14 GB (108.94 MB/s).
─── End of Execution ───

real    12m25.310s
```

Run the benchmark:

```
./run.sh 2>&1 | tee log.txt 

cat log.txt | grep --text -F 'Elapsed' | 
    grep --text -oP 'Elapsed: [\d\.]+(ms|s)\. Processed: \d+ row' | 
    sed -r -e 's/Elapsed: ([0-9\.]+)(ms|s)\. Processed: ([0-9]+) row/\1 \2 \3/' | 
    awk '{ if ($3 == 0) { print "null" } else if ($2 == "ms") { print $1 / 1000 } else { print $1 } }' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
```

Note: cluster size L is the maximum that can be created.
An attempt to create XL gives "Failed AWAITING RESOURCES". 
