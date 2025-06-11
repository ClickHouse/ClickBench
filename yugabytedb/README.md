> YugabyteDB is a PostgreSQL-compatible, high-performance, cloud-native, distributed SQL database.

—[YugabyteDB GitHub repository](https://github.com/yugabyte/yugabyte-db)

**Notes:**

- To use the [OS settings recommended by YugabyteDB](https://docs.yugabyte.com/preview/deploy/manual-deployment/system-config), first run `benchmark.sh setup`.
- To run the benchmark, run `benchmark.sh run`.
- On an AWS EC2 c6a.4xlarge (500GB gp2) instance, even simple queries run tremendously slow. On a local machine (AMD Ryzen 5 5600X, 32GB RAM, 1TB NVMe drive) inside a Docker container, queries run notably faster.
    - Q1:
      - EC2: `[1306.72,1268.44,1269.34]`
      - Local: `[329.484,328.405,327.32]`
    - Q2:
      - EC2: `[1788.86,2214.2,2214.08]`
      - Local: `[335.95,320.728,294.426]`

    The data loading time is comparable on both machines (~78 minutes).
