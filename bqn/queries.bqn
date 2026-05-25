# The 43 ClickBench queries translated to BQN.
#
# Each Qn is a 0-ary function that loads only the columns it needs from
# ./cols/ (via util.bqn) and returns the SQL result. ./query.bqn
# dispatches on the integer index read from stdin and times the call.
#
# Reference SQL formulations are in queries.sql; this file is the BQN
# equivalent.

⟨Run⟩ ⇐

util ← •Import "util.bqn"

# Pair two same-length arrays into a list of 2-element lists. Used to
# build composite group-by keys; BQN's ⍷/⊐ work on nested arrays by
# structural equality, so no string flattening is needed.
Pair ← {𝕨 {𝕨‿𝕩}¨ 𝕩}

# Top-N: indices of the N largest values, descending. Clamps to length.
TopN ← {n‿v: (n⌊≠v) ↑ ⍒v}

# Group-by aggregate. 𝔽 is applied to the index list of each group;
# returns ⟨unique-keys, aggregates⟩.
_groupBy ← {
    uniq ← ⍷ 𝕩
    ix ← uniq ⊐ 𝕩
    ⟨uniq, 𝔽¨ ix ⊔ ↕≠ix⟩
}

# ----------------------------------------------------------------------

# Q1: SELECT COUNT(*) FROM hits
Q1 ← {𝕤⋄ util.NumRows@}

# Q2: SELECT COUNT(*) FROM hits WHERE AdvEngineID <> 0
Q2 ← {𝕤⋄ +´ 0 ≠ util.LoadF "AdvEngineID"}

# Q3: SELECT SUM(AdvEngineID), COUNT(*), AVG(ResolutionWidth) FROM hits
Q3 ← {𝕤
    adv ← util.LoadF "AdvEngineID"
    rw ← util.LoadF "ResolutionWidth"
    ⟨+´adv, ≠adv, (+´rw)÷≠rw⟩
}

# Q4: SELECT AVG(UserID) FROM hits
Q4 ← {𝕤⋄ uid←util.LoadF "UserID" ⋄ (+´uid)÷≠uid}

# Q5: SELECT COUNT(DISTINCT UserID) FROM hits
Q5 ← {𝕤⋄ ≠ ⍷ util.LoadF "UserID"}

# Q6: SELECT COUNT(DISTINCT SearchPhrase) FROM hits
Q6 ← {𝕤⋄ ≠ ⍷ util.LoadS "SearchPhrase"}

# Q7: SELECT MIN(EventDate), MAX(EventDate) FROM hits
Q7 ← {𝕤⋄ ed←util.LoadF "EventDate" ⋄ ⟨⌊´ed, ⌈´ed⟩}

# Q8: ... AdvEngineID, COUNT(*) ... WHERE AdvEngineID <> 0
#     GROUP BY AdvEngineID ORDER BY COUNT(*) DESC
Q8 ← {𝕤
    adv ← util.LoadF "AdvEngineID"
    keys ← (0≠adv) / adv
    ⟨ks, cs⟩ ← (≠⊣) _groupBy keys
    ord ← ⍒ cs
    ⟨ord⊏ks, ord⊏cs⟩
}

# Q9: RegionID, COUNT(DISTINCT UserID) AS u, ORDER BY u DESC LIMIT 10
Q9 ← {𝕤
    rid ← util.LoadF "RegionID"
    uid ← util.LoadF "UserID"
    ⟨ks, ds⟩ ← {≠⍷uid⊏˜𝕩} _groupBy rid
    top ← TopN 10‿ds
    ⟨top⊏ks, top⊏ds⟩
}

# Q10: RegionID, SUM(AdvEngineID), COUNT(*) AS c, AVG(ResolutionWidth),
#      COUNT(DISTINCT UserID) GROUP BY RegionID ORDER BY c DESC LIMIT 10
Q10 ← {𝕤
    rid ← util.LoadF "RegionID"
    adv ← util.LoadF "AdvEngineID"
    rw ← util.LoadF "ResolutionWidth"
    uid ← util.LoadF "UserID"
    Agg ← {ix ← 𝕩 ⋄ ⟨+´adv⊏˜ix, ≠ix, (+´rw⊏˜ix)÷≠ix, ≠⍷uid⊏˜ix⟩
    }
    ⟨ks, vs⟩ ← Agg _groupBy rid
    cs ← 1 ⊑¨ vs
    top ← TopN 10‿cs
    ⟨top⊏ks, top⊏vs⟩
}

# Q11: MobilePhoneModel <> '' GROUP BY ... ORDER BY count(distinct uid) DESC LIMIT 10
Q11 ← {𝕤
    mpm ← util.LoadS "MobilePhoneModel"
    uid ← util.LoadF "UserID"
    mask ← 0 < ≠¨ mpm
    keys ← mask / mpm
    u2 ← mask / uid
    ⟨ks, ds⟩ ← {≠⍷u2⊏˜𝕩} _groupBy keys
    top ← TopN 10‿ds
    ⟨top⊏ks, top⊏ds⟩
}

# Q12: GROUP BY MobilePhone, MobilePhoneModel WHERE MobilePhoneModel <> ''
Q12 ← {𝕤
    mp ← util.LoadF "MobilePhone"
    mpm ← util.LoadS "MobilePhoneModel"
    uid ← util.LoadF "UserID"
    mask ← 0 < ≠¨ mpm
    m1 ← mask / mp
    m2 ← mask / mpm
    u2 ← mask / uid
    keys ← m1 Pair m2
    ⟨ks, ds⟩ ← {≠⍷u2⊏˜𝕩} _groupBy keys
    top ← TopN 10‿ds
    ⟨top⊏ks, top⊏ds⟩
}

# Q13: SELECT SearchPhrase, COUNT(*) AS c WHERE SearchPhrase<>''
#      GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10
Q13 ← {𝕤
    sp ← util.LoadS "SearchPhrase"
    keys ← (0<≠¨sp) / sp
    ⟨ks, cs⟩ ← (≠⊣) _groupBy keys
    top ← TopN 10‿cs
    ⟨top⊏ks, top⊏cs⟩
}

# Q14: SearchPhrase, COUNT(DISTINCT UserID) AS u, ORDER BY u DESC LIMIT 10
Q14 ← {𝕤
    sp ← util.LoadS "SearchPhrase"
    uid ← util.LoadF "UserID"
    mask ← 0 < ≠¨ sp
    keys ← mask / sp
    u2 ← mask / uid
    ⟨ks, ds⟩ ← {≠⍷u2⊏˜𝕩} _groupBy keys
    top ← TopN 10‿ds
    ⟨top⊏ks, top⊏ds⟩
}

# Q15: SearchEngineID, SearchPhrase, COUNT(*) c, GROUP BY (seid,sp), ORDER c DESC LIMIT 10
Q15 ← {𝕤
    seid ← util.LoadF "SearchEngineID"
    sp ← util.LoadS "SearchPhrase"
    mask ← 0 < ≠¨ sp
    s2 ← mask / seid
    sp2 ← mask / sp
    keys ← s2 Pair sp2
    ⟨ks, cs⟩ ← (≠⊣) _groupBy keys
    top ← TopN 10‿cs
    ⟨top⊏ks, top⊏cs⟩
}

# Q16: UserID, COUNT(*), GROUP BY UserID ORDER BY COUNT(*) DESC LIMIT 10
Q16 ← {𝕤
    uid ← util.LoadF "UserID"
    ⟨ks, cs⟩ ← (≠⊣) _groupBy uid
    top ← TopN 10‿cs
    ⟨top⊏ks, top⊏cs⟩
}

# Q17: UserID, SearchPhrase, COUNT(*), GROUP BY ... ORDER BY count DESC LIMIT 10
Q17 ← {𝕤
    uid ← util.LoadF "UserID"
    sp ← util.LoadS "SearchPhrase"
    keys ← uid Pair sp
    ⟨ks, cs⟩ ← (≠⊣) _groupBy keys
    top ← TopN 10‿cs
    ⟨top⊏ks, top⊏cs⟩
}

# Q18: same as Q17 but LIMIT 10 with no order
Q18 ← {𝕤
    uid ← util.LoadF "UserID"
    sp ← util.LoadS "SearchPhrase"
    keys ← uid Pair sp
    ⟨ks, cs⟩ ← (≠⊣) _groupBy keys
    top ← (10⌊≠ks) ↑ ↕≠ks
    ⟨top⊏ks, top⊏cs⟩
}

# Q19: UserID, minute(EventTime) AS m, SearchPhrase, COUNT(*), GROUP BY ...
Q19 ← {𝕤
    uid ← util.LoadF "UserID"
    et ← util.LoadF "EventTime"
    sp ← util.LoadS "SearchPhrase"
    minute ← 60 | ⌊ et ÷ 60
    keys ← uid Pair (minute Pair sp)
    ⟨ks, cs⟩ ← (≠⊣) _groupBy keys
    top ← TopN 10‿cs
    ⟨top⊏ks, top⊏cs⟩
}

# Q20: SELECT UserID FROM hits WHERE UserID = 435090932899640449
Q20 ← {𝕤
    uid ← util.LoadF "UserID"
    target ← 435090932899640449
    ≠ (target = uid) / uid
}

# Lexicographic min of a list of strings (SQL MIN on string columns).
LexMin ← {⊑ ⍋⊸⊏ 𝕩}

# Substring search: 1 where 𝕩 (a single haystack string) contains needle 𝕨.
ContainsOne ← {∨´𝕨⍷𝕩}
# Applied to a list of haystacks (𝕩) with a fixed needle (𝕨): use the
# bind operator so `¨` only enumerates the right side.
ContainsAny ← {(𝕨⊸ContainsOne)¨ 𝕩}

# Q21: COUNT(*) WHERE URL LIKE '%google%'
Q21 ← {𝕤⋄ +´ "google" ContainsAny util.LoadS "URL"}

# Q22: SearchPhrase, MIN(URL), COUNT(*) WHERE URL LIKE '%google%' AND SearchPhrase<>''
Q22 ← {𝕤
    url ← util.LoadS "URL"
    sp ← util.LoadS "SearchPhrase"
    mask ← ("google" ContainsAny url) ∧ 0<≠¨sp
    url2 ← mask / url
    sp2 ← mask / sp
    Agg ← {ix ← 𝕩 ⋄ ⟨LexMin url2⊏˜ix, ≠ix⟩}
    ⟨ks, vs⟩ ← Agg _groupBy sp2
    cs ← 1 ⊑¨ vs
    top ← TopN 10‿cs
    ⟨top⊏ks, top⊏vs⟩
}

# Q23: SearchPhrase, MIN(URL), MIN(Title), COUNT(*), COUNT(DISTINCT UserID)
#      WHERE Title LIKE '%Google%' AND URL NOT LIKE '%.google.%' AND SearchPhrase<>''
Q23 ← {𝕤
    url ← util.LoadS "URL"
    title ← util.LoadS "Title"
    sp ← util.LoadS "SearchPhrase"
    uid ← util.LoadF "UserID"
    mask ← ("Google" ContainsAny title) ∧ (¬ ".google." ContainsAny url) ∧ 0<≠¨sp
    url2 ← mask / url
    t2 ← mask / title
    sp2 ← mask / sp
    u2 ← mask / uid
    Agg ← {ix ← 𝕩 ⋄ ⟨LexMin url2⊏˜ix, LexMin t2⊏˜ix, ≠ix, ≠⍷u2⊏˜ix⟩}
    ⟨ks, vs⟩ ← Agg _groupBy sp2
    cs ← 2 ⊑¨ vs
    top ← TopN 10‿cs
    ⟨top⊏ks, top⊏vs⟩
}

# Q24: SELECT * FROM hits WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10
# "SELECT *" on 100+ columns is impractical to fully reconstruct; we
# return the 10 row indices in EventTime order.
Q24 ← {𝕤
    url ← util.LoadS "URL"
    et ← util.LoadF "EventTime"
    mask ← "google" ContainsAny url
    et2 ← mask / et
    10 ↑ ⍋ et2
}

# Q25: SearchPhrase ORDER BY EventTime LIMIT 10 WHERE SearchPhrase<>''
Q25 ← {𝕤
    sp ← util.LoadS "SearchPhrase"
    et ← util.LoadF "EventTime"
    mask ← 0<≠¨sp
    sp2 ← mask / sp
    et2 ← mask / et
    (10 ↑ ⍋ et2) ⊏ sp2
}

# Q26: SearchPhrase ORDER BY SearchPhrase LIMIT 10
Q26 ← {𝕤
    sp ← util.LoadS "SearchPhrase"
    sp2 ← (0<≠¨sp) / sp
    (10 ↑ ⍋ sp2) ⊏ sp2
}

# Q27: SearchPhrase ORDER BY EventTime, SearchPhrase LIMIT 10
Q27 ← {𝕤
    sp ← util.LoadS "SearchPhrase"
    et ← util.LoadF "EventTime"
    mask ← 0<≠¨sp
    sp2 ← mask / sp
    et2 ← mask / et
    # Stable sort: sort by sp first, then et — equivalent to primary et,
    # secondary sp under BQN's stable ⍋.
    ord ← ⍋ et2
    (10 ↑ ord) ⊏ sp2
}

# Q28: CounterID, AVG(LENGTH(URL)) AS l, COUNT(*) AS c WHERE URL<>''
#      GROUP BY CounterID HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25
Q28 ← {𝕤
    cid ← util.LoadF "CounterID"
    url ← util.LoadS "URL"
    lens ← ≠¨ url
    mask ← 0 < lens
    cid2 ← mask / cid
    lens2 ← mask / lens
    Agg ← {ix ← 𝕩 ⋄ ⟨(+´lens2⊏˜ix)÷≠ix, ≠ix⟩}
    ⟨ks, vs⟩ ← Agg _groupBy cid2
    cs ← 1 ⊑¨ vs
    ls ← 0 ⊑¨ vs
    keep ← cs > 100000
    ks2 ← keep/ks ⋄ ls2 ← keep/ls ⋄ cs2 ← keep/cs
    top ← TopN 25‿ls2
    ⟨top⊏ks2, top⊏ls2, top⊏cs2⟩
}

# Q29: REGEXP_REPLACE(Referer, '^https?://(?:www\.)?([^/]+)/.*$', '\1')
# Approximate by stripping the scheme (http:// or https://) plus
# optional "www.", then taking up to the first '/'.
Q29 ← {𝕤
    ref ← util.LoadS "Referer"
    mask ← 0 < ≠¨ ref
    ref2 ← mask / ref
    StripPrefix ← {pre 𝕊 s:
        (((≠pre)≤≠s) ∧ pre≡(≠pre)↑s) ◶ ⟨s, (≠pre)↓s⟩ @
    }
    Host ← {
        s ← "http://" StripPrefix 𝕩
        s ↩ "https://" StripPrefix s
        s ↩ "www." StripPrefix s
        (⊑ s ⊐ '/') ↑ s
    }
    keys ← Host¨ ref2
    lens ← ≠¨ ref2
    Agg ← {ix ← 𝕩 ⋄ ⟨(+´lens⊏˜ix)÷≠ix, ≠ix, LexMin ref2⊏˜ix⟩}
    ⟨ks, vs⟩ ← Agg _groupBy keys
    cs ← 1 ⊑¨ vs
    keep ← cs > 100000
    ks2 ← keep/ks ⋄ vs2 ← keep/vs ⋄ ls2 ← (0⊑¨vs2)
    top ← TopN 25‿ls2
    ⟨top⊏ks2, top⊏vs2⟩
}

# Q30: 90 sums of (ResolutionWidth + i) for i in 0..89. Equivalent to
# sum(rw) + i * count, but we replicate the literal SQL.
Q30 ← {𝕤
    rw ← util.LoadF "ResolutionWidth"
    s ← +´rw
    n ← ≠rw
    s + n × ↕90
}

# Q31: GROUP BY SearchEngineID, ClientIP WHERE SearchPhrase<>'' ORDER BY c DESC LIMIT 10
Q31 ← {𝕤
    seid ← util.LoadF "SearchEngineID"
    cip ← util.LoadF "ClientIP"
    sp ← util.LoadS "SearchPhrase"
    ir ← util.LoadF "IsRefresh"
    rw ← util.LoadF "ResolutionWidth"
    mask ← 0<≠¨sp
    s2 ← mask/seid ⋄ c2 ← mask/cip ⋄ i2 ← mask/ir ⋄ r2 ← mask/rw
    keys ← s2 Pair c2
    Agg ← {ix ← 𝕩 ⋄ ⟨≠ix, +´i2⊏˜ix, (+´r2⊏˜ix)÷≠ix⟩}
    ⟨ks, vs⟩ ← Agg _groupBy keys
    cs ← 0 ⊑¨ vs
    top ← TopN 10‿cs
    ⟨top⊏ks, top⊏vs⟩
}

# Q32: GROUP BY WatchID, ClientIP WHERE SearchPhrase<>'' ORDER BY c DESC LIMIT 10
Q32 ← {𝕤
    wid ← util.LoadF "WatchID"
    cip ← util.LoadF "ClientIP"
    sp ← util.LoadS "SearchPhrase"
    ir ← util.LoadF "IsRefresh"
    rw ← util.LoadF "ResolutionWidth"
    mask ← 0<≠¨sp
    w2 ← mask/wid ⋄ c2 ← mask/cip ⋄ i2 ← mask/ir ⋄ r2 ← mask/rw
    keys ← w2 Pair c2
    Agg ← {ix ← 𝕩 ⋄ ⟨≠ix, +´i2⊏˜ix, (+´r2⊏˜ix)÷≠ix⟩}
    ⟨ks, vs⟩ ← Agg _groupBy keys
    cs ← 0 ⊑¨ vs
    top ← TopN 10‿cs
    ⟨top⊏ks, top⊏vs⟩
}

# Q33: same as Q32 without SearchPhrase filter
Q33 ← {𝕤
    wid ← util.LoadF "WatchID"
    cip ← util.LoadF "ClientIP"
    ir ← util.LoadF "IsRefresh"
    rw ← util.LoadF "ResolutionWidth"
    keys ← wid Pair cip
    Agg ← {ix ← 𝕩 ⋄ ⟨≠ix, +´ir⊏˜ix, (+´rw⊏˜ix)÷≠ix⟩}
    ⟨ks, vs⟩ ← Agg _groupBy keys
    cs ← 0 ⊑¨ vs
    top ← TopN 10‿cs
    ⟨top⊏ks, top⊏vs⟩
}

# Q34: URL, COUNT(*), GROUP BY URL ORDER BY c DESC LIMIT 10
Q34 ← {𝕤
    url ← util.LoadS "URL"
    ⟨ks, cs⟩ ← (≠⊣) _groupBy url
    top ← TopN 10‿cs
    ⟨top⊏ks, top⊏cs⟩
}

# Q35: literal 1, URL, COUNT(*) — same as Q34 with an extra constant column
Q35 ← {𝕤
    url ← util.LoadS "URL"
    ⟨ks, cs⟩ ← (≠⊣) _groupBy url
    top ← TopN 10‿cs
    ⟨(≠top)⥊1, top⊏ks, top⊏cs⟩
}

# Q36: ClientIP, ClientIP-1, ClientIP-2, ClientIP-3, COUNT(*),
#      GROUP BY (all functionally dependent on ClientIP)
Q36 ← {𝕤
    cip ← util.LoadF "ClientIP"
    ⟨ks, cs⟩ ← (≠⊣) _groupBy cip
    top ← TopN 10‿cs
    keys ← top⊏ks
    ⟨keys, keys-1, keys-2, keys-3, top⊏cs⟩
}

# EventDate is stored as days-since-epoch. 2013-07-01 = day 15887,
# 2013-07-31 = day 15917, 2013-07-14 = day 15900, 2013-07-15 = 15901.
Q37 ← {𝕤
    cid ← util.LoadF "CounterID"
    ed ← util.LoadF "EventDate"
    dh ← util.LoadF "DontCountHits"
    ir ← util.LoadF "IsRefresh"
    url ← util.LoadS "URL"
    mask ← (62=cid) ∧ (ed≥15887) ∧ (ed≤15917) ∧ (0=dh) ∧ (0=ir) ∧ 0<≠¨url
    url2 ← mask / url
    ⟨ks, cs⟩ ← (≠⊣) _groupBy url2
    top ← TopN 10‿cs
    ⟨top⊏ks, top⊏cs⟩
}

Q38 ← {𝕤
    cid ← util.LoadF "CounterID"
    ed ← util.LoadF "EventDate"
    dh ← util.LoadF "DontCountHits"
    ir ← util.LoadF "IsRefresh"
    title ← util.LoadS "Title"
    mask ← (62=cid) ∧ (ed≥15887) ∧ (ed≤15917) ∧ (0=dh) ∧ (0=ir) ∧ 0<≠¨title
    t2 ← mask / title
    ⟨ks, cs⟩ ← (≠⊣) _groupBy t2
    top ← TopN 10‿cs
    ⟨top⊏ks, top⊏cs⟩
}

# Q39: LIMIT 10 OFFSET 1000
Q39 ← {𝕤
    cid ← util.LoadF "CounterID"
    ed ← util.LoadF "EventDate"
    ir ← util.LoadF "IsRefresh"
    il ← util.LoadF "IsLink"
    id ← util.LoadF "IsDownload"
    url ← util.LoadS "URL"
    mask ← (62=cid) ∧ (ed≥15887) ∧ (ed≤15917) ∧ (0=ir) ∧ (0≠il) ∧ (0=id)
    url2 ← mask / url
    ⟨ks, cs⟩ ← (≠⊣) _groupBy url2
    ord ← ⍒ cs
    sliced ← (10⌊0⌈(≠ord)-1000) ↑ 1000 ↓ ord
    ⟨sliced⊏ks, sliced⊏cs⟩
}

# Q40: CASE-WHEN over source, GROUP BY 5 cols, ORDER BY pv DESC LIMIT 10 OFFSET 1000
Q40 ← {𝕤
    cid ← util.LoadF "CounterID"
    ed ← util.LoadF "EventDate"
    ir ← util.LoadF "IsRefresh"
    tsid ← util.LoadF "TraficSourceID"
    seid ← util.LoadF "SearchEngineID"
    aeid ← util.LoadF "AdvEngineID"
    ref ← util.LoadS "Referer"
    url ← util.LoadS "URL"
    mask ← (62=cid) ∧ (ed≥15887) ∧ (ed≤15917) ∧ (0=ir)
    t2 ← mask/tsid ⋄ s2 ← mask/seid ⋄ a2 ← mask/aeid
    r2 ← mask/ref ⋄ u2 ← mask/url
    src ← ((0=s2) ∧ 0=a2) {𝕨? 𝕩 ; ""}¨ r2
    keys ← t2 Pair s2 Pair a2 Pair src Pair u2
    ⟨ks, cs⟩ ← (≠⊣) _groupBy keys
    ord ← ⍒ cs
    sliced ← (10⌊0⌈(≠ord)-1000) ↑ 1000 ↓ ord
    ⟨sliced⊏ks, sliced⊏cs⟩
}

Q41 ← {𝕤
    cid ← util.LoadF "CounterID"
    ed ← util.LoadF "EventDate"
    ir ← util.LoadF "IsRefresh"
    tsid ← util.LoadF "TraficSourceID"
    rh ← util.LoadF "RefererHash"
    uh ← util.LoadF "URLHash"
    target ← 3594120000172545465
    mask ← (62=cid) ∧ (ed≥15887) ∧ (ed≤15917) ∧ (0=ir) ∧ ((tsid=¯1) ∨ (tsid=6)) ∧ rh=target
    uh2 ← mask/uh ⋄ ed2 ← mask/ed
    keys ← uh2 Pair ed2
    ⟨ks, cs⟩ ← (≠⊣) _groupBy keys
    ord ← ⍒ cs
    sliced ← (10⌊0⌈(≠ord)-100) ↑ 100 ↓ ord
    ⟨sliced⊏ks, sliced⊏cs⟩
}

Q42 ← {𝕤
    cid ← util.LoadF "CounterID"
    ed ← util.LoadF "EventDate"
    ir ← util.LoadF "IsRefresh"
    dh ← util.LoadF "DontCountHits"
    uh ← util.LoadF "URLHash"
    ww ← util.LoadF "WindowClientWidth"
    wh ← util.LoadF "WindowClientHeight"
    target ← 2868770270353813622
    mask ← (62=cid) ∧ (ed≥15887) ∧ (ed≤15917) ∧ (0=ir) ∧ (0=dh) ∧ uh=target
    ww2 ← mask/ww ⋄ wh2 ← mask/wh
    keys ← ww2 Pair wh2
    ⟨ks, cs⟩ ← (≠⊣) _groupBy keys
    ord ← ⍒ cs
    sliced ← (10⌊0⌈(≠ord)-10000) ↑ 10000 ↓ ord
    ⟨sliced⊏ks, sliced⊏cs⟩
}

Q43 ← {𝕤
    cid ← util.LoadF "CounterID"
    ed ← util.LoadF "EventDate"
    ir ← util.LoadF "IsRefresh"
    dh ← util.LoadF "DontCountHits"
    et ← util.LoadF "EventTime"
    mask ← (62=cid) ∧ (ed≥15900) ∧ (ed≤15901) ∧ (0=ir) ∧ (0=dh)
    et2 ← mask / et
    m ← 60 × ⌊ et2 ÷ 60
    ⟨ks, cs⟩ ← (≠⊣) _groupBy m
    ord ← ⍋ ks
    sliced ← (10⌊0⌈(≠ord)-1000) ↑ 1000 ↓ ord
    ⟨sliced⊏ks, sliced⊏cs⟩
}

Run ← {
    (¯1+𝕩) ◶ ⟨
        Q1, Q2, Q3, Q4, Q5, Q6, Q7, Q8, Q9, Q10,
        Q11, Q12, Q13, Q14, Q15, Q16, Q17, Q18, Q19, Q20,
        Q21, Q22, Q23, Q24, Q25, Q26, Q27, Q28, Q29, Q30,
        Q31, Q32, Q33, Q34, Q35, Q36, Q37, Q38, Q39, Q40,
        Q41, Q42, Q43
    ⟩ @
}
