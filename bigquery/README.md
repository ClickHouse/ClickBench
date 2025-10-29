As of 2025, Google Bigquery allow publishing benchmark results, which was not the case earlier.

Download Google Cloud CLI:
```
wget --continue --progress=dot:giga https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
tar -xf google-cloud-cli-linux-x86_64.tar.gz
./google-cloud-sdk/install.sh
source .bashrc
./google-cloud-sdk/bin/gcloud init
```

Create the dataset and table:
```
./create.sh
```

Load the data:
```
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
gzip -d -f hits.csv.gz

echo -n "Load time: "
command time -f '%e' bq load --source_format CSV --allow_quoted_newlines=1 test.hits hits.csv
```

Run the benchmark:

```
pip install google-cloud-bigquery
python3 run_queries.py > results.txt 2> log2.txt
```
