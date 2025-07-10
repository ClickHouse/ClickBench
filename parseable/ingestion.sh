#!/bin/bash

echo "Installing Parallel pigz pv..."
sudo apt-get update -y && sudo apt-get install -y parallel pigz pv

# Set number of cores for parallel processing
NUM_CORES=$(nproc)

echo "Downloading dataset..."
wget --progress=bar:force --show-progress https://datasets.clickhouse.com/hits_compatible/hits.json.gz

echo "Decompressing dataset..."
# Get file size for progress reporting
FILE_SIZE=$(stat -c %s hits.json.gz)
pv -s $FILE_SIZE hits.json.gz | pigz -d > hits.json

# Split file into chunks of 2500 lines and process them
echo "Splitting file and processing chunks in parallel..."

# Create partitioned directory if it doesn't exist
mkdir -p partitioned

# Define processing function that will be applied immediately after splitting
split_and_process() {
    local chunk_num=$1
    local content=$(cat)
    local output_file="./partitioned/hits_${chunk_num}.json"

    # Format with brackets and commas in one step
    (
        echo "["
        echo "$content" | sed '$!s/$/,/'
        echo "]"
    ) > "$output_file"
}
export -f split_and_process

LINES_PER_CHUNK=2500

pv hits.json | parallel --pipe -N$LINES_PER_CHUNK --block 10M \
    --jobs $NUM_CORES split_and_process {#}

echo "Split and process complete"

# Remove original file
rm hits.json

# Create stream
echo "Creating stream..."
SCHEMA_FILE="static_schema.json"
curl --silent --location --request PUT 'http://localhost:8000/api/v1/logstream/hits' \
     -H 'X-P-Static-Schema-Flag: true' \
     -H 'Content-Type: application/json' \
     -u "admin:admin" \
     --data-binary @"${SCHEMA_FILE}"

# Ingest files in parallel with progress monitoring
echo "Ingesting files..."

INGEST_JOBS=6
start_time=$(date +%s)
find . -name "hits_*" -type f | parallel --progress --jobs $INGEST_JOBS \
    'curl --silent -H "Content-Type: application/json" -H "X-P-Stream: hits" -k -XPOST -u "admin:admin" "http://localhost:8000/api/v1/ingest" --data-binary @"{}"'

#sleep for 3 minutes to allow sync to complete
sleep 180

end_time=$(date +%s)
total_time=$((end_time - start_time))

echo "Total load (ingestion) time: ${total_time} seconds"
