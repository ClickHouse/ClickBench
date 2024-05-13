TRIES=3

cd opteryx

python -m opteryx "SELECT version()" 2>&1

cat ../queries.sql | while read query; do
    echo "$query"
    python3 -m opteryx "$query" --cycles 3 --o "null.parquet" 2>&1
done;