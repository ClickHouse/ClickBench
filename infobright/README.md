# Infobright

## Dead (May 2026)

Infobright Inc. has been defunct since 2017. The benchmark uses the community Docker image

    docker pull flolas/infobright

The image still pulls but is unmaintained: the latest run hangs silently part-way through `LOAD DATA LOCAL INFILE` (schema commands succeed, then no further output until the run times out). The existing workaround that truncates the dataset to the first 90M rows (to dodge a row-93557187 parse error) doesn't help with the silent hang.

There is no maintained image, no upstream successor, and no working binary path. The directory and historical results are kept; nothing here runs anymore.
