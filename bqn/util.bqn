# Shared helpers for the BQN ClickBench entry.
#
# Per-column files live under ./cols/, produced by prep.py.
# Numeric columns are raw little-endian f64; string columns come as a
# pair (<col>.str = concatenated UTF-8 bytes, <col>.off = f64-encoded
# byte offsets, length(values)+1 entries).

⟨LoadF, LoadS, NumRows, Pair, TopN, LexMin, ContainsOne, ContainsAny, _groupBy⟩ ⇐

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
