#!/usr/bin/env python3
import timeit

from tableauhyperapi import HyperProcess, Telemetry, Connection, CreateMode

with HyperProcess(telemetry=Telemetry.DO_NOT_SEND_USAGE_DATA_TO_TABLEAU) as hyper:
    with Connection(hyper.endpoint, 'hits.hyper', CreateMode.CREATE_AND_REPLACE) as connection:
        start = timeit.default_timer()
        connection.execute_command(open("create.sql").read())
        connection.execute_command("copy hits from 'hits.csv' with (format csv)")
        print(f"Load time: {timeit.default_timer() - start}") # 4m29s

