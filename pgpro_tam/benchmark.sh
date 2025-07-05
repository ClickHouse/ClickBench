#!/bin/bash

#Usage:
#./benchmark.sh parquet_fd
#./benchmark.sh parquet_mem_fd
#./benchmark.sh parquet_fd_parall
#./benchmark.sh feather_mem_fd

#install docker
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker.io

#install postgres client; postgres server is inside docker container
sudo apt-get install -y postgresql-client

#calculate target shm size (in mb) as a half of available memory and run postgres container
MEM_SIZE=$(grep MemTotal /proc/meminfo | awk '{print $2}')
SHM_SIZE=$(echo "$MEM_SIZE/2/1024" | bc)
sudo docker run --shm-size="$SHM_SIZE"m -p5432:5432 --name pgpro_tam -e POSTGRES_HOST_AUTH_METHOD=trust -d innerlife/pgpro_tam:0.0.1

#wait for postgres startup and create extension
sleep 10
psql -h 127.0.0.1 -U postgres -t -c "create extension ppg_tam"

#create table
if [ "$1" != "parquet_fd" ] && [ "$1" != "parquet_mem_fd" ] && [ "$1" != "parquet_fd_parall" ] && \
    [ "$1" != "feather_mem_fd" ] && [ "$1" != "" ]; then
    echo "Error: command line argument must be one of {'parquet_fd', 'parquet_mem_fd', 'parquet_fd_parall', 'feather_mem_fd'}"
    exit 1
fi
if [ ! -z "$1" ]; then
    CREATE_FILE="$1"
else
    CREATE_FILE="parquet_fd"
fi
psql -h 127.0.0.1 -U postgres -t < create/"$CREATE_FILE".sql

#get and unpack hits.tsv
sudo docker exec pgpro_tam bash -c "cd /tmp && wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz' && gzip -d -f hits.tsv.gz"

#insert data to table
if [ "$1" == "parquet_fd_parall" ] ; then
    #insert data in parallel; not ordered insert is much faster, but breaks query performance
    sudo docker exec pgpro_tam bash -c "time cat /tmp/hits.tsv | parallel -l 2000000 -j 50 -N1 -k --spreadstdin 'psql -U postgres -t -c \"copy hits FROM STDIN\"'"
else
    echo -n "Load time: "
    command time -f '%e' psql -h 127.0.0.1 -U postgres -t -c "COPY hits FROM '/tmp/hits.tsv'"
fi

#run benchmark
./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
sudo docker exec pgpro_tam du -bcs /var/lib/postgresql/data/base

#parse logfile for query execution time
cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
