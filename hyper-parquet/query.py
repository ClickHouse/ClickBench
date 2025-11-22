#!/usr/bin/env python3
import timeit
import sys
import subprocess

from tableauhyperapi import HyperProcess, Telemetry, Connection, CreateMode, HyperException

query = sys.stdin.read()

with HyperProcess(telemetry=Telemetry.DO_NOT_SEND_USAGE_DATA_TO_TABLEAU) as hyper:
    with Connection(hyper.endpoint) as connection:
        # Hyper only supports temporary external tables, so we need to create them on every query
        connection.execute_command(open("create.sql").read())
        for try_num in range(3):
            if try_num == 0:
                # Flush OS page cache before first run of each query
                subprocess.run(['sync'], check=True)
                subprocess.run(['sudo', 'tee', '/proc/sys/vm/drop_caches'], input=b'3', check=True, stdout=subprocess.DEVNULL)

            start = timeit.default_timer()
            try:
                connection.execute_list_query(query)
                print(round(timeit.default_timer() - start, 3))
            except HyperException:
                print("null")
