# chDB tuned

This setup inherits the chDB benchmark's disabled automatic statistics and
final part merge. It additionally forces LZ4 and disables adaptive codec
selection on `t3a.small` and `c6a.large`, where the lower decompression cost
is more beneficial than ZSTD's smaller on-disk representation. Other machine
types retain the default ZSTD path.

The EC2 instance type is read from DMI. For local reproduction, set
`CLICKBENCH_INSTANCE_TYPE` explicitly before running the benchmark.
