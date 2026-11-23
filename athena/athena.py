"""boto3 client for the Athena entries.

    athena.py query     SQL on stdin; rows -> stdout, seconds -> stderr
    athena.py worker D  concurrent-QPS worker: cycle through the queries on
                        stdin until Unix time D, then print "<successful> <failed>"

Settings come from the environment, exported by env.sh: AWS_REGION,
ATHENA_DATABASE, ATHENA_WORKGROUP, ATHENA_OUTPUT.
"""
import os, sys, time
import boto3

athena = boto3.client("athena")


def run(query):
    """Run one query, wait for it, return its execution description."""
    qid = athena.start_query_execution(
        QueryString=query,
        QueryExecutionContext={"Database": os.environ["ATHENA_DATABASE"]},
        WorkGroup=os.environ["ATHENA_WORKGROUP"],
        ResultConfiguration={"OutputLocation": os.environ["ATHENA_OUTPUT"]},
        ResultReuseConfiguration={"ResultReuseByAgeConfiguration": {"Enabled": False}},
    )["QueryExecutionId"]
    while True:
        e = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]
        state = e["Status"]["State"]
        if state == "SUCCEEDED":
            return e
        if state in ("FAILED", "CANCELLED"):
            raise RuntimeError(f"query {qid} {state}: {e['Status'].get('StateChangeReason')}")
        time.sleep(0.1)


mode = sys.argv[1]
if mode == "query":
    e = run(sys.stdin.read())
    rows = athena.get_query_results(QueryExecutionId=e["QueryExecutionId"], MaxResults=100)
    for row in rows["ResultSet"]["Rows"]:
        print("\t".join(d.get("VarCharValue", "") for d in row["Data"]))
    # Athena's own measurement: queueing + planning + execution + service
    # processing, independent of the client's polling.
    print(f"{e['Statistics']['TotalExecutionTimeInMillis'] / 1000:.3f}", file=sys.stderr)

elif mode == "worker":
    deadline = float(sys.argv[2])
    queries = [q for q in sys.stdin.read().splitlines() if q.strip()]
    ok = err = i = 0
    while time.time() < deadline:
        try:
            run(queries[i])
            ok += 1
        except Exception as ex:
            err += 1
            print(f"concurrent-worker: {ex}", file=sys.stderr)
        i = (i + 1) % len(queries)
    print(ok, err)

else:
    sys.exit(f"unknown mode {mode}")
