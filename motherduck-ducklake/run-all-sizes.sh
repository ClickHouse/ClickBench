#!/bin/bash
# Run the full benchmark (all 43 queries plus the concurrent-QPS test) on
# MotherDuck once per Duckling size, largest first, and write
# results/<date>/<size>.json for each, labeled "Motherduck: <size>".
#
#   motherduck_token=<TOKEN> ./run-all-sizes.sh [size ...]
#
# This is ../motherduck/run-all-sizes.sh pointed at this entry: same default
# size set (mega jumbo standard pulse; giga with INCLUDE_GIGA=1 or by name),
# same resize + settle wait between sizes, same env (INCLUDE_GIGA,
# RESTORE_SIZE, ...). Logs go to motherduck-ducklake-<size>.log. For a single size
# at the live Duckling size, use ./run-size.sh.
set -eu
cd "$(dirname "$0")"
MOTHERDUCK_ENTRY=$(pwd) exec ../motherduck/run-all-sizes.sh "$@"
