// Q34: SELECT URL, COUNT(*) AS c FROM hits
//      GROUP BY URL ORDER BY c DESC LIMIT 10;
//
// URL is high-cardinality (~1M distinct), with strings often >50 bytes.
// Strategy mirrors q13:
//   1. Per-thread open-addressing string hashmap keyed on (hash, off, len).
//   2. No WHERE filter — every row contributes a count, including empty URL.
//   3. Merge per-thread tables, then TopK 10 by count.
//
// Initial map capacity bumped to 1<<18 (vs q13's 1<<14) because each
// thread will see ~ HITS_ROWS/T rows mapping to hundreds of thousands of
// distinct URLs; starting big avoids the early O(N) rehash storm.

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

// FNV-1a-style cheap hash. URLs can be long (~100 bytes); FNV's per-byte
// cost is fine compared to the cache-miss probe that dominates anyway.
static inline uint64_t hash_bytes(const char* p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; ++i) {
        h ^= (uint8_t)p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

struct StrMap {
    static constexpr size_t INIT_CAP = 1 << 18;  // 262144 slots up front
    std::vector<int32_t> slots;  // -1 = empty, else index into entries
    std::vector<StrEntry> entries;
    size_t mask;
    size_t live = 0;

    StrMap() : slots(INIT_CAP, -1), entries(), mask(INIT_CAP - 1) {
        entries.reserve(1 << 17);
    }

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
                // After grow only the slots index moved; entries vector
                // wasn't reallocated, so the pointer above is still valid.
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
    if (argc < 2) { std::fprintf(stderr, "usage: q34 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    auto url = gendb::mmap_strcol(dir, "URL");

    int T = omp_get_max_threads();
    std::vector<StrMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        StrMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < url.n; ++i) {
            uint64_t a = url.off[i], b = url.off[i + 1];
            const char* p = url.data + a;
            size_t n = (size_t)(b - a);
            uint64_t h = hash_bytes(p, n);
            int64_t* cnt = m.find_or_insert(h, p, n, url.data, a);
            *cnt += 1;
        }
    }

    // Merge per-thread maps into one. Distinct URLs ~1M, so the merged map
    // needs room — INIT_CAP is already 1<<18 and it will grow as needed.
    StrMap merged;
    for (auto& m : maps) {
        for (auto& e : m.entries) {
            uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
            int64_t* tgt = merged.find_or_insert(e.hash, url.data + off, e.len, url.data, off);
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

    std::printf("URL,c\n");
    for (auto& r : rows) {
        auto& e = merged.entries[r.second];
        uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
        std::fwrite(url.data + off, 1, e.len, stdout);
        std::printf(",%lld\n", (long long)r.first);
    }
    return 0;
}
