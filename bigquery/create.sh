#!/bin/bash

bq mk --dataset test

bq query --use_legacy_sql=false < create.sql
