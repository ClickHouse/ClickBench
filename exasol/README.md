# Exasol

[Exasol Personal](https://github.com/exasol/exasol-personal), the free edition of Exasol for personal use,
launched in 2026. Unlike the `exasol/docker-db` images, which allow at most 10 GiB of raw data and were
the reason this entry was empty before, it has no limit on the data size or on the hardware. It is licensed for a single user and one
installation under the
[Exasol Personal End User License Agreement](https://www.exasol.com/terms-and-conditions/#h-exasol-personal-end-user-license-agreement),
which `./install` accepts by deploying it.

The benchmark uses the local deployment of the Exasol Launcher: on Linux, the database runs on the host
in a Docker container, as a single node that uses the resources of the whole machine.

- The query result cache is disabled in every session (`ALTER SESSION SET QUERY_CACHE = 'OFF'`), so
  the second and third runs are not answered from cached results.
- Queries run through [pyexasol](https://github.com/exasol/pyexasol); the reported time covers the
  execution and fetching of the result, not the connection.
- Exasol does not distinguish an empty string from `NULL`: empty strings are loaded as `NULL`, the string
  columns are nullable, and the conditions `x <> ''` are written as `x IS NOT NULL`. For the same reason,
  `COUNT(DISTINCT SearchPhrase)` does not count the empty search phrase.
- Integers are `DECIMAL(p, 0)`, as Exasol has no binary integer types. The 64-bit columns (`WatchID`, `UserID`,
  ...) need `DECIMAL(19, 0)`, which Exasol stores in 128 bits, because their values do not fit into 18 digits.
- No indexes, distribution keys, or partitioning are declared; Exasol creates the indexes it needs
  automatically.
