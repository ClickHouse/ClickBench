"""Native (PostgreSQL protocol) client for the Redshift entries.

    rs.py <connection file> query     SQL on stdin; rows -> stdout, seconds -> stderr
    rs.py <connection file> check     SELECT 1
    rs.py <connection file> worker D  concurrent-QPS worker: cycle through the
                                      queries on stdin until Unix time D, then
                                      print "<successful> <failed>"

The connection file is written by ./provision: host, port, user, password,
one per line.
"""
import sys, time
import redshift_connector

conn_file, mode = sys.argv[1], sys.argv[2]
host, port, user, password = open(conn_file).read().split("\n")[:4]


def connect():
    con = redshift_connector.connect(host=host, port=int(port), database="dev",
                                     user=user, password=password)
    con.autocommit = True
    cur = con.cursor()
    cur.execute("SET enable_result_cache_for_session TO off")
    return con, cur


def run(cur, query):
    cur.execute(query)
    return cur.fetchall() if cur.description else []


if mode == "check":
    con, cur = connect()
    run(cur, "SELECT 1")

elif mode == "query":
    query = sys.stdin.read().strip().rstrip(";")
    con, cur = connect()
    start = time.monotonic()
    rows = run(cur, query)
    elapsed = time.monotonic() - start
    for row in rows[:100]:
        print("\t".join(map(str, row)))
    print(f"{elapsed:.3f}", file=sys.stderr)

elif mode == "worker":
    deadline = float(sys.argv[3])
    queries = [q.strip().rstrip(";") for q in sys.stdin.read().splitlines() if q.strip()]
    con, cur = connect()
    ok = err = i = 0
    while time.time() < deadline:
        try:
            run(cur, queries[i])
            ok += 1
        except Exception as e:
            err += 1
            print(f"concurrent-worker: {e}", file=sys.stderr)
            try:
                con.close()
            except Exception:
                pass
            try:
                con, cur = connect()
            except Exception as e:
                print(f"concurrent-worker: reconnect: {e}", file=sys.stderr)
                time.sleep(1)
        i = (i + 1) % len(queries)
    print(ok, err)

else:
    sys.exit(f"unknown mode {mode}")
