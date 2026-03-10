#!/bin/bash
#!/bin/bash
# Install system dependencies required to build Sirius and run ClickBench.

echo "Installing system dependencies..."
sudo apt-get update -y
sudo apt-get install -y git wget curl build-essential time

# Install Pixi package manager (used to manage CUDA/cuDF toolchain)
if ! command -v pixi &> /dev/null; then
  echo "Pixi not found. Installing..."
  curl -fsSL https://pixi.sh/install.sh | sudo PIXI_BIN_DIR=/usr/local/bin PIXI_NO_PATH_UPDATE=1 bash
fi

echo "All dependencies installed."
