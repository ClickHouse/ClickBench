Open-GPDB is an open-source fork of Greenplum 6, maintained by the
Yandex Managed Greenplum team after upstream Greenplum went closed
source in 2024. https://github.com/open-gpdb/gpdb

The benchmark runs Open-GPDB inside a privileged Ubuntu 22.04 docker
container, so the host can be any distro with docker. The install
script fetches the upstream `.deb` (no source build) and initializes a
single-host, 14-segment cluster via gpinitsystem.

The other scripts (start/stop/check/load/query) `docker exec` into the
running container.

To run the test:

```
./benchmark.sh
```
