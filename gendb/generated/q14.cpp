// Q14: SELECT SearchPhrase, COUNT(DISTINCT UserID) AS u FROM hits
//      WHERE SearchPhrase <> '' GROUP BY SearchPhrase
//      ORDER BY u DESC LIMIT 10;
//
// Strategy (same as q11, but on SearchPhrase):
//   1. Per-thread string-keyed hashmap (see q13) from SearchPhrase
//      bytes -> I64Set of UserIDs seen for that key (see q5).
//   2. Skip rows where the search phrase is empty.
//   3. Merge per-thread maps by union-ing the per-key sets serially.
//   4. TopK over the merged map by set.live (= number of distinct users).
//
// SearchPhrase has much higher cardinality than MobilePhoneModel
// (hundreds of thousands of distinct values vs. a few hundred), so we
// bump StrMap::INIT_CAP accordingly. Each per-key I64Set still starts
// tiny (cap = 16) and grows on demand to keep memory bounded for the
// long tail of rare phrases.

#include "../utils/storage.h"
#include "../utils/timing.h"
#include "../utils/hashmap.h"
#include "../utils/topn.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <omp.h>
#include <string>
#include <vector>

// Open-addressing hashset on int64. Sentinel: INT64_MIN. UserIDs in this
// dataset are positive so the sentinel is safe; we still remap INT64_MIN
// to INT64_MIN+1 defensively (same as q5).
struct I64Set {
    std::vector<int64_t> slots;
    size_t mask;
    size_t live = 0;
    static constexpr int64_t EMPTY = INT64_MIN;

    I64Set() : slots(16, EMPTY), mask(15) {}

    inline void insert(int64_t v) {
        if (v == EMPTY) v = EMPTY + 1;
        size_t pos = gendb::mix64((uint64_t)v) & mask;
        while (true) {
            int64_t s = slots[pos];
            if (s == EMPTY) {
                slots[pos] = v;
                ++live;
                if (live * 2 > slots.size()) grow();
                return;
            }
            if (s == v) return;
            pos = (pos + 1) & mask;
        }
    }

    void grow() {
        std::vector<int64_t> old = std::move(slots);
        size_t newcap = old.size() * 2;
        slots.assign(newcap, EMPTY);
        mask = newcap - 1;
        for (int64_t v : old) {
            if (v != EMPTY) {
                size_t pos = gendb::mix64((uint64_t)v) & mask;
                while (slots[pos] != EMPTY) pos = (pos + 1) & mask;
                slots[pos] = v;
            }
        }
    }
};

struct StrEntry {
    uint64_t hash;
    uint32_t off_lo;
    uint32_t off_hi;
    uint32_t len;
    I64Set   users;
};

static inline uint64_t hash_bytes(const char* p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; ++i) {
        h ^= (uint8_t)p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

struct StrMap {
    // SearchPhrase cardinality is much higher than MobilePhoneModel; start big
    // so we don't pay many rehashes during the hot per-thread scan.
    static constexpr size_t INIT_CAP = 1 << 17;
    std::vector<int32_t> slots;
    std::vector<StrEntry> entries;
    size_t mask;
    size_t live = 0;

    StrMap() : slots(INIT_CAP, -1), entries(), mask(INIT_CAP - 1) { entries.reserve(1 << 14); }

    void maybe_grow() {
        if (live * 2 <= slots.size()) return;
        size_t newcap = slots.size() * 2;
        std::vector<int32_t> ns(newcap, -1);
        size_t nm = newcap - 1;
        for (size_t i = 0; i < entries.size(); ++i) {
            uint64_t h = entries[i].hash;
            size_t pos = h & nm;
            while (ns[pos] != -1) pos = (pos + 1) & nm;
            ns[pos] = (int32_t)i;
        }
        slots = std::move(ns);
        mask = nm;
    }

    // Returns pointer to the I64Set for this key. The pointer is stable for
    // the duration of the call chain that doesn't trigger maybe_grow afterward;
    // we return after maybe_grow so the entries vector won't move under us.
    I64Set* find_or_insert(uint64_t h, const char* p, size_t n, const char* data_base, uint64_t row_off) {
        size_t pos = h & mask;
        while (true) {
            int32_t idx = slots[pos];
            if (idx == -1) {
                StrEntry e;
                e.hash = h;
                e.off_lo = (uint32_t)(row_off & 0xffffffffu);
                e.off_hi = (uint32_t)(row_off >> 32);
                e.len = (uint32_t)n;
                entries.push_back(std::move(e));
                slots[pos] = (int32_t)(entries.size() - 1);
                ++live;
                size_t my_idx = entries.size() - 1;
                maybe_grow();
                return &entries[my_idx].users;
            }
            auto& e = entries[idx];
            if (e.hash == h && e.len == n) {
                uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
                if (memcmp(data_base + off, p, n) == 0) return &e.users;
            }
            pos = (pos + 1) & mask;
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q14 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    auto sp = gendb::mmap_strcol(dir, "SearchPhrase");
    const int64_t* uid = gendb::mmap_col<int64_t>(dir, "UserID");

    int T = omp_get_max_threads();
    std::vector<StrMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        StrMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < sp.n; ++i) {
            uint64_t a = sp.off[i], b = sp.off[i + 1];
            if (a == b) continue;  // empty SearchPhrase
            const char* p = sp.data + a;
            size_t n = (size_t)(b - a);
            uint64_t h = hash_bytes(p, n);
            I64Set* s = m.find_or_insert(h, p, n, sp.data, a);
            s->insert(uid[i]);
        }
    }

    // Merge per-thread maps into a single map by union-ing sets per key.
    StrMap merged;
    for (auto& m : maps) {
        for (auto& e : m.entries) {
            uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
            I64Set* tgt = merged.find_or_insert(e.hash, sp.data + off, e.len, sp.data, off);
            for (int64_t v : e.users.slots) {
                if (v != I64Set::EMPTY) tgt->insert(v);
            }
        }
    }

    // TopK by distinct-user count.
    using Row = std::pair<int64_t, int>;  // (count_distinct, index into merged.entries)
    gendb::TopK<Row> top(10);
    for (size_t i = 0; i < merged.entries.size(); ++i) {
        top.try_push({(int64_t)merged.entries[i].users.live, (int)i});
    }
    auto rows = top.sorted_desc();

    std::printf("SearchPhrase,u\n");
    for (auto& r : rows) {
        auto& e = merged.entries[r.second];
        uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
        std::fwrite(sp.data + off, 1, e.len, stdout);
        std::printf(",%lld\n", (long long)r.first);
    }
    return 0;
}
