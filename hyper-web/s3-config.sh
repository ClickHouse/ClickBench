#!/bin/bash

# The default database is public so the benchmark runs without AWS credentials.
export HYPER_WEB_S3_BUCKET="${HYPER_WEB_S3_BUCKET:-csauer-public-data-uswest2}"
export HYPER_WEB_S3_REGION="${HYPER_WEB_S3_REGION:-us-west-2}"
export HYPER_WEB_S3_PREFIX="${HYPER_WEB_S3_PREFIX:-clickbench/}"
export HYPER_WEB_S3_DATABASE="${HYPER_WEB_S3_DATABASE:-hits-zstd.hyper}"
