#!/bin/bash

# Server setup Install
sudo apt install docker.io -y
sudo usermod -aG docker ${USER}
sudo systemctl start docker

# You must log out, then back into the VM at this point for Docker to work...

# Run the GizmoSQL server in the background with Docker
docker run --name gizmosql \
           --detach \
           --rm \
           --tty \
           --init \
           --publish 31337:31337 \
           --pull always \
           --mount type=bind,source=/nfs_data,target=/opt/gizmosql/data \
           --env GIZMOSQL_USERNAME=clickbench \
           --env GIZMOSQL_PASSWORD=clickbench \
           --env DATABASE_FILENAME=/opt/gizmosql/data/clickbench.db \
           gizmodata/gizmosql:latest

# Install Java and the GizmoSQLLine CLI client
sudo apt install openjdk-17-jre-headless -y
pushd /tmp
curl -L -o gizmosqlline https://github.com/gizmodata/gizmosqlline/releases/latest/download/gizmosqlline
chmod +x gizmosqlline
sudo mv gizmosqlline /usr/local/bin/
popd

# Create the table
gizmosqlline \
  -u 'jdbc:arrow-flight-sql://localhost:31337?useEncryption=true&disableCertificateVerification=true' \
  -n clickbench \
  -p clickbench \
  -f create.sql

# Load the data
pushd /nfs_data
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'
popd

echo -n "Load time: "
time gizmosqlline \
  -u 'jdbc:arrow-flight-sql://localhost:31337?useEncryption=true&disableCertificateVerification=true' \
  -n clickbench \
  -p clickbench \
  -f load.sql

# Run the queries
script --quiet --command="./run.sh" log.txt

# Remove carriage returns from the log
sed -i 's/\r$//' log.txt

echo -n "Data size: "
wc -c /nfs_data/clickbench.db

cat log.txt | \
  grep -E 'rows? selected \([0-9.]+ seconds\)|Killed|Segmentation' | \
  sed -E 's/.*rows? selected \(([0-9.]+) seconds\).*/\1/; s/.*(Killed|Segmentation).*/null/' | \
  awk '{
    if (NR % 3 == 1) printf "[";
    if ($1 == "null") printf "null";
    else printf $1;
    if (NR % 3 == 0) printf "],\n";
    else printf ", ";
  }'
