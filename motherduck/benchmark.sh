#!/bin/bash

if [ "$1" != "--skip-setup" ]; then
  # Install python and dependencies
  sudo apt-get update -y
  sudo apt-get install -y python3-pip python3-venv
  python3 -m venv myenv
  source myenv/bin/activate
  pip install duckdb psutil
fi

# See README.md
python3 ./benchmark.py 2>&1
