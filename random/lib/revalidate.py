"""Validates the results of a machine again, with the current validator.

The machines send all the outputs of the correct-looking runs and the
reference results, compressed (outputs_gz, reference_gz, see run-system.sh).
A fix of the validator then applies to the runs of the past: the statuses of
the runs whose output is stored are computed again; the other runs keep the
status from the machine. The counts follow.
"""

import base64
import gzip
import json

import validate

FAILED_ON_MACHINE = ("error", "timeout", "unsupported")


def unpack(blob):
    return json.loads(gzip.decompress(base64.b64decode(blob))) if blob else {}


def revalidate(result):
    """Updates the statuses of `result` in place; returns the number of changed runs."""
    if not result.get("outputs_gz") or not result.get("reference_gz"):
        return 0
    outputs = unpack(result["outputs_gz"])
    references = {q: validate.parse_reference(t.encode()) for q, t in unpack(result["reference_gz"]).items()}
    changed = 0
    for e in result["executions"]:
        if e["status"] in FAILED_ON_MACHINE:
            continue
        key = f"{e['id']}.{e['repeat']}"
        if key not in outputs:
            continue
        if e["id"] not in references:
            status, detail = "unverified", "reference: no result"
        else:
            status, detail = validate.compare(references[e["id"]], outputs[key].encode())
        if status != e["status"]:
            changed += 1
        e["status"], e["detail"] = status, detail
    counts = {}
    for e in result["executions"]:
        counts[e["status"]] = counts.get(e["status"], 0) + 1
    result["counts"] = counts
    result["revalidated"] = True
    return changed
