# Shared helpers for the BQN ClickBench entry.
#
# Per-column files live under ./cols/, produced by prep.py.
# Numeric columns are raw little-endian f64; string columns come as a
# pair (<col>.str = concatenated UTF-8 bytes, <col>.off = little-endian
# int64 byte offsets, length(values)+1 entries).

⟨LoadF, LoadS, NumRows, Pair, TopN, LexMin, ContainsOne, ContainsAny, _groupBy⟩ ⇐

# Read a numeric column as a flat f64 vector.
LoadF ← {
    raw ← •FBytes "cols/"∾𝕩∾".f64"
    8‿64 •bit._cast -⟜@ raw
}

# Reconstruct an i64 little-endian array from a raw byte stream by
# byte-by-byte arithmetic. We can't use `•bit._cast` for the offsets
# file: on at least one x86_64 build of CBQN it returns a fractional
# f64 (`79.96875` instead of `80`) for a multi-hundred-MB input, even
# though writing the bytes back to disk shows them intact. Doing the
# i64 reconstruction manually with `+˝˘` and powers of 256 is slower
# (~1 GB/s scan vs free memcpy) but bit-pattern-independent.
#
# Offsets here fit in 2^53 (the entire hits dataset's biggest string
# column is < 16 GB), so a plain f64 number is exact.
BytesToI64 ← {
    n ← (≠𝕩) ÷ 8
    matrix ← (n ‿ 8) ⥊ -⟜@ 𝕩
    powers4 ← 256 ⋆ ↕ 4
    Dot ← {+˝ 𝕨 × 𝕩}
    lo ← (powers4⊸Dot)˘ 4↑˘matrix
    hi ← (powers4⊸Dot)˘ 4↓˘matrix
    lo + hi × 4294967296
}

# Read a string column as a list of strings.
LoadS ← {
    raw ← •FBytes "cols/"∾𝕩∾".str"
    offs ← BytesToI64 •FBytes "cols/"∾𝕩∾".off"
    starts ← ¯1↓offs
    ends ← 1↓offs
    starts {(𝕩-𝕨)↑𝕨↓raw}¨ ends
}

# Row count of the hits dataset.
NumRows ← {𝕤⋄99997497}

# Pair two same-length arrays into a list of 2-element lists. Used to
# build composite group-by keys; BQN's ⍷/⊐ work on nested arrays by
# structural equality, so no string flattening is required.
Pair ← {𝕨 {𝕨‿𝕩}¨ 𝕩}

# Top-N: indices of the N largest values, descending. Clamps to length.
TopN ← {n‿v: (n⌊≠v) ↑ ⍒v}

# Lexicographic min of a list of strings (SQL MIN on string columns).
LexMin ← {⊑ ⍋⊸⊏ 𝕩}

# Substring search: 1 if 𝕩 (a single haystack string) contains needle 𝕨.
ContainsOne ← {∨´ 𝕨 ⍷ 𝕩}
# Fixed needle 𝕨, list-of-haystacks 𝕩 → list of 0/1.
ContainsAny ← {(𝕨⊸ContainsOne)¨ 𝕩}

# Group-by aggregate. 𝔽 is applied to the index list of each group;
# returns ⟨unique-keys, aggregates⟩.
_groupBy ← {
    uniq ← ⍷ 𝕩
    ix ← uniq ⊐ 𝕩
    ⟨uniq, 𝔽¨ ix ⊔ ↕≠ix⟩
}
