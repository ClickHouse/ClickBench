# Per-query runner. The benchmark driver pipes one line of queries.sql
# (a BQN expression that uses the `util` namespace) into stdin. We
# evaluate it via `•BQN` with a `util ← •Import "..."` prefix, time the
# call, print the result to stdout, and write the runtime in fractional
# seconds on the last line of stderr — the contract expected by
# lib/benchmark-common.sh.

utilPath ← •file.RealPath "util.bqn"
prefix ← "util ← •Import """∾utilPath∾""" ⋄ "

# Slurp all of stdin so a query can span multiple lines; the driver
# only sends one logical line plus newline but we tolerate either.
src ← ""
line ← •GetLine 0
{ 𝕊⋄
    src ∾↩ line ∾ @+10
    line ↩ •GetLine 0
}•_while_ {𝕊⋄ ¬ line≡@} @

t0 ← •MonoTime @
result ← •BQN prefix ∾ src
t1 ← •MonoTime @

•Show result

# Timing to stderr, fractional seconds.
•term.ErrRaw (•Repr t1-t0) ∾ @+10
