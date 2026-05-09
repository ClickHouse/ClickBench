Cloudberry DB is a fork of Greenplum DB, based on PG 14.

The install script assumes a RHEL-family host (Rocky/Alma/CentOS/RHEL): it
uses `yum`, `grubby`, the `wheel` group, SELinux config, and `/data0` paths.
On Ubuntu/Debian it will refuse to run.

To run the test, put all files in a single directory and run benchmark.sh under root user, then follow the instructions (you will need to run the script multiple times with different options).
