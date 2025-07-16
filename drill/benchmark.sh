# Install

sudo apt-get update -y
sudo apt-get install -y docker.io

../lib/download-parquet.sh

./run.sh 2>&1 | tee log.txt

cat log.txt | grep -P '\([\d\.]+ seconds\)|Errors' | sed -r -e 's/Errors:/null/; s/^.+\(([.0-9]+) seconds\)/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

echo "Data size: $(du -b hits.parquet)"
echo "Load time: 0"
