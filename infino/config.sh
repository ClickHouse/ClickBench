# Shared infino configuration, sourced by load, start, and benchmark.sh, so the
# raw scripts (which the playground runs directly, without benchmark.sh) get the
# same tuning as the benchmark. Everything is a :- fallback, so an explicit env
# from the caller still wins.

# Disk cache lives beside the data so warm queries read cached column chunks.
export INFINO_CACHE_DIR="${INFINO_CACHE_DIR:-./cache}"

# Superfile segment size: many mid-size segments let the scan parallelise across
# cores. 256 MB fits a 16-core box on up. Without this the default ~1 GiB
# segments leave queries single-file-bound (seconds instead of sub-second).
export INFINO_TARGET_SF_MB="${INFINO_TARGET_SF_MB:-256}"

# Disk-cache budget: 24 GiB, comfortably above the ~11 GB (100M-row) dataset so
# every superfile stays cached (the DiskCacheStore holds them mmap-backed) and
# warm queries are fast. A fixed size, not a RAM fraction: the cache lives on
# the 200 GB sysdisk, and actual use is capped by the ~11 GB dataset, which fits
# in RAM on every ClickBench machine (>= 16 GB). The default (10 GiB) is below
# the dataset, so it range-reads and queries turn slow.
export INFINO_CACHE_BUDGET="${INFINO_CACHE_BUDGET:-25769803776}"  # 24 GiB
