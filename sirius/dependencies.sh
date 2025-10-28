#!/bin/bash
echo "Checking dependencies..."

# DuckDB dependencies
sudo apt-get update -y
sudo apt-get install -y git g++ ninja-build libssl-dev build-essential make ccache pip

# CMake
CMAKE_REQUIRED_VERSION="3.30.4"
if command -v cmake &>/dev/null; then
  CMAKE_INSTALLED_VERSION=$(cmake --version | head -n1 | awk '{print $3}')
else
  CMAKE_INSTALLED_VERSION="0"
fi

version_lt() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]
}

if version_lt "$CMAKE_INSTALLED_VERSION" "$CMAKE_REQUIRED_VERSION"; then
  echo "CMake version too old, installing version $CMAKE_REQUIRED_VERSION..."
  sudo apt purge --autoremove -y cmake
  wget -qO- "https://github.com/Kitware/CMake/releases/download/v$CMAKE_REQUIRED_VERSION/cmake-$CMAKE_REQUIRED_VERSION.tar.gz" | tar -xz
  cd "cmake-$CMAKE_REQUIRED_VERSION"
  ./bootstrap
  make -j$(nproc)
  sudo make install
  cd ..
  rm -rf "cmake-$CMAKE_REQUIRED_VERSION"
fi

# CONDA
MINICONDA_DIR="$HOME/miniconda3"
if [[ ! -d "$MINICONDA_DIR" ]]; then
  echo "Miniconda not found. Installing..."
  ARCH=$(uname -m)
  if [[ "$ARCH" == "x86_64" ]]; then
    MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
  elif [[ "$ARCH" == "aarch64" ]]; then
    MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh"
  else
    echo "Unsupported architecture for Miniconda: $ARCH"
    exit 1
  fi
  wget -q $MINICONDA_URL -O /tmp/Miniconda3-latest.sh
  bash /tmp/Miniconda3-latest.sh -b -p $HOME/miniconda3
  rm /tmp/Miniconda3-latest.sh
fi
source "$MINICONDA_DIR/etc/profile.d/conda.sh"

# Accept ToS for non-interactive use
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r

# CUDF
CUDF_REQUIRED_VERSION="25.12"
CUDF_NIGHTLY=true
CONDA_CUDF_ENV_NAME="libcudf-env"
CONDA_BASE=$(conda info --base)
export LIBCUDF_ENV_PREFIX="$CONDA_BASE/envs/$CONDA_CUDF_ENV_NAME"

check_libcudf_version() {
  conda list --prefix "$1" 2>/dev/null | grep "^libcudf" | awk '{print $2}'
}
CUDF_INSTALLED_VERSION=$(check_libcudf_version "$LIBCUDF_ENV_PREFIX" || echo "")

if [[ ! -d "$LIBCUDF_ENV_PREFIX" ]]; then
  echo "Creating conda environment $CONDA_CUDF_ENV_NAME..."
  conda create --name "$CONDA_CUDF_ENV_NAME" -y
fi
conda activate "$CONDA_CUDF_ENV_NAME"

if [[ "$CUDF_INSTALLED_VERSION" != "$CUDF_REQUIRED_VERSION" ]]; then
  echo "Installing/upgrading libcudf $CUDF_REQUIRED_VERSION..."
  if [[ "$CUDF_NIGHTLY" = true ]]; then
    conda install -c rapidsai -c conda-forge -c nvidia "rapidsai-nightly::libcudf=$CUDF_REQUIRED_VERSION" -y
  else
    conda install -c rapidsai -c conda-forge -c nvidia "rapidsai::libcudf=$CUDF_REQUIRED_VERSION" -y
  fi
fi
