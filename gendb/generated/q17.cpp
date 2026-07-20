// Q17: SELECT UserID, SearchPhrase, COUNT(*)
//      FROM hits
//      GROUP BY UserID, SearchPhrase
//      ORDER BY COUNT(*) DESC LIMIT 10;
//
// Composite key (int64 UserID, string SearchPhrase). Every row goes in —
// no empty-string filter.
//
// Inner-loop strategy (composite of q12's mix64-xor-fnv1a key and q13's
// string-keyed COUNT table):
//   1. For each row, compute sh = fnv1a(SearchPhrase bytes) and
//      h = mix64(UserID) ^ sh. We use this composite h as the probe key.
//   2. Open-addressing hashmap entry stores
//      (hash, str_hash, off, len, uid, count). On collision we verify
//      hash == h && uid match && len match && memcmp on the byte range.
//   3. Per-thread maps; serial merge — the merge re-uses the cached
//      `str_hash` so we don't rehash bytes during merging.
//   4. TopK 10 by count.

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

struct Entry {
    uint64_t hash;     // composite hash: mix64(uid) ^ fnv1a(phrase_bytes)
    uint64_t str_hash; // fnv1a(phrase_bytes) alone — preserved for merge
    uint32_t off_lo;
    uint32_t off_hi;
    uint32_t len;
    int64_t  uid;
    int64_t  count;
};

// FNV-1a on the phrase byte range — same as q12/q13. Empty string maps to
// the FNV offset basis, which is fine: every row with empty SearchPhrase
// and the same UserID will land on the same composite hash and group.
static inline uint64_t hash_bytes(const char* p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; ++i) {
        h ^= (uint8_t)p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

struct StrMap {
    static constexpr size_t INIT_CAP = 1 << 14;
    std::vector<int32_t> slots;  // -1 = empty, else index into entries
    std::vector<Entry>   entries;
    size_t mask;
    size_t live = 0;

    StrMap() : slots(INIT_CAP, -1), mask(INIT_CAP - 1) { entries.reserve(2048); }

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

    // Locate (or create) the entry for (uid, phrase_bytes) keyed by the
    // pre-computed composite hash `h`. `str_hash` is stashed inside the
    // entry so the merge step can rebuild a fresh map without rehashing.
    Entry* find_or_insert(uint64_t h, uint64_t str_hash,
                          int64_t uid,
                          const char* p, size_t n,
                          const char* data_base, uint64_t row_off) {
        size_t pos = h & mask;
        while (true) {
            int32_t idx = slots[pos];
            if (idx == -1) {
                Entry e;
                e.hash = h;
                e.str_hash = str_hash;
                e.off_lo = (uint32_t)(row_off & 0xffffffffu);
                e.off_hi = (uint32_t)(row_off >> 32);
                e.len = (uint32_t)n;
                e.uid = uid;
                e.count = 0;
                entries.push_back(std::move(e));
                slots[pos] = (int32_t)(entries.size() - 1);
                ++live;
                Entry* ret = &entries.back();
                // maybe_grow only touches `slots`; the entries vector's
                // last realloc already happened inside push_back above.
                maybe_grow();
                return ret;
            }
            Entry& e = entries[idx];
            if (e.hash == h && e.uid == uid && e.len == n) {
                uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
                if (memcmp(data_base + off, p, n) == 0) return &e;
            }
            pos = (pos + 1) & mask;
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q17 <gendb_dir>\n"); return 1; }
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
            const char* p = sp.data + a;
            size_t n = (size_t)(b - a);
            int64_t u = uid[i];
            uint64_t sh = hash_bytes(p, n);
            uint64_t h  = gendb::mix64((uint64_t)u) ^ sh;
            Entry* e = m.find_or_insert(h, sh, u, p, n, sp.data, a);
            e->count += 1;
        }
    }

    // Merge per-thread maps. Each group's count is the sum over threads.
    StrMap merged;
    for (auto& m : maps) {
        for (auto& e : m.entries) {
            uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
            Entry* tgt = merged.find_or_insert(
                e.hash, e.str_hash, e.uid,
                sp.data + off, e.len, sp.data, off);
            tgt->count += e.count;
        }
    }

    // TopK by count.
    using Row = std::pair<int64_t, int>;  // (count, index into merged.entries)
    gendb::TopK<Row> top(10);
    for (size_t i = 0; i < merged.entries.size(); ++i) {
        top.try_push({merged.entries[i].count, (int)i});
    }
    auto rows = top.sorted_desc();

    std::printf("UserID,SearchPhrase,c\n");
    for (auto& r : rows) {
        auto& e = merged.entries[r.second];
        uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
        std::printf("%lld,", (long long)e.uid);
        std::fwrite(sp.data + off, 1, e.len, stdout);
        std::printf(",%lld\n", (long long)r.first);
    }
    return 0;
}
