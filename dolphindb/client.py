#!/usr/bin/env python3
"""DolphinDB client for the ClickBench harness.

DolphinDB ships no command-line SQL client: the server package contains the
server, a web notebook and the DolphinDB script interpreter, and everything
else talks to it over the native binary protocol through one of the language
APIs. This wraps the Python API (`pip install dolphindb`) in the three
operations the harness needs.

    check   connect and evaluate 1+1; non-zero exit means the server is not
            answering yet
    load    run create.sql, then bulk-load hits.csv into the DFS table
    query   read one query from stdin, run it, print the result on stdout and
            the elapsed seconds on stderr
"""
import os
import sys
import time

import dolphindb as ddb

HOST = os.environ.get("DOLPHINDB_HOST", "localhost")
PORT = int(os.environ.get("DOLPHINDB_PORT", "8848"))
# Documented defaults of a fresh install. A DFS table is not readable by an
# anonymous session ("Not granted to read table"), so the client logs in.
USER = os.environ.get("DOLPHINDB_USER", "admin")
PASSWORD = os.environ.get("DOLPHINDB_PASSWORD", "123456")

DATABASE = "dfs://clickbench"
TABLE = "hits"


def connect():
    session = ddb.session()
    session.connect(HOST, PORT, USER, PASSWORD)
    return session


def do_check(session):
    if session.run("1+1") != 2:
        raise RuntimeError("server did not evaluate 1+1 to 2")


def do_load(session):
    session.run(f'if (existsDatabase("{DATABASE}")) dropDatabase("{DATABASE}")')
    with open("create.sql", encoding="utf-8") as f:
        session.run(f.read())

    # Two things loadTextEx needs spelled out:
    #
    # schema  - hits.csv has no header row, so without it the loader names the
    #           columns col0..col104 and types them by sniffing. Read the names
    #           and types back out of the table create.sql just made, so the
    #           schema is stated in exactly one place.
    # atomic  - false, i.e. commit the load as a series of transactions rather
    #           than one. Required here, and the vendor says so: "It is
    #           required to set atomic = false if the file to be loaded exceeds
    #           the cache engine capacity. Otherwise, a transaction may get
    #           stuck: it can neither be committed nor rolled back."
    #           https://docs.dolphindb.com/en/Functions/l/loadTextEx.html
    #           With the default, an 81 GB hits.csv against the shipped
    #           OLAPCacheEngineSize=2 (GB) livelocks about six minutes in:
    #           resident memory pins to the license's 8 GB ceiling and the log
    #           fills with "[TabletCache::flushContext] come across an
    #           exception : std::bad_alloc, and will retry later", once a
    #           second, forever.
    session.run(f"""
        db = database("{DATABASE}")
        sch = select name, typeString as type
              from schema(loadTable("{DATABASE}", "{TABLE}")).colDefs
        loaded = loadTextEx(dbHandle=db, tableName="{TABLE}",
                            partitionColumns="EventDate",
                            filename="{os.path.abspath('hits.csv')}",
                            delimiter=',', schema=sch, atomic=false)
    """)

    # loadTextEx writes chunks straight through, but an INSERT would land in
    # the OLAP cache engine (OLAPCacheEngineSize=2 in the shipped config) and
    # be flushed in the background. Force it out so the load time the harness
    # measures covers making the data durable, the same as the sync it does
    # for everyone else.
    session.run("flushOLAPCache()")


def do_query(session):
    query = sys.stdin.read().strip()
    if not query:
        raise RuntimeError("no query on stdin")

    # Bind the DFS table into the session and run the query as one script, so
    # the timing covers resolving the table (a cold read of the chunk metadata
    # after drop_caches) the same way a single SELECT would in a SQL client.
    script = f'{TABLE} = loadTable("{DATABASE}", "{TABLE}")\n{query}'

    start = time.time()
    result = session.run(script)
    elapsed = time.time() - start

    # The result has already crossed the wire at this point; printing it is
    # outside the measured window but keeps the run honest about not
    # suppressing output.
    print(result)
    print(f"{elapsed:.3f}", file=sys.stderr)


def main():
    actions = {"check": do_check, "load": do_load, "query": do_query}
    if len(sys.argv) != 2 or sys.argv[1] not in actions:
        print(f"usage: {sys.argv[0]} {{{'|'.join(actions)}}}", file=sys.stderr)
        return 2
    actions[sys.argv[1]](connect())
    return 0


if __name__ == "__main__":
    sys.exit(main())
