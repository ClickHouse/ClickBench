Cloudberry DB is a fork of Greenplum DB, based on PG 14.

The benchmark runs Cloudberry inside a privileged Rocky 9 docker container,
so the host can be Ubuntu/Debian/RHEL/anything that runs docker. The install
script builds Cloudberry from source inside the container (~10–20 min on
first install) and initializes a single-segment cluster via gpinitsystem.

The other scripts (start/stop/check/load/query) `docker exec` into the
running container.

To run the test:

```
./benchmark.sh
```
