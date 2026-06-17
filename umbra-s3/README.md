# Umbra (S3)

ClickBench for [Umbra](https://umbra-db.com/) with the `hits` table stored on
**Amazon S3** (`backend=cloud`) instead of local disk. It is the same Umbra
benchmark as [`../umbra`](../umbra), with two differences:

- `create.sql` registers an S3 bucket as Umbra remote storage and creates the
  table with `backend=cloud`, so table data lives in the bucket.
- You must provision that bucket first with [`./create-bucket`](#1-create-the-s3-bucket).

The dataset (`hits.parquet`) is still ingested from a local copy via
`umbra.parquetview`; only the resulting table is stored in S3.

## Prerequisites

- A fresh Ubuntu 24.04+ VM (the scripts `sudo apt-get install` Docker, the
  Postgres client, and the AWS CLI as needed).
- Docker access (the default flow runs `umbradb/umbra` in a container).
- **AWS credentials that can create and write an S3 bucket.** `create-bucket`
  picks them up, in order, from:
  1. `$AWS_ACCESS_KEY_ID` / `$AWS_SECRET_ACCESS_KEY` in the environment,
  2. whatever `aws configure` has stored,
  3. an interactive prompt (only if neither of the above can reach S3).

  The *same static keys* are handed to Umbra's `create remote storage`
  statement, so they must allow normal S3 data access (not just bucket
  creation). No IAM user/role is created.

## 1. Create the S3 bucket

```bash
cd umbra-s3
./create-bucket
```

This:

- ensures the AWS CLI is installed,
- resolves working AWS credentials (see above),
- generates a globally-unique bucket name `clickbench-umbra-s3-<YYYYMMDD>-<uuid>`
  and creates it in your region,
- writes everything Umbra needs to **`.s3-env`** (bucket, region, key id, key).

`.s3-env` is gitignored and `chmod 600`. **`./load` sources it automatically**,
so once `create-bucket` has run you do not need to export anything by hand.
Re-running `create-bucket` reuses the bucket/credentials already in `.s3-env`.

### Region and path

- Region: `$UMBRA_S3_REGION`, else `$AWS_DEFAULT_REGION`, else `us-east-1`.
- Path prefix inside the bucket: `$UMBRA_S3_PATH` (default `umbra`).

Umbra addresses the bucket as `s3://<bucket>:<region>/<path>` — the region is
part of the URI, not a separate option.

## 2. Run the benchmark

Either run the standard ClickBench driver directly from this directory:

```bash
cd umbra-s3
./benchmark.sh
```

The driver (`../lib/benchmark-common.sh`, via `benchmark.sh`) runs the
primitives in order: `install` → `start` → `load` → the 43 queries
(cold + 2 warm each) → `stop`. `install` downloads `hits.parquet` into `data/`
(kept across runs, out of the measured load time); `load` registers the S3
remote storage, creates the `backend=cloud` table, and ingests it.

> Run `./create-bucket` **before** the benchmark. `load` fails fast with a
> clear message if `UMBRA_S3_*` are unset (i.e. no `.s3-env`).

## 3. Tear down

```bash
./delete-bucket
```

Empties and deletes the bucket recorded in `.s3-env`, then removes `.s3-env`.
Idempotent, and touches no IAM resources.
