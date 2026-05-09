#!/bin/bash

# Set input parameters
PG_USER="$1"
PG_PASSWORD="$2"
HOST_NAME=$3
PORT=$4

DATABASE="hits"

# Install dependencies. Hologres is a managed cloud service, so all this
# host needs is a psql client. Pull a postgres docker image once and run
# psql out of it — works on Ubuntu/Debian/Amazon Linux/RHEL alike.
PSQL_IMAGE="postgres:17-alpine"
if ! command -v docker >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -y
        sudo apt-get install -y docker.io
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y docker
    else
        echo "hologres: install docker manually first" >&2
        exit 1
    fi
fi
sudo systemctl start docker 2>/dev/null || sudo service docker start || true
sudo docker pull "$PSQL_IMAGE"

# Drop a `psql` shim into ./bin/ that wraps `docker run`. Adding the dir to
# PATH lets the rest of this script and run.sh call `psql ...` normally —
# including `command time -f '%e' psql ...`, which would skip a bash
# function but does pick up shims found on PATH.
mkdir -p bin
cat > bin/psql <<EOF
#!/bin/bash
exec sudo docker run --rm -i --network host \\
    -e PGUSER -e PGPASSWORD \\
    -v "\$PWD":"\$PWD" -v /tmp:/tmp -w "\$PWD" \\
    "$PSQL_IMAGE" psql "\$@"
EOF
chmod +x bin/psql
export PATH="$PWD/bin:$PATH"

# Set the file name and download link
FILENAME="hits.tsv"

# Check if the file exists
if [ ! -f "$FILENAME" ]; then
    echo "The file $FILENAME does not exist. Starting to download..."
    ../download-hits-tsv
    chmod 777 ~ hits.tsv
    if [ $? -eq 0 ]; then
        echo "File download completed!"
    else
        echo "The download failed. Please check the URL or the network connection. "
        exit 1
    fi
else
    echo "The file $FILENAME already exists. Skipping the download."
fi

# create database and create table
PGUSER=$PG_USER PGPASSWORD=$PG_PASSWORD psql -h $HOST_NAME -p $PORT -d postgres  -t -c "DROP DATABASE IF EXISTS $DATABASE"
sleep 15  # sleep for 15 seconds
PGUSER=$PG_USER PGPASSWORD=$PG_PASSWORD psql -h $HOST_NAME -p $PORT -d postgres  -t -c "CREATE DATABASE $DATABASE"
sleep 15  # sleep for 15 seconds
PGUSER=$PG_USER PGPASSWORD=$PG_PASSWORD psql -h $HOST_NAME -p $PORT -d $DATABASE -t < create.sql 2>&1 | tee load_out.txt
if grep 'ERROR' load_out.txt
then
    exit 1
fi
sleep 15  # sleep for 15 seconds

# split data
echo "Starting to split the file..."
split -l 10000000 hits.tsv hits_part_

# load data
echo "Starting to load data..."
for file in hits_part_*; do
    echo -n "Load time: "
    PGUSER=$PG_USER PGPASSWORD=$PG_PASSWORD command time -f '%e' psql -h $HOST_NAME -p $PORT -d $DATABASE -t -c "\\copy hits FROM '$file'"
done

# run clickbench test with queries
echo "Starting to run queries..."

./run.sh $PG_USER $PG_PASSWORD $HOST_NAME $PORT $DATABASE 2>&1 | tee log_queries_$DATABASE.txt

cat log_queries_$DATABASE.txt | grep -oP 'Time: \d+\.\d+ ms|psql: error' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/; s/^.*psql: error.*$/null/' |
    awk '{ if (i % 3 == 0) { printf "[" }; if ($1 == "null") { printf $1 } else { printf $1 / 1000 }; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }' | tee result_queries_$DATABASE.txt
