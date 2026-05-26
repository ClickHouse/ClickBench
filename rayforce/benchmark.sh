#!/bin/bash
set -euo pipefail

export HOME=${HOME:=~}

if [ ! -x ../../rayforce/rayforce ]; then
  sudo apt-get update -y
  sudo apt-get install -y build-essential git
  git clone --depth 1 https://github.com/RayforceDB/rayforce.git .rf-src
  make -C .rf-src release
  export RAY_BIN="$PWD/.rf-src/rayforce"
else
  export RAY_BIN="../../rayforce/rayforce"
fi

if [ ! -f hits.csv ]; then
  if ! ../download-hits-csv; then
    url=$(sed -n "s/.*'\\(https:.*hits.csv.gz\\)'.*/\\1/p" ../download-hits-csv)
    if [ -z "$url" ]; then
      echo "missing dataset URL" >&2
      exit 1
    fi
    wget --continue --progress=dot:giga "$url"
    gzip -df hits.csv.gz
  fi
fi
./run.sh
