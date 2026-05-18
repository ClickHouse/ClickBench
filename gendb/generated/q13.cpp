// Q13: SELECT SearchPhrase, COUNT(*) AS c FROM hits
//      WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;
//
// Inner-loop strategy:
//   1. Per-row, skip empty SearchPhrase (the off[i+1]==off[i] case).
//   2. Hash the byte range; insert into open-addressing hashmap whose key
//      stores (hash, offset, len). On collision compare bytes.
//   3. The aggregation table is per-thread; we merge at the end.
//   4. Final TopK on the merged table.

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

struct StrEntry {
    uint64_t hash;
    uint32_t off_lo;  // low 32 bits of offset
    uint32_t off_hi;
    uint32_t len;
    int64_t  count;
};

// FNV-1a-style cheap hash for short strings (search phrases are usually
// <50 bytes); for longer ones we'd want xxhash but the cost dominance is
// the L3-miss probe, not the hash itself.
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
    std::vector<StrEntry> entries;
    size_t mask;
    size_t live = 0;

    StrMap() : slots(INIT_CAP, -1), entries(), mask(INIT_CAP - 1) { entries.reserve(1024); }

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

    int64_t* find_or_insert(uint64_t h, const char* p, size_t n, const char* data_base, uint64_t row_off) {
        size_t pos = h & mask;
        while (true) {
            int32_t idx = slots[pos];
            if (idx == -1) {
                StrEntry e;
                e.hash = h;
                e.off_lo = (uint32_t)(row_off & 0xffffffffu);
                e.off_hi = (uint32_t)(row_off >> 32);
                e.len = (uint32_t)n;
                e.count = 0;
                entries.push_back(e);
                slots[pos] = (int32_t)(entries.size() - 1);
                ++live;
                int64_t* ret = &entries.back().count;
                maybe_grow();
                // After grow the pointer is still valid: entries vector wasn't reallocated
                // in maybe_grow (only the slots index moved). The push_back above is the
                // last potential realloc.
                return ret;
            }
            auto& e = entries[idx];
            if (e.hash == h && e.len == n) {
                uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
                if (memcmp(data_base + off, p, n) == 0) return &e.count;
            }
            pos = (pos + 1) & mask;
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q13 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    auto sp = gendb::mmap_strcol(dir, "SearchPhrase");

    int T = omp_get_max_threads();
    std::vector<StrMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        StrMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < sp.n; ++i) {
            uint64_t a = sp.off[i], b = sp.off[i + 1];
            if (a == b) continue;  // empty string
            const char* p = sp.data + a;
            size_t n = (size_t)(b - a);
            uint64_t h = hash_bytes(p, n);
            int64_t* cnt = m.find_or_insert(h, p, n, sp.data, a);
            *cnt += 1;
        }
    }

    // Merge per-thread maps into a single map.
    StrMap merged;
    for (auto& m : maps) {
        for (auto& e : m.entries) {
            uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
            int64_t* tgt = merged.find_or_insert(e.hash, sp.data + off, e.len, sp.data, off);
            *tgt += e.count;
        }
    }

    // TopK by count.
    using Row = std::pair<int64_t, int>;  // (count, index into merged.entries)
    gendb::TopK<Row> top(10);
    for (size_t i = 0; i < merged.entries.size(); ++i) {
        top.try_push({merged.entries[i].count, (int)i});
    }
    auto rows = top.sorted_desc();

    std::printf("SearchPhrase,c\n");
    for (auto& r : rows) {
        auto& e = merged.entries[r.second];
        uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
        std::fwrite(sp.data + off, 1, e.len, stdout);
        std::printf(",%lld\n", (long long)r.first);
    }
    return 0;
}
