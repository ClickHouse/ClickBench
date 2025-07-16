#!/bin/bash

# Install

sudo apt-get update -y
sudo apt-get install -y default-jre-headless apt-transport-https

sudo apt-get install -y docker.io
sudo docker run -it --rm -v $(pwd):/host ubuntu:18.04 cp /lib/x86_64-linux-gnu/libtinfo.so.5 /host/
sudo cp libtinfo.so.5 /usr/lib/x86_64-linux-gnu/

sudo useradd -U -m heavyai
sudo curl https://releases.heavy.ai/GPG-KEY-heavyai | sudo apt-key add -
echo "deb https://releases.heavy.ai/os/apt/ stable cpu" | sudo tee /etc/apt/sources.list.d/heavyai.list
sudo apt-get update -y
sudo apt-get install heavyai -y

export HEAVYAI_USER=heavyai
export HEAVYAI_GROUP=heavyai
export HEAVYAI_STORAGE=/var/lib/heavyai
export HEAVYAI_PATH=/opt/heavyai
export HEAVYAI_LOG=/var/lib/heavyai/data/mapd_log

pushd $HEAVYAI_PATH/systemd
./install_heavy_systemd.sh
popd

# Press Enter multiple times.

sudo systemctl start heavydb
sudo systemctl enable heavydb

# Load the data

../lib/download-csv.sh
chmod 777 ~ hits.csv

sudo bash -c "echo 'allowed-import-paths = [\"$(pwd)\"]' > /var/lib/heavyai/heavy.conf_"
sudo bash -c "cat /var/lib/heavyai/heavy.conf >> /var/lib/heavyai/heavy.conf_"
sudo bash -c "mv /var/lib/heavyai/heavy.conf_ /var/lib/heavyai/heavy.conf && chown heavyai /var/lib/heavyai/heavy.conf"
sudo systemctl restart heavydb

/opt/heavyai/bin/heavysql -t -p HyperInteractive < create.sql
echo -n "Load time: "
command time -f '%e' /opt/heavyai/bin/heavysql -q -t -p HyperInteractive <<< "COPY hits FROM '$(pwd)/hits.csv' WITH (HEADER = 'false');"

# Loaded: 99997497 recs, Rejected: 0 recs in 572.633 secs

./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
du -bcs /var/lib/heavyai/ | grep total

cat log.txt | grep -P 'Total time|null' | sed -r -e 's/^.*Total time: ([0-9]+) ms$/\1/' |
  awk '{ if ($1 == "null") { print } else { print $1 / 1000 } }' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
