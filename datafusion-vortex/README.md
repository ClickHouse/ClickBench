# DataFusion + Vortex

Single-file Vortex dataset, converted from the ClickBench Parquet file and queried with [`vortex-datafusion-cli`].

[`vortex-datafusion-cli`]: https://github.com/vortex-data/vortex-datafusion-cli

## Cookbook: Generate benchmark results

Follow the same EC2 setup used by [datafusion](../datafusion/README.md), then run:

```bash
cd ClickBench/datafusion-vortex
bash benchmark.sh
```

The shared benchmark harness builds `vortex-datafusion-cli`, downloads `hits.parquet`, converts it to `vortex/hits.vortex`, and runs the query set.

The `install` script checks out `vortex-datafusion-cli` tag `0.70.0-53.1.0`. CLI tags use `<vortex-version>-<df-version>`, where the first component is the `vortex-datafusion` crate version and the second is the DataFusion/DataFusion CLI version.

You can update/preview the results by running:

```bash
./make-json.sh <machine-name> # Example. ./make-json.sh c6a.xlarge
```

## Parquet To Vortex Conversion

The conversion intentionally goes through the DataFusion CLI path:

```sql
CREATE EXTERNAL TABLE hits_parquet
STORED AS PARQUET
LOCATION 'hits.parquet'
OPTIONS ('binary_as_string' 'true');

COPY (
    SELECT * EXCEPT ("EventDate"),
           CAST(CAST("EventDate" AS INTEGER) AS DATE) AS "EventDate"
    FROM hits_parquet
) TO 'vortex/hits.vortex' STORED AS VORTEX;
```

`binary_as_string=true` handles the ClickBench Parquet byte/string mismatch before Vortex is written. The resulting Vortex file stores those columns as strings, so Vortex reads do not need the Parquet-only option.
