"""
Convert one NDJSON file into one Parquet file holding the documents in a single VARIANT column.

    python load.py <in.jsonl> <out.parquet>

READ_JSONL(..., as_variant => 'data') reads every line whole as one VARIANT value (no key is
split out into a column of its own). ignore_errors skips the few records of the dataset that are
not valid JSON, as ../opteryx does. The rows are sorted by the paths the queries read, and rugo's
streaming Parquet writer (bundled in opteryx-core) writes the column as a shredded Parquet VARIANT.

Standard library and opteryx-core only.
"""

import sys

import opteryx
from rugo.parquet import write_parquet_stream

source, target = sys.argv[1], sys.argv[2]

SQL = f"""
SELECT data
FROM READ_JSONL('{source}', as_variant => 'data', ignore_errors => true)
ORDER BY data->>'kind', data->'commit'->>'operation', data->'commit'->>'collection',
         data->>'did', CAST(data->>'time_us' AS INT64)
"""

with open(target, "wb") as handle:
    write_parquet_stream(opteryx.session().execute_to_morsels(SQL), handle.write, compression="zstd")
