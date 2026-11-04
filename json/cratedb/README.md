# CrateDB

[CrateDB](https://github.com/crate/crate), the latest stable release from the official APT repository, with the default configuration.

The documents are stored in a single `OBJECT` column, `data`. Its sub-columns are `DYNAMIC`: every new field is added to the schema with the type of its first value, indexed and stored in the columnar doc values, which is what the queries use. The exception is `data['commit']['record']`, the content of the record, declared `IGNORED`: its fields are not typed or indexed, because the same path has different types in different collections (e.g. `commit.record.subject` is an object in likes and a string in follows), so that dynamic typing would reject documents. All documents are kept unchanged in `_source`, so `retains_structure` is `yes`.

COPY FROM reads JSON lines whose keys are the columns of the table, so the load wraps every document as `{"data": <document>}` and drops the few lines that are not valid JSON (documents of more than 64 KiB split into two lines, see `../mongodb/load`) with a Python filter, 32 files in parallel, and then loads these files with `COPY bluesky FROM 'file:///.../*.json'`.

CrateDB timestamps have millisecond precision: Q3 and Q4 use `(data['time_us'] / 1000)::TIMESTAMP WITH TIME ZONE`, so the timestamp of Q4 is truncated to milliseconds. Q5 computes the activity span as the difference of the microsecond timestamps divided by 1000. Q2 uses the exact `COUNT(DISTINCT)`.
