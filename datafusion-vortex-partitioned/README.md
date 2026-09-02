# DataFusion + Vortex

Partitioned Vortex dataset, converted one-for-one from the 100 ClickBench Parquet files and queried with [`vortex-datafusion-cli`].

[`vortex-datafusion-cli`]: https://github.com/vortex-data/vortex-datafusion-cli

## Cookbook: Generate benchmark results

Follow the same EC2 setup used by [datafusion-partitioned](../datafusion-partitioned/README.md), then run:

```bash
cd ClickBench/datafusion-vortex-partitioned
bash benchmark.sh
```

The shared benchmark harness builds `vortex-datafusion-cli`, downloads the partitioned Parquet files, converts each `partitioned/hits_N.parquet` file into exactly one `vortex/hits_N.vortex` file, and runs the query set.

The `install` script checks out `vortex-datafusion-cli` tag `0.70.0-53.1.0`. CLI tags use `<vortex-version>-<df-version>`, where the first component is the `vortex-datafusion` crate version and the second is the DataFusion/DataFusion CLI version.

You can update/preview the results by running:

```bash
./make-json.sh <machine-name> # Example. ./make-json.sh c6a.xlarge
```

## Parquet To Vortex Conversion

Each input file is converted independently through `vortex-datafusion-cli`:

```sql
CREATE EXTERNAL TABLE hits_parquet
STORED AS PARQUET
LOCATION 'partitioned/hits_0.parquet'
OPTIONS ('binary_as_string' 'true');

COPY (
    SELECT * EXCEPT ("EventDate"),
           CAST(CAST("EventDate" AS INTEGER) AS DATE) AS "EventDate"
    FROM hits_parquet
) TO 'vortex/hits_0.vortex' STORED AS VORTEX;
```

`binary_as_string=true` handles the incorrect Parquet logical annotation before Vortex is written. The produced Vortex files store those fields as strings, so benchmark reads use only the Vortex table registration.
