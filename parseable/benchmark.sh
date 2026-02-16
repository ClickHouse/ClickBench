# Install Dependencies
sudo apt-get update -y
sudo apt-get install -y parallel
# Determine instance type based on CPU and memory
CPU_COUNT=$(nproc)

if [ $CPU_COUNT -ge 190 ]; then
    export P_EXECUTION_BATCH_SIZE=75000
    echo "Setting P_EXECUTION_BATCH_SIZE=75000 (detected c6a.metal equivalent)"
elif [ $CPU_COUNT -ge 15 ]; then
    export P_EXECUTION_BATCH_SIZE=40000
    echo "Setting P_EXECUTION_BATCH_SIZE=40000 (detected c6a.4xlarge equivalent)"
else
    # Default for other configurations
    export P_EXECUTION_BATCH_SIZE=1000000
    echo "Using default P_EXECUTION_BATCH_SIZE=1000000 for default configuration"
fi

# Download Parseable v2.5.11 binary
wget --continue --progress=dot:giga https://github.com/parseablehq/parseable/releases/download/v2.5.11/Parseable_OSS_x86_64-unknown-linux-gnu
mv Parseable_OSS_x86_64-unknown-linux-gnu parseable
chmod +x parseable

# Run Parseable
export RUST_LOG=warn
export P_CPU_THRESHOLD=100
export P_MEMORY_THRESHOLD=100

./parseable local-store > parseable.log 2>&1 & PARSEABLE_PID=$!
# Verify Parseable is running
if ps -p $PARSEABLE_PID > /dev/null; then
    echo "Parseable is running with PID: $PARSEABLE_PID"
else
    echo "Error: Parseable failed to start. Check parseable.log for details."
    exit 1
fi

chmod +x ingestion.sh
chmod +x run_query.sh

#run ingestion script
echo -n "Load time: "
command time -f '%e' ./ingestion.sh

#run query script
./run_query.sh

#view results
cat result.csv | sed -r -e 's/^([0-9\.]+) ([0-9\.]+) ([0-9\.]+)$/[\1, \2, \3]/'

echo -n "Data size: "
du -bcs local-store | grep total

#kill parseable
kill $PARSEABLE_PID
