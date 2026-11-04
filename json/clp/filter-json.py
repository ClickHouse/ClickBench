# Copies NDJSON from stdin to stdout, dropping the lines that are not valid
# JSON objects (see ./load). The valid lines are passed through unchanged.
import json
import sys

out = sys.stdout.buffer
skipped = 0
for line in sys.stdin.buffer:
    try:
        valid = isinstance(json.loads(line), dict)
    except ValueError:
        valid = False
    if valid:
        out.write(line)
    else:
        skipped += 1
if skipped:
    print(f"load: skipped {skipped} invalid lines in {sys.argv[1]}", file=sys.stderr)
