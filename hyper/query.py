#!/usr/bin/env python3
import timeit
import sys

from tableauhyperapi import HyperProcess, Telemetry, Connection, CreateMode, HyperException

query = sys.stdin.read()

with HyperProcess(telemetry=Telemetry.DO_NOT_SEND_USAGE_DATA_TO_TABLEAU) as hyper:
    with Connection(hyper.endpoint, 'hits.hyper', CreateMode.NONE) as connection:
        for _ in range(3):
            start = timeit.default_timer()
            try:
                connection.execute_list_query(query)
                print(round(timeit.default_timer() - start, 3))
            except HyperException:
                print("null")
