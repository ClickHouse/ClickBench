#!/bin/bash

if [ "$1" != "--skip-setup" ]; then
  # Install python and dependencies
  sudo apt-get update -y
  sudo apt-get install -y python3-pip python3-venv
  python3 -m venv myenv
  source myenv/bin/activate
  pip install duckdb psutil
fi

# Go to the web ui and obtain a token
# https://motherduck.com/docs/key-tasks/authenticating-and-connecting-to-motherduck/authenticating-to-motherduck/#creating-an-access-token
# Save the token as the motherduck_token environment variable:
# export motherduck_token=...

python3 ./benchmark.py 2>&1
