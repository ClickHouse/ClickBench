Google's [General Service Terms](https://cloud.google.com/terms/service-terms/index-20230814) allow benchmarking under certain conditions (i.e. no DeWitt clause):

```
7. Benchmarking. Customer may conduct benchmark tests of the Services (each a "Test"). Customer may only publicly disclose the results of
   such Tests if (a) the public disclosure includes all necessary information to replicate the Tests, and (b) Customer allows Google to
   conduct benchmark tests of Customer's publicly available products or services and publicly disclose the results of such tests.
   Notwithstanding the foregoing, Customer may not do either of the following on behalf of a hyperscale public cloud provider without
   Google's prior written consent: (i) conduct (directly or through a third party) any Test or (ii) disclose the results of any such Test.
```

It's very difficult to find, how to create a database.
Databases are named "datasets". You need to press on `⋮` near project.

Create dataset `test`.
Go to the query editor and paste the contents of `create.sql`.
It will take two seconds to create a table.

Download Google Cloud CLI:
```
wget https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
tar -xf google-cloud-cli-linux-x86_64.tar.gz
./google-cloud-sdk/install.sh
source .bashrc
./google-cloud-sdk/bin/gcloud init
```

Load the data:
```
wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
gzip -d hits.csv.gz

time bq load --source_format CSV --allow_quoted_newlines=1 test.hits hits.csv
```

Run the benchmark:

```
./run.sh 2>&1 | tee log.txt

cat log.txt |
  grep -P '^real|^Error' |
  sed -r -e 's/^Error.*$/null/; s/^real\s*([0-9.]+)m([0-9.]+)s$/\1 \2/' |
  awk '{ if ($2) { print $1 * 60 + $2 } else { print $1 } }' |
  awk '{ if ($1 == "null") { skip = 1 } else { if (i % 3 == 0) { printf "[" }; printf skip ? "null" : $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; skip = 0; } }'
```
