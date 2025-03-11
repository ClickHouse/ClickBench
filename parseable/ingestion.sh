# Download and unzip dataset
wget https://datasets.clickhouse.com/hits_compatible/hits.json.gz
gzip -d hits.json.gz
split -l 2500 hits.json hits_

for file in hits_*; do
    # Add a comma at the end of each line except the last line
    sed '$!s/$/,/' "$file" > temp_file

    # Add "[" at the beginning and "]" at the end
    (echo "["; cat temp_file; echo "]") > "${file}_modified"

    # Replace the original file with the modified one
    mv "${file}_modified" "$file"

    # Clean up
    rm temp_file
done
SCHEMA_FILE="static_schema.json"
curl --location --request PUT 'http://localhost:8000/api/v1/logstream/hits' -H 'X-P-Static-Schema-Flag: true' -H 'Content-Type: application/json'  -u "admin:admin" --data-binary @"${SCHEMA_FILE}"

start_time=$(date +%s)

# Use GNU Parallel to ingest files in parallel
parallel --jobs 8 'curl -H "Content-Type: application/json" -H "X-P-Stream: hits" -k -XPOST -u "admin:admin" "http://localhost:8000/api/v1/ingest" --data-binary @"{}"' ::: hits_*

end_time=$(date +%s)
total_time=$((end_time - start_time))

echo "Total time: ${total_time} seconds"
