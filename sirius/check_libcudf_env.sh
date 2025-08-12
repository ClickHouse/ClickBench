#!/bin/bash

if [[ -n "$CONDA_PREFIX" ]]; then
  echo "You are in a Conda environment: $CONDA_DEFAULT_ENV"

  # Check if libcudf is installed
  if conda list | grep -q "^libcudf"; then
    echo "libcudf is installed in this environment."
  else
    echo "libcudf is NOT installed in this environment."
    exit 1
  fi
else
  echo "You are NOT in a Conda environment."
  exit 1
fi

# Check if LIBCUDF_ENV_PREFIX is set
if [[ -z "$LIBCUDF_ENV_PREFIX" ]]; then
  echo "LIBCUDF_ENV_PREFIX is not set."
  exit 1
fi

# Check if it's a valid conda environment (conda-meta folder exists)
if [[ ! -d "$LIBCUDF_ENV_PREFIX/conda-meta" ]]; then
  echo "LIBCUDF_ENV_PREFIX does not point to a valid Conda environment: $LIBCUDF_ENV_PREFIX"
  exit 1
fi

# Use conda to list packages in that environment and grep for libcudf
if conda list --prefix "$LIBCUDF_ENV_PREFIX" | grep -q "^libcudf"; then
  echo "libcudf is installed in the Conda environment at $LIBCUDF_ENV_PREFIX"
else
  echo "libcudf is NOT installed in the Conda environment at $LIBCUDF_ENV_PREFIX"
  exit 1
fi