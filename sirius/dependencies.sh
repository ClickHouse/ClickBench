#!/bin/bash
echo "Checking dependencies..."

sudo apt-get update -y
sudo apt-get install -y git wget curl build-essential time

# Install Pixi globally so it is available to all scripts without PATH hacks
if ! command -v pixi &> /dev/null; then
  echo "Pixi not found. Installing globally..."
  curl -fsSL https://pixi.sh/install.sh | sudo PIXI_BIN_DIR=/usr/local/bin PIXI_NO_PATH_UPDATE=1 bash
fi
