WarehousePG (WHPG) is an open-source Greenplum 7 fork, picking up the
Greenplum OSS project after it went closed source in 2024.
https://github.com/warehouse-pg/warehouse-pg

The benchmark runs WarehousePG inside a privileged Rocky 9 docker
container, so the host can be any distro with docker. WarehousePG ships
no prebuilt binaries; the install script builds it from source inside
the container (~10–20 min on first install) and initializes a
single-host, 14-segment cluster via gpinitsystem.

The other scripts (start/stop/check/load/query) `docker exec` into the
running container.

To run the test:

```
./benchmark.sh
```
