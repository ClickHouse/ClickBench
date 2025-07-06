#!/usr/bin/env python3
import timeit
import sys

from tableauhyperapi import HyperProcess, Telemetry, Connection, CreateMode, HyperException

query = sys.stdin.read()

with HyperProcess(telemetry=Telemetry.DO_NOT_SEND_USAGE_DATA_TO_TABLEAU) as hyper:
    with Connection(hyper.endpoint) as connection:
        # Hyper only supports temporary external tables, so we need to create them on every query
        connection.execute_command(open("create.sql").read())
        for _ in range(3):
            start = timeit.default_timer()
            try:
                connection.execute_list_query(query)
                print(round(timeit.default_timer() - start, 3))
            except HyperException:
                print("null")
