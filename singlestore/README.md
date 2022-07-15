This benchmark has two options: running against a Singlestore cluster-in-a-box docker image or Singlestore Cloud

To test cluster-in-a-box locally, simply execute benchmark.sh

To test against Singlestore Cloud, first create an account and cluster, then paste your cluster endpoint and password
into the corresponding variables in benchmark_on_cloud.sh. You can then execute benchmark_on_cloud.sh to complete the
benchmark. The easiest way to check the amount of object storage used in this variant of the test is via the portal ui.
