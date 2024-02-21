#!/bin/bash

sudo apt-get update
sudo apt-get -y install openjdk-8-jdk-headless

### If there is no HDFS and Spark on your system:

export HADOOP_DIR="/usr/local/hadoop"
export SPARK_DIR="/usr/local/spark"
export JAVA_HOME="/usr/lib/jvm/java-8-openjdk-amd64"
export HADOOP_VERSION="3.3.6"
export SPARK_VERSION="3.5.0"


# export hadoop_file=hadoop-$HADOOP_VERSION.tar.gz
# export spark_file=spark-$SPARK_VERSION-bin-hadoop3.tgz
# wget --continue https://downloads.apache.org/hadoop/common/hadoop-$HADOOP_VERSION/$hadoop_file
# wget --continue https://downloads.apache.org/spark/spark-$SPARK_VERSION/$spark_file
# sudo tar -xzf $hadoop_file $spark_file
# sudo rm -f $spark_file $hadoop_file
# sudo rm -rf $HADOOP_DIR $SPARK_DIR
# sudo mv spark-$SPARK_VERSION spark
# sudo mv spark $SPARK_DIR
# sudo mv hadoop-$HADOOP_VERSION hadoop
# sudo mv hadoop $HADOOP_DIR

# echo "export HADOOP_HOME=$HADOOP_DIR" >> ~/.bashrc
# echo "export SPARK_HOME=$SPARK_DIR" >> ~/.bashrc
# echo "export PATH=$SPARK_HOME/bin:$SPARK_HOME/sbin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH" >> ~/.bashrc
# source ~/.bashrc

### To configure HDFS:

#cd $HADOOP_HOME/etc/hadoop
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
# echo "export JAVA_HOME=$JAVA_HOME" >> hadoop-env.sh

### To configure Spark:

# cd $SPARK_HOME/conf
# cp spark-env.sh.template spark-env.sh
# echo "export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop" >> spark-env.sh
# echo "export SPARK_MASTER_HOST=localhost" >> spark-env.sh

### To run passless connection on localhost:

# ssh-keygen -t rsa
# cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
# chmod og-wx ~/.ssh/authorized_keys 

### To run Spark and HDFS:

# cd $SPARK_HOME/sbin
# ./start-master.sh
# ./start-slave.sh spark://localhost:7077
# cd $HADOOP_HOME/sbin
# hdfs namenode -format
# ./start-dfs.sh

wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz
chmod 777 ~ hits.tsv
hdfs dfs -put hits.tsv /

$SPARK_HOME/bin/spark-shell --master local -i ClickBenchRunner.scala
