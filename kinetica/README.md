# Kinetica

## Setup and benchmark

1. Deploy a c6a.4xlarge with 500 GB gp2 disk; `benchmark.sh` assumes that you are deploying an Ubuntu OS variant and runs the `setup-dev-ubuntu.sh` script. If you deploy any other OS, then you will need to install docker, java, and ripgrep separately.

2. Once you have the VM up and running, you can run the `benchmark.sh` script for a one-click install and run; it will:                                                                                      
-- download and install the `Kinetica` developer edition and its sql-client `kisql`
-- increase the RAM tier (via `alter tier`)
-- ingest the dataset
-- run the queries

All the queries will be executed on behalf of the user `admin` with the password `admin`.

## Notes
`99,997,496` rows will be inserted; `1` row isn't inserted because of bad data:
> WARNING: Invalid_Argument: quoted field must end with quote (ColumnIndex:100)(ColumnName:UTMTerm)(ColumnType:char256)(Value:"tatuirovarki_redmond 70            0       -296158784638538920     -8631670417943857411    0)
> WARNING: Skipped: 1, inserted : 99997496 records, updated : 0 records.

