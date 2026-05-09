# Infobright

## Status (as of May 2026): unreproducible

Infobright Inc. has been defunct since 2017. The benchmark relies on the community Docker image

    docker pull flolas/infobright

which still pulls, but the image is unmaintained: the latest run hangs silently part-way through `LOAD DATA LOCAL INFILE` (after the schema commands succeed, no further output appears and the run eventually times out). The previous `LOAD DATA` workaround in `load` truncates the dataset to the first 90M rows to dodge a row-93557187 parse error, but the silent hang persists past that.

Without a maintained image, an upstream successor, or a working binary path, this isn't reproducible. The directory and historical results are kept for reference.
