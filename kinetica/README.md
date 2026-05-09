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

## Status (as of May 2026): unreproducible

The benchmark drives Kinetica via the `kisql` CLI. The previously-pinned binary download

    https://github.com/kineticadb/kisql/releases/download/v7.1.7.2/kisql

now returns 404 — that GitHub release was deleted upstream. Newer source tags exist (v7.2.3.x) but the project no longer attaches compiled artifacts to releases, so there's no drop-in binary to fetch.

Kinetica itself still installs via `https://files.kinetica.com/install/kinetica.sh` and the Postgres-wire endpoint on port 5434 is reachable; switching the bench to drive it through `psql` over that wire would be a path forward, but most Kinetica-specific SQL (e.g. `LOAD INTO ... FROM FILE PATHS`) isn't accepted there. The directory and historical results are kept for reference.

