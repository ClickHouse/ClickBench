The `setup.sh` script will install docker and any necessary packages for the benchmark to run.
`benchmark.sh` will download and install the `Kinetica` developer edition and its sql-client `kisql`, increase the RAM tier (via `alter tier`), ingest the dataset, and run the queries.
All the queries will be executed on behalf of the user `admin` with the password `admin`.

`99,997,496` rows will be inserted; `1` row isn't inserted because of bad data:                                                                                                                                                 
> WARNING: Invalid_Argument: quoted field must end with quote (ColumnIndex:100)(ColumnName:UTMTerm)(ColumnType:char256)(Value:"tatuirovarki_redmond 70            0       -296158784638538920     -8631670417943857411    0)
> WARNING: Skipped: 1, inserted : 99997496 records, updated : 0 records.
