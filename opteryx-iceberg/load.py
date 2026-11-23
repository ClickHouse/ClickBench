"""CREATE TABLE, then the single INSERT ... SELECT from the downloaded Parquet
files (./hits/hits_*.parquet), with the default settings."""

import os

import opteryx

import lake

lake.register()
here = os.path.dirname(os.path.abspath(__file__))
for script in ("create.sql", "insert.sql"):
    with open(os.path.join(here, script)) as handle:
        sql = handle.read()
    session = opteryx.session()
    for _ in session.execute_to_morsels(sql):
        pass
    session.close()
