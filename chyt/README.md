## 1. Requesting a Demo Cluster

* Visit the [YTsaurus Getting Started webpage](https://ytsaurus.tech/docs/en/overview/try-yt#demo-stand) to book your demo cluster.

## 2. Exporting Necessary Parameters

After receiving the email with your cluster details, configure your environment by exporting the following parameters. Remember to replace `XXXXXXXX` with the actual ID from your email. Execute the following commands in your terminal:

```console
sudo su
export YT_USE_HOSTS=0
export YT_TOKEN=your_cluster_password
export CLUSTER_NAME=ytdemo
export YT_PROXY=https://http-proxy-XXXXXXXX.demo.ytsaurus.tech
export YT_CONTROLLER=https://strawberry-XXXXXXXX.demo.ytsaurus.tech
```
**Note:** It is essential to execute `sudo su` before exporting variables to ensure correct permissions and environment configuration.
## 3. Running the Benchmark

Once the environment is configured, execute the `run.sh` script. This script automates the following steps:
* Creates a table named `//home/hits`.
* Populates the table with data from the ClickBench dataset repository.
* Sorts the data within the table.
* Executes benchmark queries against the sorted data.

To start the benchmark, simply execute:
```console
./run.sh
```
### Compatibility
The `run.sh` script has been tested on **Ubuntu 24.04.2 LTS**
