#!/bin/bash
# Run the full benchmark at one MotherDuck Duckling size and emit a committable
# results/<date>/<size>.json labeled "Motherduck: <size>".
#
#   motherduck_token=<TOKEN> ./run-size.sh <pulse|standard|jumbo|mega|giga>
#
# Reuses the motherduck entry's helpers: ../motherduck/set-instance-size to
# change the account's read_write Duckling (skipped when the live size already
# matches) and ../motherduck/make-result to turn the log into a results JSON
# (it reads template.json and writes results/ in this directory).
set -eu
cd "$(dirname "$0")"

size="${1:?usage: ./run-size.sh <pulse|standard|jumbo|mega|giga>}"
export motherduck_token="${motherduck_token:-${MOTHERDUCK_TOKEN:-}}"
: "${motherduck_token:?motherduck_token is required}"
RUN_DATE=$(date +%F)

./install

live=$(.venv/bin/python3 -c "import duckdb; print(duckdb.connect('md:').execute('SELECT type FROM md_live_duckling_size()').fetchone()[0])")
if [ "${live,,}" != "${size,,}" ]; then
    echo "live duckling size is $live; resizing to $size"
    ../motherduck/set-instance-size "$size"
else
    echo "live duckling size is already $live"
fi

log="motherduck-ducklake-${size}.log"
{
    echo "MotherDuck duckling size: $size"
    ./benchmark.sh
} > "$log" 2>&1
echo "-> $log"
../motherduck/make-result "$size" "$log" "$RUN_DATE"
