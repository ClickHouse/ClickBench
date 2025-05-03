# Timescale Cloud

### Running the Benchmark 

1. Create a [Timescale Cloud Account](https://console.cloud.timescale.com/signup). 
   - This benchmark can be executed with a trial account.
1. Create a new "Time series and analytics" service with the desired benchmark compute size.
1. Install the [psql connection tool](https://docs.timescale.com/use-timescale/latest/integrations/query-admin/psql/) if necessary.
1. Once the service is ready use the provided connection string to import the dataset:  

   ```bash
   wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
   gzip -d -f hits.tsv.gz
   
   export $CONNECTION_STRING=...  
   time ./load.sh 
   ```

1. Find the datasize:
   ```bash
   psql "$CONNECTION_STRING" -c "SELECT hypertable_size('hits');"    
   ```

1. Run the and benchmark the queries:

   ```bash
   ./run.sh 2>&1 | tee log.txt
   
   cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
     awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
   ```
