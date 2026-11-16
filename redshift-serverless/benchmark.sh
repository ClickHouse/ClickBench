#!/bin/bash
# Redshift Serverless. Same scripts as ../redshift (symlinked here); only the
# mode differs. REDSHIFT_RPU sets the base capacity (default 128).
export REDSHIFT_MODE=serverless
exec ../redshift/benchmark.sh
