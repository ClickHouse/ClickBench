#!/usr/bin/env python3
"""Compares the results of a system with the reference results.

Usage: validate.py <reference dir> <driver output dir>

The reference dir has <id>.tsv (from reference.py, TSVWithNames) and status.json; the driver
output dir has out/<id>.<repeat>.out and run.json (from driver.py). Writes
<driver output dir>/validation.json and prints a summary.

The systems print their results in their own formats (tables with borders,
CSV, JSON, S-expressions...), so the comparison does not parse them. It takes
the values of the reference result, cell by cell in order, and checks that
they are present in the output of the system in the same order, separated only
by separators: whitespace, punctuation, borders, and the like. Before the
first value there may be anything (a header); after the last value, a short
footer (like "(10 rows)").

Tolerated:
  - numbers in another notation or precision (1.5, 1.50, 1.5e0; a float
    printed with fewer digits matches within the precision it was printed with),
  - booleans as true/false, t/f for 1/0,
  - times as 2013-07-15T10:20:30, with fractional zeros or a UTC suffix,
  - NULL and empty strings printed as anything or nothing,
  - differences of escaping: backslashes and quotes are ignored,
  - a few mangled characters: U+FFFD or ? instead of a non-ASCII character.

Statuses of an execution: ok, wrong (the output does not match; "order" if
the rows are right but their order differs), error, timeout, unsupported, and
unverified (the system returned a result, but the reference has none: it
failed or timed out).
"""

import json
import math
import os
import re
import sys

NUMBER = re.compile(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?")
NUMERIC_CELL = re.compile(r"^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$|^[-+]?(?:inf|nan)$", re.I)
DATETIME_CELL = re.compile(r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})(\.\d+)?$")
DATE_CELL = re.compile(r"^\d{4}-\d{2}-\d{2}$")
NULL_WORDS = re.compile(r"(?:NULL|null|Null|None|none|NaN|nan|<NA>|N/A|\\N|NA|\u1d3a\u1d41\u1d38\u1d38)(?![\w])")
TRUE_WORDS = re.compile(r"(?:true|TRUE|True|t)(?![\w])")
FALSE_WORDS = re.compile(r"(?:false|FALSE|False|f)(?![\w])")
# The readable-number hints of ClickHouse's Pretty formats: "-- 1.23 million".
HINT = re.compile(r"--\s*[\d.]+\s+(?:thousand|million|billion|trillion|quadrillion)")
FOOTER_TOKENS = 6
# Footers of the clients: "(10 rows)", "10 rows in set", "Elapsed: 0.1 sec",
# "2 rows  3 columns" and "100 rows (100 shown)" of DuckDB's box mode.
FOOTER = re.compile(r"\(?\d+ (?:rows?|columns?|shown)\)?(?: in set)?|Elapsed:?\s*[\d.]+\s*(?:sec|s|ms)?|Run Time[^\n]*|Time:?\s*[\d.]+\s*(?:sec|s|ms)?|Processed [^\n]*", re.I)
MAX_STARTS = 200


def unescape_tsv(cell):
    if cell == "\\N":
        return None
    out, i = [], 0
    mapping = {"t": "\t", "n": "\n", "r": "\r", "b": "\b", "f": "\f", "0": "\0", "\\": "\\", "'": "'", "N": "N"}
    while i < len(cell):
        c = cell[i]
        if c == "\\" and i + 1 < len(cell):
            out.append(mapping.get(cell[i + 1], cell[i + 1]))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def parse_reference(data):
    """Returns (column names, rows) of a result in TSVWithNames."""
    text = data.decode("utf-8", errors="replace")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    names = [unescape_tsv(c) or "" for c in lines[0].split("\t")] if lines else []
    return names, [[unescape_tsv(c) for c in line.split("\t")] for line in lines[1:]]


CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
UNICODE_ESCAPE = re.compile(r"\\u([0-9a-fA-F]{4})")
# The hints of the Pretty formats of ClickHouse after a row with a large
# number: "│ 2514652 │ -- 2.51 million".
NUMBER_HINT = re.compile(r"(?m)(?<=[│┃|])[ \t]*-- -?[\d.]+ (?:thousand|million|billion|trillion|quadrillion|quintillion)[ \t]*$")


def clean(text):
    """Escaping differences: literal \\n, \\t, \\r and \\uXXXX (of JSON) become
    characters, the control characters other than the newline and the tab are
    dropped (a system prints them raw, escaped or not at all), then all
    backslashes and quotes are dropped."""
    text = UNICODE_ESCAPE.sub(lambda m: chr(int(m.group(1), 16)), text)
    text = text.replace("\\n", "\n").replace("\\t", "\t").replace("\\r", "\r")
    text = CONTROL.sub("", text)
    text = NUMBER_HINT.sub("", text)
    return re.sub(r"[ \t]+", " ", re.sub(r"[\\\"'`]", "", text))


def is_separator(ch):
    return not ch.isalnum() and ch not in "�?_"


# Words that may stand between values: the column names (keys of JSON-like
# outputs, labels of vertical outputs). Set for every comparison.
GAP_WORDS = set()
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
ROW_NUMBER = re.compile(r"(?:Row\s+)?\d+[.):](?=\s)")
LINE_ROW_NUMBER = re.compile(r"(?m)^\s*(?:Row\s+)?\d+[.):](?=\s)")


def skip_separators(text, pos):
    while pos < len(text):
        if is_separator(text[pos]):
            pos += 1
            continue
        m = WORD.match(text, pos)
        if m and m.group(0) in GAP_WORDS and (pos == 0 or not text[pos - 1].isalnum()):
            pos = m.end()
            continue
        # A row number at the start of a line: "1.", "1)", "Row 1:".
        m = ROW_NUMBER.match(text, pos)
        if m and text[text.rfind("\n", 0, pos) + 1:pos].strip() == "":
            pos = m.end()
            continue
        break
    return pos


def number_matches(ref, token):
    try:
        a, b = float(ref), float(token)
    except ValueError:
        return False
    if math.isnan(a) or math.isnan(b):
        return math.isnan(a) and math.isnan(b)
    if a == b:
        return True
    # Integers are exact; floats are approximate.
    if re.fullmatch(r"[-+]?\d+", ref) and re.fullmatch(r"[-+]?\d+", token):
        return False
    if abs(a - b) <= 1e-6 * max(abs(a), abs(b)) or abs(a - b) <= 1e-12:
        return True
    # A float printed with fewer digits matches within the precision it was
    # printed with, if it has at least 4 significant digits.
    mantissa = token.lower().split("e")[0].lstrip("+-")
    if "." not in mantissa or len(mantissa.replace(".", "").lstrip("0")) < 4:
        return False
    decimals = len(mantissa.split(".")[1])
    exponent = int(token.lower().split("e")[1]) if "e" in token.lower() else 0
    return abs(a - b) <= 0.5 * 10 ** (exponent - decimals)


def match_string(cell, text, pos):
    """Returns the end of a match of the string at pos, or None."""
    if text.startswith(cell, pos):
        return pos + len(cell)
    if all(ord(c) < 128 for c in cell):
        return None
    # Mangled characters: a non-ASCII character may come as U+FFFD (one or more) or ?.
    pattern = "".join(re.escape(c) if ord(c) < 128 else f"(?:{re.escape(c)}|�+|\\?)" for c in cell)
    m = re.compile(pattern).match(text, pos)
    if not m:
        return None
    mangled = sum(1 for _ in re.finditer("�+|\\?", m.group(0))) - cell.count("?")
    non_ascii = sum(1 for c in cell if ord(c) >= 128)
    return m.end() if mangled <= max(3, non_ascii // 20) else None


def match_cell(cell, text, pos):
    """Returns the end of a match of the cell at pos (after separators), or None.
    An empty or NULL cell may match nothing."""
    if cell is None or cell.strip() == "":
        m = NULL_WORDS.match(text, pos)
        return m.end() if m else pos
    value = clean(cell).strip()
    if NUMERIC_CELL.match(value):
        m = NUMBER.match(text, pos)
        if m and number_matches(value, m.group(0)) and not (m.end() < len(text) and text[m.end()].isalnum()):
            return m.end()
        if value in ("0", "1"):
            m = (TRUE_WORDS if value == "1" else FALSE_WORDS).match(text, pos)
            if m:
                return m.end()
        if value.lower() in ("inf", "+inf", "-inf", "nan"):
            m = re.compile(r"[-+]?(?:inf(?:inity)?|nan)", re.I).match(text, pos)
            if m and m.group(0).lower().lstrip("+").startswith(value.lower().lstrip("+")[:4]):
                return m.end()
        return match_string(value, text, pos)
    m = DATETIME_CELL.match(value)
    if m:
        pattern = re.escape(m.group(1)) + r"[ T]" + re.escape(m.group(2)) + r"(?:\.0*)?(?:Z|\s?UTC|[+-]00(?::?00)?)?"
        found = re.compile(pattern).match(text, pos)
        return found.end() if found else None
    if DATE_CELL.match(value):
        found = re.compile(re.escape(value) + r"(?:[ T]00:00:00(?:\.0*)?)?").match(text, pos)
        return found.end() if found else None
    return match_string(value, text, pos)


def match_after_separators(cell, text, pos):
    """Matches the cell after the separators that follow pos. A value can begin
    with what looks like a separator (a minus sign, a parenthesis), so every
    position within the separators is tried, the last first."""
    end_of_gap = skip_separators(text, pos)
    for p in range(end_of_gap, pos - 1, -1):
        end = match_cell(cell, text, p)
        if end is not None and (end > p or p == end_of_gap):
            return end
    return None


def is_empty(cell):
    return cell is None or cell.strip() == ""


def match_sequence(cells, text, pos):
    """Matches cells one after another, separated only by separators. Returns
    the end or None. An empty or NULL cell matches a NULL word or nothing, but
    nothing only if what follows is not a number (a NULL must not come as 0)
    or is the number of the next cell."""
    for i, cell in enumerate(cells):
        if is_empty(cell):
            p = skip_separators(text, pos)
            m = NULL_WORDS.match(text, p)
            if m:
                pos = m.end()
                continue
            if NUMBER.match(text, p):
                following = next((c for c in cells[i + 1:] if not is_empty(c)), None)
                if following is None or match_cell(following, text, p) is None:
                    return None
            continue
        end = match_after_separators(cell, text, pos)
        if end is None:
            return None
        pos = end
    return pos


KEY_NUMBER = re.compile(r"\b([A-Za-z_]\w*)\s*[:=]\s*[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?")


def footer_ok(text, pos):
    """After the last value: a short footer, with statistics such as
    "rows": 10 or "elapsed": 0.1, but no more values of the result (an extra
    row of a key-value format has the column names as keys)."""
    footer = FOOTER.sub(" ", text[pos:])
    footer = KEY_NUMBER.sub(lambda m: m.group(0) if m.group(1) in GAP_WORDS else " ", footer)
    # The column names repeated after the rows (the Pretty formats of
    # ClickHouse do it after a long result); the values of an extra row of a
    # key-value format stay and fail the check.
    footer = WORD.sub(lambda m: " " if m.group(0) in GAP_WORDS else m.group(0), footer)
    return not NUMBER.search(footer) and len(re.findall(r"\w+", footer)) <= FOOTER_TOKENS


def start_positions(first, text):
    """Where the first non-empty cell can start: at word boundaries."""
    positions = []
    for p in range(len(text)):
        if p > 0 and (text[p - 1].isalnum() or text[p - 1] == "�"):
            continue
        end = match_cell(first, text, p)
        if end is not None and end > p:
            positions.append(p)
            if len(positions) >= MAX_STARTS:
                break
    return positions


def compare(reference, output):
    names, reference_rows = reference
    GAP_WORDS.clear()
    GAP_WORDS.update(w for name in names for w in WORD.findall(clean(name)))
    text = HINT.sub(" ", clean(output.decode("utf-8", errors="replace")))
    cells = [c for row in reference_rows for c in row]
    if not reference_rows or all(is_empty(c) for c in cells):
        # Nothing to find; the output must not have values either.
        rest = LINE_ROW_NUMBER.sub(" ", FOOTER.sub(" ", NULL_WORDS.sub(" ", text)))
        rest = " ".join(w for w in WORD.findall(rest) if w not in GAP_WORDS) + " " + re.sub(r"[A-Za-z_]\w*", " ", rest)
        if NUMBER.search(rest):
            return "wrong", "values for an empty result"
        return "ok", ""
    first = next(c for c in cells if not is_empty(c))
    for start in start_positions(first, text):
        end = match_sequence(cells[cells.index(first):], text, start)
        if end is not None:
            if footer_ok(text, end):
                return "ok", ""
            return "wrong", "extra output after the result"
    # Are the rows right, in another order? Every row must be found once, and
    # the rows must cover the output between the first and the last of them.
    spans = []
    for row in reference_rows:
        if all(is_empty(c) for c in row):
            continue
        row_first = next(c for c in row if not is_empty(c))
        rest = row[row.index(row_first):]
        found = None
        for start in start_positions(row_first, text):
            if any(a <= start < b for a, b in spans):
                continue
            end = match_sequence(rest, text, start)
            if end is not None:
                found = (start, end)
                break
        if not found:
            return "wrong", f"no match for the row {json.dumps(row, ensure_ascii=False)[:300]}"
        spans.append(found)
    spans.sort()
    for (_, end), (next_start, _) in zip(spans, spans[1:]):
        if skip_separators(text, end) < next_start:
            return "wrong", "the rows are found, but there is more output between them"
    return "wrong", "order"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    ref_dir, run_dir = sys.argv[1], sys.argv[2]
    with open(os.path.join(ref_dir, "status.json")) as f:
        ref_status = json.load(f)
    with open(os.path.join(run_dir, "run.json")) as f:
        run = json.load(f)
    reference_cache = {}
    results = []
    for e in run["executions"]:
        status, detail = e["status"], e.get("error", "")[:300]
        if status == "ok":
            ref = ref_status.get(e["id"], {})
            if ref.get("status") != "ok":
                status, detail = "unverified", f"reference: {ref.get('status', 'missing')}"
            else:
                if e["id"] not in reference_cache:
                    with open(os.path.join(ref_dir, e["id"] + ".tsv"), "rb") as f:
                        reference_cache[e["id"]] = parse_reference(f.read())
                with open(os.path.join(run_dir, "out", f"{e['id']}.{e['repeat']}.out"), "rb") as f:
                    output = f.read()
                status, detail = compare(reference_cache[e["id"]], output)
        results.append({"id": e["id"], "repeat": e["repeat"], "status": status, "detail": detail})
    counts = {}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    with open(os.path.join(run_dir, "validation.json"), "w") as f:
        json.dump({"counts": counts, "results": results}, f, indent=1, ensure_ascii=False)
    print(f"Validation: {json.dumps(counts)}", file=sys.stderr)


if __name__ == "__main__":
    main()
