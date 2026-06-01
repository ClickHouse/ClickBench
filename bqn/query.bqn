# Per-query runner. Reads a BQN program from stdin, evaluates it via
# `•BQN`, prints the result on stdout, and writes the wall-clock runtime
# in fractional seconds on the last line of stderr — the contract
# expected by lib/benchmark-common.sh. Each queries.sql line is itself a
# self-contained BQN expression that imports util via `•wdpath`.

# Slurp all of stdin so a query can span multiple lines.
src ← ""
line ← •GetLine 0
{ 𝕤⋄
    src ∾↩ line ∾ @+10
    line ↩ •GetLine 0
}•_while_ {𝕤⋄ ¬ line≡@} @

t0 ← •MonoTime @
result ← •BQN src
t1 ← •MonoTime @

•Show result

•term.ErrRaw (•Repr t1-t0) ∾ @+10
