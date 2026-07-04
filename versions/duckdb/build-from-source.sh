#!/usr/bin/env bash
# Build a DuckDB CLI from source for versions with no published Linux binary (pre-0.1.9,
# i.e. 0.1.0-0.1.8, released 2019-2020). Used by run-version.sh when versions.tsv marks a
# version as "source"; the DB cloud-init installs the toolchain (build-essential, cmake).
#
#   ./build-from-source.sh <version> <output-binary-path>
#
# Two fixes make the 2019-era sources build on a modern toolchain: modern CMake removed
# compatibility with the old cmake_minimum_required (-> CMAKE_POLICY_VERSION_MINIMUM=3.5),
# and GCC 13 no longer transitively includes <cstdint>/<cstddef> (-> force-include them).
set -euo pipefail

VERSION="${1:?usage: build-from-source.sh <version> <output-binary-path>}"
OUT="${2:?usage: build-from-source.sh <version> <output-binary-path>}"
[ -x "${OUT}" ] && { echo "duckdb ${VERSION} already built at ${OUT}" >&2; exit 0; }

command -v cmake >/dev/null && command -v g++ >/dev/null \
    || { echo "need cmake + g++ (build-essential) to build DuckDB ${VERSION}" >&2; exit 1; }

SRC="$(mktemp -d)"
trap 'rm -rf "${SRC}"' EXIT
echo "building DuckDB ${VERSION} from source (v${VERSION})..." >&2
git clone -q --branch "v${VERSION}" --depth 1 https://github.com/duckdb/duckdb "${SRC}" \
    || { echo "git clone of v${VERSION} failed" >&2; exit 1; }
mkdir -p "${SRC}/build" && cd "${SRC}/build"
cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHELL=1 \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_CXX_FLAGS="-include cstdint -include cstddef" .. >/dev/null 2>&1 \
    || { echo "cmake failed for ${VERSION}" >&2; exit 1; }
make -j"$(nproc)" shell >/dev/null 2>&1 || { echo "make failed for ${VERSION}" >&2; exit 1; }

# Old builds name the CLI `duckdb_cli`; newer ones `duckdb`. Take whichever exists.
bin="$(find . -maxdepth 3 -type f -executable \( -name duckdb_cli -o -name duckdb \) | head -1)"
[ -n "${bin}" ] || { echo "no CLI binary produced for ${VERSION}" >&2; exit 1; }
mkdir -p "$(dirname "${OUT}")"; cp "${bin}" "${OUT}"; chmod +x "${OUT}"
echo "built ${VERSION} -> ${OUT}" >&2
[ -x "${OUT}" ]
