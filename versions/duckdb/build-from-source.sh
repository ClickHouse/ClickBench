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
# Bound the build so a flaky/stuck old build can't burn the sweep's whole per-version budget.
BUILD_TIMEOUT="${BUILD_TIMEOUT:-2400}"           # 40 min
mkdir -p "${SRC}/build" && cd "${SRC}/build"
# -fcommon: pre-2020 C in the bundled third_party (hyperloglog's sds.c) defines globals in a
# header without extern; GCC 10+ defaults to -fno-common and rejects them as multiple definitions
# ("multiple definition of `SDS_NOINIT'"). -fcommon restores the old tentative-definition merging.
timeout "${BUILD_TIMEOUT}" cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHELL=1 \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -DCMAKE_C_FLAGS="-fcommon" \
      -DCMAKE_CXX_FLAGS="-fcommon -include cstdint -include cstddef" .. >/dev/null 2>&1 \
    || { echo "cmake failed/timed out for ${VERSION}" >&2; exit 1; }
timeout "${BUILD_TIMEOUT}" make -j"$(nproc)" shell >/dev/null 2>&1 || { echo "make failed/timed out for ${VERSION}" >&2; exit 1; }

# The CLI binary is named `duckdb` (newer), `duckdb_cli` (mid), or `shell` (0.1.0-0.1.2, under
# tools/shell/). Prefer the duckdb name; fall back to shell.
bin="$(find . -maxdepth 3 -type f -executable \( -name duckdb_cli -o -name duckdb \) | head -1)"
[ -n "${bin}" ] || bin="$(find . -maxdepth 3 -type f -executable -name shell | head -1)"
[ -n "${bin}" ] || { echo "no CLI binary produced for ${VERSION}" >&2; exit 1; }
mkdir -p "$(dirname "${OUT}")"
# 0.1.0-0.1.2 build a DYNAMIC shell that needs libduckdb.so / libsqlite3_api_wrapper.so, which
# live in the (soon-deleted) build tree. If so, bundle the binary + all its .so into <OUT>.libs
# and make OUT a wrapper that points LD_LIBRARY_PATH there. Newer versions are a self-contained
# static binary -> copy as-is.
if ldd "${bin}" 2>/dev/null | grep -qE 'libduckdb\.so|libsqlite3_api_wrapper\.so|=> not found'; then
    libdir="${OUT}.libs"; rm -rf "${libdir}"; mkdir -p "${libdir}"
    cp "${bin}" "${libdir}/duckdb-bin"; chmod +x "${libdir}/duckdb-bin"
    find . -maxdepth 4 -name '*.so' -exec cp {} "${libdir}/" \; 2>/dev/null
    cat > "${OUT}" <<WRAP
#!/bin/sh
exec env LD_LIBRARY_PATH="${libdir}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" "${libdir}/duckdb-bin" "\$@"
WRAP
    chmod +x "${OUT}"
    echo "built ${VERSION} (dynamic; bundled $(ls "${libdir}"/*.so 2>/dev/null | wc -l) libs) -> ${OUT}" >&2
else
    cp "${bin}" "${OUT}"; chmod +x "${OUT}"
    echo "built ${VERSION} -> ${OUT}" >&2
fi
[ -x "${OUT}" ]
