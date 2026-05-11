## Presto on a directory of Parquet files (100 partitions)

Same setup as `presto/` but the external table points at a directory of
100 parquet files split by `RegionID` instead of a single ~14.7 GB
parquet file. Presto splits each file in parallel across worker threads.

The `hits` view in `create.sql` performs the same `EventTime`/`EventDate`
type conversions as the single-file variant.
