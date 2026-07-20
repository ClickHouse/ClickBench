Greengage DB is an open-source MPP database based on Greenplum,
maintained by the GreengageDB community after Greenplum went closed
source in 2024. https://github.com/GreengageDB/greengage

The benchmark runs Greengage inside a privileged Ubuntu 22.04 docker
container, so the host can be any distro with docker. The install
script fetches the upstream `greengage6.deb` (no source build) and
initializes a single-host, 14-segment cluster via gpinitsystem.

The other scripts (start/stop/check/load/query) `docker exec` into the
running container.

To run the test:

```
./benchmark.sh
```
