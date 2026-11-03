# Passes through the lines of stdin that are JSON objects, drops the others
# (see ./load). Stricter than json.loads alone: NaN/Infinity and unpaired
# surrogate escapes (which json.loads accepts) are dropped as well, because
# they are not valid JSON for the server either.
import json
import sys


def reject_constant(name):
    raise ValueError(name)


out = sys.stdout.buffer
skipped = 0
for line in sys.stdin.buffer:
    try:
        doc = json.loads(line, parse_constant=reject_constant)
        valid = isinstance(doc, dict)
        if valid:
            json.dumps(doc, ensure_ascii=False).encode('utf-8')
    except ValueError:
        valid = False
    if valid:
        out.write(line)
    else:
        skipped += 1
if skipped:
    print(f"load: skipped {skipped} invalid lines", file=sys.stderr)
