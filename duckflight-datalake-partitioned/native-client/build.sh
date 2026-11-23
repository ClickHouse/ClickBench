#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_dir="$(uv run --frozen --no-sync python native-client/prepare.py)"
toolchain=1.99.0
if command -v rustup >/dev/null 2>&1 && rustup run "$toolchain" rustc --version >/dev/null 2>&1; then
    export RUSTUP_TOOLCHAIN="$toolchain"
else
    export CARGO_HOME="$PWD/.tools/cargo"
    export RUSTUP_HOME="$PWD/.tools/rustup"
    curl --fail --location --retry 3 https://sh.rustup.rs -o .tools/install-rust.sh
    sh .tools/install-rust.sh -y --no-modify-path --profile minimal --default-toolchain "$toolchain"
    export PATH="$CARGO_HOME/bin:$PATH"
    export RUSTUP_TOOLCHAIN="$toolchain"
fi
toolchain_bin="$(dirname "$(rustup which --toolchain "$toolchain" cargo)")"
export PATH="$toolchain_bin:$PATH"
compiler="${RUSTC:-rustc}"
case "$("$compiler" --version)" in
    "rustc $toolchain "*) ;;
    *) echo "The native client requires Rust $toolchain." >&2; exit 1 ;;
esac
"$compiler" -Vv > .tools/rust-toolchain.txt
cargo --version >> .tools/rust-toolchain.txt
build=(cargo)
if command -v mbx >/dev/null 2>&1 \
    && [ -z "${RUSTC_WRAPPER:-}${RUSTC_WORKSPACE_WRAPPER:-}${CARGO_BUILD_RUSTC_WRAPPER:-}${CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER:-}" ]; then
    build=(mbx)
else
    echo 'Building the Arrow client with Cargo without Boxington.' >&2
fi
"${build[@]}" build --release --locked --manifest-path "$source_dir/Cargo.toml" \
    --bin flight_sql_client --features cli,flight-sql,tls-ring \
    --jobs "${DUCKFLIGHT_BENCH_BUILD_JOBS:-2}"
target_dir="${CARGO_TARGET_DIR:-$source_dir/target}"
cp "$target_dir/release/flight_sql_client" .tools/flight_sql_client
