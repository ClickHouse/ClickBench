# Keyten over Parquet

Runs the same dataframe expressions as `../keyten` directly over the single
official Parquet file, without converting it to native storage. The client
times the request through receipt of the complete serialized result.

Run `./benchmark.sh` from this directory. The server script is a copy of the
native-storage entry's, so query semantics and timing stay identical.
The standard driver restarts the server and drops OS caches before each cold
query. The server opens the file only on its first timed query.
