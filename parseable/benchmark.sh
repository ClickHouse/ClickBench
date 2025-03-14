# Install Dependencies
sudo apt-get update -y
sudo apt-get install -y rustup parallel
rustup update stable


# Clone Parseable Repository and checkout v1.7.3 branch
git clone https://github.com/parseablehq/parseable.git
cd parseable
git checkout main

# Build and Run Parseable
cargo build --release
export PATH="`pwd`/target/release:$PATH"
export RUST_LOG=info
./target/release/parseable local-store > parseable.log 2>&1 & PARSEABLE_PID=$!
# Verify Parseable is running
if ps -p $PARSEABLE_PID > /dev/null; then
    echo "Parseable is running with PID: $PARSEABLE_PID"
else
    echo "Error: Parseable failed to start. Check parseable.log for details."
    exit 1
fi

cd ..

chmod +x ingestion.sh
chmod +x run_query.sh

#run ingestion script
./ingestion.sh

#sleep for 3 minutes to allow sync to complete
sleep 180

#run query script
./run_query.sh

#view results
cat result.csv

#kill parseable
kill $PARSEABLE_PID
