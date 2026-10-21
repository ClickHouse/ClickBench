#!/bin/bash
set -eu
cd "$(dirname "$0")"
if [ "${DUCKFLIGHT_BENCH_CLIENT:-rust}" = rust ]; then
    case "$(uname -s)" in
        Linux)
            if ! command -v cc >/dev/null 2>&1 || ! command -v pkg-config >/dev/null 2>&1; then
                if ! command -v apt-get >/dev/null 2>&1; then
                    echo 'Install a C compiler, linker, make and pkg-config before building the Rust client.' >&2
                    exit 1
                fi
                privilege=()
                if [ "$(id -u)" -ne 0 ]; then privilege=(sudo); fi
                "${privilege[@]}" apt-get update
                "${privilege[@]}" apt-get install -y build-essential pkg-config
            fi
            ;;
        Darwin) xcrun --find clang >/dev/null ;;
    esac
fi
if ! command -v uv >/dev/null 2>&1; then
    mkdir -p .tools
    curl -LsSf https://astral.sh/uv/0.12.13/install.sh -o .tools/install-uv.sh
    UV_INSTALL_DIR="$PWD/.tools" UV_NO_MODIFY_PATH=1 sh .tools/install-uv.sh
    export PATH="$PWD/.tools:$PATH"
fi
uv sync --frozen --python 3.12
uv run --frozen --no-sync python harness.py install
case "${DUCKFLIGHT_BENCH_CLIENT:-rust}" in
    rust) bash native-client/build.sh ;;
    python) ;;
    *) echo 'DUCKFLIGHT_BENCH_CLIENT must be rust or python' >&2; exit 2 ;;
esac
