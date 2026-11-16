#!/usr/bin/env python3
# Let Kylin design models from the benchmark queries, then build them.
#
# 1. POST /api/models/model_suggestion: Kylin's SQL-based recommendation
#    proposes models with aggregate indexes, table indexes and computed
#    columns for the given queries and saves them online, with one empty
#    full-range segment each (the model has no partition column).
# 2. POST /api/models/{model}/indexes: fill that segment with every index.
# 3. Wait for the build jobs to finish.
#
# Queries that Kylin cannot model are listed in "error_sqls"; at query time
# they are pushed down to Spark like in the `kylin` entry.

import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("KYLIN_URL", "http://localhost:7070") + "/kylin/api"
PROJECT = "clickbench"
HEADERS = {
    "Authorization": os.environ["KYLIN_AUTH_HEADER"].split(": ", 1)[1],
    "Accept": "application/vnd.apache.kylin-v4-public+json",
    "Accept-Language": "en",
    "Content-Type": "application/json;charset=utf-8",
}


def call(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=HEADERS)
    try:
        with urllib.request.urlopen(req, timeout=3600) as resp:
            envelope = json.load(resp)
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} failed: HTTP {e.code}: {e.read().decode(errors='replace')}")
    if envelope.get("code") != "000":
        sys.exit(f"{method} {path} failed: {json.dumps(envelope)}")
    return envelope["data"]


sqls = [line.strip().rstrip(";").strip() for line in open(sys.argv[1]) if line.strip()]
print(f"suggesting models for {len(sqls)} queries", flush=True)

suggestion = call("POST", "/models/model_suggestion", {
    "project": PROJECT,
    "sqls": sqls,
    "with_segment": True,
    "with_model_online": True,
})

models = list({m["alias"]: m for m in suggestion["models"] + suggestion.get("optimal_models", [])}.values())
if not models:
    sys.exit("Kylin suggested no models: " + json.dumps(suggestion))
for model in models:
    indexes = model.get("indexes", [])
    print(f"model {model['alias']}: {len(indexes)} indexes", flush=True)
    for index in indexes:
        print("    index {}: {} dimensions, {} measures, {} computed columns, {} queries".format(
            index.get("index_id"), len(index.get("dimensions", [])), len(index.get("measures", [])),
            len(index.get("computed_columns", [])), len(index.get("sqls", []))), flush=True)
error_sqls = suggestion.get("error_sqls", [])
print(f"{len(error_sqls)} queries are not answered by any index (pushdown):", flush=True)
for sql in error_sqls:
    print(f"    Q{sqls.index(sql) + 1}: {sql}", flush=True)

job_ids = []
for model in models:
    build = call("POST", f"/models/{model['alias']}/indexes", {"project": PROJECT})
    print(f"build of model {model['alias']}: {json.dumps(build)}", flush=True)
    if build.get("type") != "NORM_BUILD" or not build.get("job_id"):
        sys.exit(f"no build job was created for model {model['alias']}")
    job_ids.append(build["job_id"])

FAILED = {"ERROR", "DISCARDED", "STOPPED", "SUICIDAL", "LAUNCHING_ERROR"}
last_report = 0
while True:
    jobs = call("GET", f"/jobs?project={PROJECT}&time_filter=4&page_size=1000")["value"]
    status = {job["id"]: job for job in jobs if job["id"] in job_ids}
    missing = set(job_ids) - set(status)
    if missing:
        sys.exit(f"build jobs disappeared: {sorted(missing)}")
    failed = [job for job in status.values() if job["job_status"] in FAILED]
    if failed:
        sys.exit("build failed: " + json.dumps(failed))
    if all(job["job_status"] == "FINISHED" for job in status.values()):
        break
    if time.time() - last_report >= 60:
        last_report = time.time()
        print("build: " + ", ".join(f"{job['job_status']} {job.get('progress', 0):.0f}%"
                                    for job in status.values()), flush=True)
    time.sleep(5)

print("all indexes are built", flush=True)
