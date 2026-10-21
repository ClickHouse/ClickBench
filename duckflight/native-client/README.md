# Native ClickBench client

`prepare.py` downloads checksum-pinned Apache Arrow `arrow-flight` 60.0.0 from
the public crate registry. A small checked patch adds opt-in timing and complete
CSV output. Upstream connection,
authentication, direct SQL execution and complete stream collection are unchanged.
Elapsed seconds are emitted on stderr, as required by ClickBench's query hook.

`Cargo.lock` preserves the measured build's dependency resolution.
Generated source, toolchains and binaries stay under the ignored `.tools` directory.
`build.sh` uses Boxington when installed and preserves an existing Rust compiler
wrapper by using Cargo when another wrapper is selected in the environment.
Rust 1.99.0 is selected explicitly, including when a different standalone Cargo
appears earlier on PATH. The chosen compiler details are recorded in
`.tools/rust-toolchain.txt`.

The timer begins after connecting and authenticating and ends after collecting
all Arrow batches. CSV serialization happens afterward. NULL uses `\N`; empty
strings remain empty. Failed queries return nonzero without a success timing.
