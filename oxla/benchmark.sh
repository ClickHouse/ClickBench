#!/bin/bash

# docker
sudo rm /usr/share/keyrings/docker-archive-keyring.gpg
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce

# base
sudo apt-get install -y postgresql-client curl wget apt-transport-https ca-certificates software-properties-common gnupg2
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential

# ruby and fake S3
sudo apt install -y ruby-full
sudo gem install bundler fakes3 webrick sorted_set

# install aws cli tools
sudo rm /usr/local/bin/aws
sudo rm /usr/local/bin/aws_completer
sudo rm -rf /usr/local/aws-cli
sudo rm -rf ~/.aws/ aws

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install --update
/usr/local/bin/aws --version
rm -f awscliv2.zip

# configure aws
mkdir -p ~/.aws
echo -e "[default]\nregion = none" > ~/.aws/config
echo -e "[default]\naws_access_key_id = none\naws_secret_access_key = none" > ~/.aws/credentials

# run fake S3
ps aux | grep fakes3 | grep -v grep | awk '{print $2}' | xargs -r kill -9

sudo rm -rf /mnt/fakes3_root
sudo mkdir -p /mnt/fakes3_root
sudo chmod a+rw /mnt/fakes3_root -R
fakes3 -r /mnt/fakes3_root -H 0.0.0.0 -p 4569 --license license.pdf > /dev/null 2>&1 &

# # download dataset
# wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
# gzip -d hits.tsv.gz
# chmod 777 ~ hits.tsv

# # convert dataset to csv
# rm -f hits_part*.csv
# curl https://clickhouse.com/ | sh
# ./clickhouse local --query "SELECT * FROM 'hits.tsv' INTO OUTFILE 'hits.csv'"
# rm hits.tsv

# split -l 5000000 hits.csv part_
# for file in part_*; do mv "$file" "${file}.csv"; done

# upload dataset to fake S3 bucket
aws s3 mb s3://my-new-bucket --endpoint-url http://localhost:4569

for file in part_*.csv; do
    echo "Processing file: $file"

    # copy the file to the S3 bucket
    aws s3 cp "./$file" s3://my-new-bucket --endpoint-url http://localhost:4569

    # clean-up tmp pars left after upload
    for key in $(aws s3api list-objects --bucket my-new-bucket --query "Contents[?contains(Key, '_${file}_')].Key" --output text --endpoint-url http://localhost:4569); do
        aws s3api delete-object --bucket my-new-bucket --key "$key" --endpoint-url http://localhost:4569
    done
done

# get and configure Oxla image
sudo docker run --rm -it -p 5432:5432 --name oxlacontainer public.ecr.aws/oxla/release:latest &
sudo docker exec -it oxlacontainer /bin/bash -c "sed -i 's#endpoint: \"\"#endpoint: \"http://localhost:4569\"#g' oxla/default_config.yml"
sudo docker exec -it oxlacontainer /bin/bash -c "sed -i 's#endpoint:.*#endpoint: '\''http://localhost:4569'\''#g' oxla/startup_config/config.yml"
sudo docker commit oxlacontainer oxla-configured-image
sudo docker stop oxlacontainer

# run oxla
sudo docker run --rm -it -p 5432:5432 --net=host --name oxlacontainer oxla-configured-image &

# sleep, waiting for initialisation (leader election, etc.)
sleep(10)

# create table and ingest data
export PGCLIENTENCODING=UTF8
psql -h localhost -p 5432 -U postgres -t -c 'CREATE SCHEMA test'
psql -h localhost -p 5432 -U postgres -d test -t < create.sql

for file in part_*.csv; do
    echo "Processing file: $file"
    psql -h localhost -p 5432 -U postgres -d test -t -c '\timing' -c "COPY hits FROM 's3://my-new-bucket/$file';"
done

# kill fake S3
ps aux | grep fakes3 | grep -v grep | awk '{print $2}' | xargs -r kill -9
sudo rm -rf /mnt/fakes3_root

sudo docker exec -it oxlacontainer /bin/bash -c "du -sh oxla/data"

./run.sh 2>&1 | tee log.txt

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
