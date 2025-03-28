# YDB

[YDB](https://ydb.tech) is a versatile open source Distributed SQL Database that combines high availability and scalability with strong consistency and ACID transactions. It accommodates transactional (OLTP), analytical (OLAP), and streaming workloads simultaneously.

## Running the benchmark

YDB is a distributed database, the minimum in terms of fault tolerance production configuration is 3 servers. The `benchmark_variables.sh` file contains variables that must be specified before running the script:
1. `host1`, `host2`, `host3` - servers where YDB will be deployed
1. `ydb_host_user_name` - SSH-user name, from under which SSH-connections to servers will be established
1. `disk1`, `disk2`, `disk3` - path to raw block-device, where data will be stored i.e. `/dev/nvme01`
1. `host_suffix` - FQDN suffix of the servers, it is necessary for forming SSL certificates.

After specifying all the variables, you need to run ./benchmark.sh, which will download all the necessary packages, collect the YDB source code, build it and install on the servers with the help of ansible and run the benchmark itself.
