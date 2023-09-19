#!/bin/bash

sudo apt-get update
sudo apt-get -y install openjdk-8-jdk-headless

# For Spark3.0.1 installation: 
# wget --continue https://downloads.apache.org/spark/spark-3.0.1/spark-3.0.1-bin-hadoop2.7.tgz
# tar -xzf spark-3.0.1-bin-hadoop2.7.tgz
# mv spark-3.0.1-bin-hadoop2.7 spark

wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
#gzip -d hits.tsv.gz
chmod 777 ~ hits.tsv
$HADOOP_HOME/bin/hdfs dfs -put hits.tsv /

$SPARK_HOME/bin/spark-shell --master local -i ClickBenchRunner.scala > log.txt
