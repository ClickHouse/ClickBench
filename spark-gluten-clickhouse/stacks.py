#!/usr/bin/env python3

"""
Reads a `jcmd <pid> Thread.print` or `gdb -batch -ex 'thread apply all bt'`
dump on stdin and prints each distinct stack once, with the number of threads
that have it, most frequent first. A JVM with libch.so has hundreds of
threads, most of them identical idle pool workers, so the raw dump is too long
for the benchmark log. Used by ./query when a query hangs.
"""

import collections
import re
import sys

DEPTH = 16

stacks = collections.Counter()
current = None


def flush():
    global current
    if current:
        stacks["\n".join(current[:DEPTH])] += 1
    current = None


for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith('"') or line.startswith("Thread "):
        # A new thread: `"name" #12 ...` (jcmd) or `Thread 7 (...):` (gdb).
        flush()
        current = []
    elif current is not None:
        m = re.match(r"\s+java\.lang\.Thread\.State: (.*)", line)
        if m:
            current.append("state: " + m.group(1))
            continue
        m = re.match(r"\s+at (.*)", line)
        if m:
            current.append(m.group(1))
            continue
        m = re.match(r"#\d+\s+(?:0x[0-9a-f]+ in )?(\S+)", line)
        if m:
            current.append(m.group(1))
flush()

for stack, count in stacks.most_common():
    print(f"--- {count} thread(s):")
    print(stack)
