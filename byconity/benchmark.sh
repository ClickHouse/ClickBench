#!/bin/bash -e

sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Make sure docker is running
sudo systemctl start docker

docker compose up -d
sleep 5

hdfs/create_users.sh

function byconity()
{
    docker compose exec -T server clickhouse-client --port 52145 "$@"
}
export -f byconity

byconity --time -n < create.sql
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
pigz -fkd hits.tsv.gz

START=$(date +%s)
byconity --database bench --query "INSERT INTO hits FORMAT TSV" < hits.tsv
END=$(date +%s)
echo "Load time: $(echo "$END - $START" | bc)"

# NOTE: sometimes may hung due to docker-compose, using docker directly may help
./run.sh

echo -n "Data size: "
byconity --enable_multiple_tables_for_cnch_parts=1 --query "SELECT sum(bytes_on_disk) FROM system.cnch_parts WHERE table = 'hits' AND database = 'bench'"

docker compose down --volumes
