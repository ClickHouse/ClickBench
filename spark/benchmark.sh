#!/bin/bash

sudo apt-get update
sudo apt-get -y install openjdk-8-jdk-headless

### If there is no HDFS and Spark on your system:

# wget --continue https://downloads.apache.org/hadoop/common/hadoop-3.3.6/hadoop-3.3.6.tar.gz
# wget --continue https://downloads.apache.org/spark/spark-3.5.0/spark-3.5.0-bin-hadoop3.tgz
# tar -xzf hadoop-3*
# tar -xzf spark-3*
# sudo mkdir -p /urs/local/hadoop
# sudo mkdir -p /usr/local/spark
# sudo mv hadoop-3* /usr/local/hadoop
# sudo mv spark-3* /usr/local/spark

# echo "export HADOOP_HOME=/usr/local/hadoop" >> ~/.bashrc
# echo "export PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin" >> ~/.bashrc
# echo "export SPARK_HOME=/usr/local/spark>" >> ~/.bashrc
# echo "export PATH=$PATH:$SPARK_HOME/bin:$SPARK_HOME/sbin" >> ~/.bashrc

### To configure HDFS:

#cd /usr/local/hadoop/etc/hadoop
#cp core-site.xml core-site.xml.bak
#cp hdfs-site.xml hdfs-site.xml.bak
# echo "<configuration>
#   <property>
#     <name>fs.defaultFS</name>
#     <value>hdfs://localhost:9000</value>
#   </property>
# </configuration>" > core-site.xml
# echo "<configuration>
#   <property>
#     <name>dfs.replication</name>
#     <value>1</value>
#   </property>
# </configuration>" > hdfs-site.xml

### To configure Spark:

# cd /usr/local/spark/conf
# cp spark-env.sh.template spark-env.sh
# echo "export HADOOP_CONF_DIR=/usr/local/hadoop/etc/hadoop" >> spark-env.sh
# echo "export SPARK_MASTER_HOST=localhost" >> spark-env.sh

### To run Spark and HDFS:

# start-master.sh
# start-slave.sh spark://localhost:7077
# hdfs namenode -format
# start-dfs.sh


source ~/.bashrc

wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz
chmod 777 ~ hits.tsv
hdfs dfs -put hits.tsv /

$SPARK_HOME/bin/spark-shell --master local -i ClickBenchRunner.scala
