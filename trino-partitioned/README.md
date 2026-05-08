## Trino on a directory of Parquet files (100 partitions)

Same setup as `trino/` (Hive connector + file metastore + native local
filesystem driver), but the external table points at a directory of
100 parquet files split by `RegionID` instead of a single ~14.7 GB
parquet file. Trino splits each file into 64 MB chunks and processes
them in parallel.

The `hits` view in `create.sql` performs the same `EventTime`/`EventDate`
type conversions as the single-file variant.
