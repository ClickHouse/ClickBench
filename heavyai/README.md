# HeavyDB / Heavy.AI

## Sourcing the binary (May 2026)

HEAVY.AI's apt repo and tarball CDN both started returning S3 `AccessDenied`:

    https://releases.heavy.ai/GPG-KEY-heavyai      -> 403
    https://releases.heavy.ai/os/apt/dists/...     -> 403
    https://releases.heavy.ai/os/tar/...           -> 403

The source repo at `github.com/heavyai/heavydb` is alive (v9.0.0 released 2025-10-20, not archived) but its GitHub releases ship no compiled artifacts, and a full C++ build is too heavy to run inside cloud-init.

`omnisci/core-os-cpu:v5.10.2` is the last public Docker image (Feb 2022) — it is OmniSciDB, the immediate predecessor of HeavyDB before the v6.0.0 rename. The benchmark schema and queries are vanilla enough to run unchanged against it. `install` now pulls that image, bind-mounts a `heavyai-storage/` directory, and the rest of the scripts (start / check / load / query / data-size) drive the container via `omnisql` instead of the systemd-managed native install.

Override `HEAVYAI_VERSION` if you want a different OmniSci tag; the available ones are listed at <https://hub.docker.com/r/omnisci/core-os-cpu/tags>.
