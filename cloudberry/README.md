Cloudberry DB is a fork of Greenplum DB, based on PG 14.
The test was run on AWS c6a.4xlarge machine, 500Gb gp2. One mater segment, 14 primary segments, no mirrors. The databased was compiled from source (couldn't find RPMs). ORCA enabled.

To run the test, put all files in a single directory and run benchmark.sh, then follow the instructions (you will need to run the script multiple times with different options).
