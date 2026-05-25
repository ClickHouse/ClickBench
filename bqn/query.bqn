# Per-query runner. The benchmark driver pipes one line of the queries
# file (containing the integer query number) into stdin. We dispatch to
# the matching function in queries.bqn, time it, print the result to
# stdout, and write the runtime in fractional seconds to the last line
# of stderr — the contract expected by lib/benchmark-common.sh.

queries ← •Import "queries.bqn"

# Read query index from stdin.
line ← •GetLine 0
qn ← •ParseFloat line

t0 ← •MonoTime @
result ← queries.Run qn
t1 ← •MonoTime @

# Result to stdout (the driver reads it for sanity but ignores content).
•Show result

# Timing to stderr, fractional seconds. •term.ErrRaw writes a string to
# stderr without adding a newline, so we append one ourselves.
•term.ErrRaw (•Repr t1-t0) ∾ @+10
