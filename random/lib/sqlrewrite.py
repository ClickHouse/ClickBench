"""Rewrites of the generated queries for ClickHouse, so that it answers them
with the standard SQL semantics, as the settings in reference-settings do for
the rest.

ClickHouse's LENGTH, SUBSTRING, LOWER and UPPER work on bytes (and on ASCII
letters only): the standard functions, as in PostgreSQL and DuckDB, work on
characters. The generated data has non-ASCII text, so the results differ.
The rewrite replaces them with the UTF-8 variants, which count characters.
CHAR_LENGTH is already the character length in ClickHouse. The generator
rejects the forms that have no UTF-8 variant with the same syntax
(SUBSTRING ... FROM ... FOR, POSITION ... IN).
"""

import re

FUNCTIONS = {"LENGTH": "lengthUTF8", "SUBSTRING": "substringUTF8", "SUBSTR": "substringUTF8",
             "LOWER": "lowerUTF8", "UPPER": "upperUTF8"}
CALL = re.compile(r"\b(" + "|".join(FUNCTIONS) + r")\s*\(", re.I)


def clickhouse_standard(sql):
    """Replaces the byte-wise string functions with the UTF-8 ones, outside of
    string literals."""
    parts = re.split(r"('(?:[^'\\]|\\.|'')*')", sql)
    return "".join(p if i % 2 else CALL.sub(lambda m: FUNCTIONS[m.group(1).upper()] + "(", p)
                   for i, p in enumerate(parts))


# The forms of the generated queries that have no equivalent in ClickHouse
# with the standard semantics.
UNSUPPORTED = [
    (re.compile(r"\bSUBSTR(ING)?\s*\([^()]*\bFROM\b", re.I), "SUBSTRING ... FROM (use SUBSTRING(s, start, length))"),
    (re.compile(r"\bPOSITION\s*\(", re.I), "POSITION (byte offsets in ClickHouse)"),
    (re.compile(r"\b(OCTET_LENGTH|BIT_LENGTH|LEFT|RIGHT|REVERSE)\s*\(", re.I), "a byte-wise string function"),
]


def unsupported(sql):
    for pattern, reason in UNSUPPORTED:
        if pattern.search(sql):
            return reason
    return None
