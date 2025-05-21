Hologres is an all-in-one real-time data warehouse engine that is compatible with PostgreSQL. It supports online analytical processing (OLAP) and ad hoc analysis of PB-scale data. Hologres supports online data serving at high concurrency and low latency.

To evaluate the performance of Hologres, follow these guidelines to set up and execute the benchmark tests.

1. **Instance Purchase**:  
   Refer to the [Alibaba Cloud Hologres TPC-H Testing Documentation](https://www.alibabacloud.com/help/en/hologres/user-guide/test-plan?spm=a2c63.p38356.help-menu-113622.d_2_14_0_0.54e14f70oTAEXO) for details on purchasing Hologres and ECS instances. Both instances must be purchased within the same region. For example, you can choose instances from Zone J in the Hangzhou region.

2. **Benchmark Execution**:  
   Once the instances are set up, prepare your ECS instance by executing the `benchmark.sh` script. The script requires the following parameters:
   - `ak`: Access Key
   - `sk`: Secret Key
   - `host_name`: Hostname of the Hologres instance
   - `port`: Port of the Hologres instance

   You can create your Access Key (ak, sk) by following the instructions in the [RAM User Guide](https://www.alibabacloud.com/help/en/ram/user-guide/create-an-accesskey-pair?spm=a3c0i.29367734.6737026690.14.7a797d3fJmRhXM).

3. **Sample Execution**:
   ```bash
   ./benchmark.sh ak sk host_name 80
   ```
