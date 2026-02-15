ApsaraDB for ClickHouse Enterprise Edition(ClickHouse Cloud on Alibaba Cloud) is a cloud service that is developed based on open source ClickHouse. The architecture and features of ApsaraDB for ClickHouse Enterprise Edition differ from those of open source ClickHouse.

To evaluate the performance of ClickHouse Cloud on Alibaba Cloud, follow these guidelines to set up and execute the benchmark tests.

1. **Instance Purchase**:  
   Purchase a ApsaraDB for ClickHouse Enterprise Edition cluster instance and an ECS instance from Alibaba Cloud. Both instances must be in the same region for optimal network performance. For example, you can choose instances from the Hangzhou region.
   
   - **ClickHouse Instance**: Refer to the [ApsaraDB for ClickHouse Purchase Guide](https://www.alibabacloud.com/help/en/clickhouse/create-a-cluster?spm=a2c63.p38356.help-menu-144466.d_1_3.48341f55GpqImZ) for details on creating a ClickHouse cluster.
     - **Edition**: Select **Enterprise Edition** when creating the instance
     - **Storage Type**: Choose **ESSD_L1(ON AFS, ADB File System)** for optimal performance
     - **Compute Group**: For single-node testing, create a **single-node compute group**
   - **ECS Instance**: Refer to the [ECS Instance Purchase Guide](https://www.alibabacloud.com/help/en/ecs/user-guide/create-an-instance-by-using-the-wizard) for details on creating an ECS instance.

2. **Access Key Setup**:  
   Create your Alibaba Cloud Access Key (AK, SK) by following the instructions in the [RAM User Guide](https://www.alibabacloud.com/help/en/ram/user-guide/create-an-accesskey-pair). You will need these credentials for data preparation and benchmark execution.

3. **Data Preparation**:  
   On your ECS instance, execute the `download.sh` script to download the ClickBench test dataset and upload it to OSS:
   
   ```bash
   export AK=your_access_key
   export SK=your_secret_key
   export OSS_ENDPOINT=oss-cn-hangzhou-internal.aliyuncs.com
   export OSS_PATH=oss://your-bucket-name/clickbench/hits_parquets/
   ./download.sh
   ```
   
   This script will:
   - Download the latest ClickBench dataset from the official source (100 parquet files)
   - Upload the parquet files to your OSS bucket for use in the benchmark
   
   **Note**: Make sure to replace `your-bucket-name` with your actual OSS bucket name and adjust the endpoint region if needed.

4. **ClickHouse Instance Configuration**:  
   Before running the benchmark, configure your ClickHouse instance:
   
   - **Create Test User**: Create a database user account for running the benchmark tests
   - **Whitelist ECS IP**: Add your ECS instance's internal IP address to the ClickHouse instance whitelist to allow connections
   
   Refer to the [ClickHouse Security Configuration Guide](https://www.alibabacloud.com/help/en/clickhouse/user-guide/configure-ip-address-whitelists) for detailed instructions.

5. **Environment Variables Setup**:  
   Set up the following environment variables on your ECS instance:
   
   ```bash
   export FQDN=your_clickhouse_host          # ClickHouse instance FQDN
   export USER=user_name                     # ClickHouse username
   export PASSWORD=your_password             # ClickHouse password
   export AK=access_key                      # Alibaba Cloud Access Key ID
   export SK=secret_key                      # Alibaba Cloud Secret Access Key
   export STORAGE=afs                        # Storage type identifier (e.g., afs, oss)
   export REPLICAS=replicas_num              # Number of replicas
   export CCU=your_ccu                       # Compute Capacity Units (CCUs)
   export ECS=ECS_instance_generation
   export OSS_URL="https://your-bucket-name.oss-cn-hangzhou-internal.aliyuncs.com/clickbench/hits_parquets/hits_{0..99}.parquet"
   ```
   
   **Important**: 
   - Replace `your-bucket-name` with your actual OSS bucket name
   - Ensure the OSS_URL matches the path where you uploaded the data in step 3
   - Use the internal endpoint for better performance and no data transfer fees

6. **Benchmark Execution**:  
   Execute the `benchmark.sh` script to run the complete benchmark test:
   
   ```bash
   ./benchmark.sh
   ```

7. **Complete Example**:  
   Here's a complete workflow example:
   
   ```bash
   # Step 1: Download and upload test data to OSS
   export AK=LTAI5txxxxxxxxxx
   export SK=xxxxxxxxxxxxxxxx
   export OSS_ENDPOINT=oss-cn-hangzhou-internal.aliyuncs.com
   export OSS_PATH=oss://clickhouse-test-bucket/clickbench/hits_parquets/
   ./download.sh
   
   # Step 2: Configure ClickHouse instance (via web console)
   # - Create test user (or use default user)
   # - Whitelist ECS internal IP address
   
   # Step 3: Set environment variables and run benchmark
   export FQDN=xxxxx.clickhouse.aliyuncs.com
   export USER=default
   export PASSWORD=YourPassword123
   export AK=LTAI5txxxxxxxxxx
   export SK=xxxxxxxxxxxxxxxx
   export STORAGE=afs
   export REPLICAS=2
   export CCU=32
   export ECS=r8i
   export OSS_URL="https://clickhouse-test-bucket.oss-cn-hangzhou-internal.aliyuncs.com/clickbench/hits_parquets/hits_{0..99}.parquet"
   
   ./benchmark.sh
   ```

8. **Results**:  
   The benchmark results will be saved in the `results/` directory in JSON format, with filenames following the pattern: `alicloud-{CATEGORY}-{REPLICAS}-{STORAGE}-{CCU}-{REPLICAS}.json`

