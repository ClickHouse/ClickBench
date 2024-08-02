## Introduction

AWS S3 has support for `SelectObjectContent` method, which allows to run SQL queries directly on S3 objects, if they contain data in CSV, JSON or Parquet formats.

Reference: https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-select-sql-reference-select.html

Unfortunately, the language is very primitive. It does not support ORDER BY or GROUP BY. Only filtering by WHERE with a primitive set of functions and the LIMIT clause.

That's why it cannot complete ClickBench.

The performance is atrocious, and the usability is dubious. It is pointless to use even if you want to pre-filter data by some conditions before further processing.

## Comparison

AWS S3 Select:

```
time aws s3api select-object-content --bucket clickhouse-public-datasets --key 'hits_compatible/hits.parquet' --expression "SELECT CounterID, SearchPhrase FROM S3Object WHERE SearchPhrase LIKE '%трешбоксарский%'" --expression-type SQL --input-serialization '{"Parquet": {}}' --output-serialization '{"CSV": {}}' /dev/stdout
1634,прировочный счёт трешбоксарский лабор для железневые в гаражных расписатель

real    0m33.796s
user    0m0.842s
sys     0m0.091s
```

ClickHouse:

```
time ch -q "SELECT CounterID, SearchPhrase FROM s3('s3://clickhouse-public-datasets/hits_compatible/hits.parquet') WHERE SearchPhrase LIKE '%трешбоксарский%'"
1634    прировочный счёт трешбоксарский лабор для железневые в гаражных расписатель

real    0m3.526s
user    0m7.248s
sys     0m1.314s
```

We can see that ClickHouse is ten times faster despite the need for client-side processing.

## Caveats

Some invalid queries just hang instead of returning an error:

```
aws s3api select-object-content --bucket clickhouse-public-datasets --key 'hits_compatible/hits.parquet' --expression "SELECT CounterID, count(*) FROM S3Object WHERE SearchPhrase LIKE '%test%'" --expression-type SQL --input-serialization '{"Parquet": {}}' --output-serialization '{"CSV": {}}' -
```

When they do return an error, the error message is below reasonable:

```
aws s3api select-object-content --bucket clickhouse-public-datasets --key 'hits_compatible/hits.parquet' --expression "SELECT CounterID, count(*) FROM S3Object GROUP BY CounterID ORDER BY count(*) DESC LIMIT 10" --expression-type SQL --input-serialization '{"Parquet": {}}' --output-serialization '{"CSV": {}}' -

An error occurred (ParseUnexpectedToken) when calling the SelectObjectContent operation: Unexpected token found KEYWORD:UNKNOWN at line 1, column 61.
```

## Alternatives

You can use ClickHouse in AWS Lambda: https://github.com/aws-samples/aws-lambda-clickhouse

This project is made by AWS engineers.
