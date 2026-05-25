# Shared helpers for the BQN ClickBench entry.
#
# Per-column files live under ./cols/, produced by prep.py.
# Numeric columns are raw little-endian f64; string columns come as a
# pair (<col>.str = concatenated UTF-8 bytes, <col>.off = int64
# little-endian offsets, length(values)+1 entries).

⟨LoadF, LoadS, NumRows⟩ ⇐

# Read a numeric column as a flat f64 vector.
LoadF ← {
    raw ← •FBytes "cols/"∾𝕩∾".f64"
    8‿64 •bit._cast -⟜@ raw
}

# Read a string column as a list of strings.
LoadS ← {
    raw ← •FBytes "cols/"∾𝕩∾".str"
    offs ← 8‿64 •bit._cast -⟜@ •FBytes "cols/"∾𝕩∾".off"
    starts ← ¯1↓offs
    ends ← 1↓offs
    starts {(𝕩-𝕨)↑𝕨↓raw}¨ ends
}

# Row count of the hits dataset (always the full ClickBench size).
NumRows ← {𝕤⋄99997497}
