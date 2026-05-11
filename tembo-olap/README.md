## Status

Tembo's OLAP cloud stack has been discontinued — `cloud.tembo.io` no
longer resolves. The result under `results/20240209/` is preserved as a
historical data point and tagged `"historical"`; this benchmark cannot be
re-run as written. The instructions below are kept for reference.

# Instantiation

1) Create Account and Login to https://cloud.tembo.io
2) Select OLAP Stack after clicking Create Instance button

## Choose System Configuration:

**Instance Type**: Compute Optimized (CI-32)

**CPU**: 16vCPU

**RAM** : 32GB

**Storage**: 500GB 

Note: instance creation takes *20-25* seconds.

## Specify Connection params
Tembo provides connection-string through instance **Home** tab.

Use hostname and password taken from Tembo console and specify them in benchmark.sh
```
HOSTNAME="<hostname>"
PASSWORD="<password>"
```

## Start Benchmark

```
./benchmark.sh
```