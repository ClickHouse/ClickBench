#!/usr/bin/env python3

import duckdb

# Load the data to determine the memory use.
# This load is not timed.
con = duckdb.connect(read_only=False)

# enable the progress bar
con.execute('PRAGMA enable_progress_bar;')
con.execute('PRAGMA enable_print_progress_bar;')
# disable preservation of insertion order
con.execute("SET preserve_insertion_order = false;")

con.execute(open("create.sql").read())
con.execute(open("load.sql").read())
