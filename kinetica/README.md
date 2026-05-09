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

## Sourcing kisql (May 2026)

The previously-pinned `kisql` binary at

    https://github.com/kineticadb/kisql/releases/download/v7.1.7.2/kisql

is gone — that GitHub release was deleted upstream and newer release pages ship no compiled artifacts. The same binary is committed directly to the repo root as a self-extracting bash+jar launcher, so `install` now fetches it from

    https://raw.githubusercontent.com/kineticadb/kisql/<KISQL_TAG>/kisql

(default `KISQL_TAG=v7.2.3.17`, matches the 7.2.x server we install).

