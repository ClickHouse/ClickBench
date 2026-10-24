# Security Policy

## Supported Artifacts

Only official evaluation packages and native standalone binaries (`silicium_runner` and `silicium_ingest` for `x86_64` and `aarch64`) matching the cryptographic SHA-256 digests listed in `checksums.sha256` and `install` are supported for benchmark verification.

## Integrity Verification

Before executing any benchmark or starting the PostgreSQL v3 wire server, verify file integrity:

```bash
sha256sum -c checksums.sha256
```

## Reporting a Vulnerability

If you discover a memory safety issue, wire protocol boundary vulnerability, or artifact integrity discrepancy, please open a confidential security advisory on the evaluation repository or contact the Silicium Architecture Research Team (`silicium369@gmail.com`) with a minimal reproduction script and hardware environment details.
