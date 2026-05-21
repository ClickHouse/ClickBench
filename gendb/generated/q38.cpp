// Q38: SELECT Title, COUNT(*) AS PageViews FROM hits
//      WHERE CounterID = 62
//        AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31'
//        AND DontCountHits = 0
//        AND IsRefresh = 0
//        AND Title <> ''
//      GROUP BY Title ORDER BY PageViews DESC LIMIT 10;
//
// Same shape as q37 but grouping by Title (high-cardinality string) instead
// of URL. Filters drop the vast majority of the 100M rows before we even
// touch the string column, so the hashmap pressure is far below q13/q34.
//
// Inner-loop strategy:
//   1. Cheap fixed-width predicates first: CounterID == 62 (int32),
//      EventDate in [15887, 15917] (int32 days since epoch),
//      DontCountHits == 0 (int16), IsRefresh == 0 (int16).
//   2. Title <> '' is the off[i+1] != off[i] check.
//   3. Per-thread string hashmap keyed on (hash, off, len); merge after.
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

struct StrEntry {
    uint64_t hash;
    uint32_t off_lo;
    uint32_t off_hi;
    uint32_t len;
    int64_t  count;
};

// FNV-1a — fine for medium-length Title strings; the L3-miss probe
// dominates cost, not the per-byte hash work.
static inline uint64_t hash_bytes(const char* p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; ++i) {
        h ^= (uint8_t)p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

struct StrMap {
    // CounterID=62 + July-2013 + non-refresh narrows the surviving rows to
    // a small fraction of 100M, so a 1<<14 start is plenty.
    static constexpr size_t INIT_CAP = 1 << 14;
    std::vector<int32_t> slots;  // -1 = empty, else index into entries
    std::vector<StrEntry> entries;
    size_t mask;
    size_t live = 0;

    StrMap() : slots(INIT_CAP, -1), entries(), mask(INIT_CAP - 1) {
        entries.reserve(1024);
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
                // After grow only the slots index changed; entries vector
                // wasn't reallocated by maybe_grow, so the pointer above
                // remains valid.
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
    if (argc < 2) { std::fprintf(stderr, "usage: q38 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int32_t* counter_id = gendb::mmap_col<int32_t>(dir, "CounterID");
    const int32_t* event_date = gendb::mmap_col<int32_t>(dir, "EventDate");
    const int16_t* dont_count = gendb::mmap_col<int16_t>(dir, "DontCountHits");
    const int16_t* is_refresh = gendb::mmap_col<int16_t>(dir, "IsRefresh");
    auto title = gendb::mmap_strcol(dir, "Title");

    constexpr int32_t DATE_LO = 15887;  // 2013-07-01
    constexpr int32_t DATE_HI = 15917;  // 2013-07-31

    int T = omp_get_max_threads();
    std::vector<StrMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        StrMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < title.n; ++i) {
            if (counter_id[i] != 62) continue;
            int32_t d = event_date[i];
            if (d < DATE_LO || d > DATE_HI) continue;
            if (dont_count[i] != 0) continue;
            if (is_refresh[i] != 0) continue;
            uint64_t a = title.off[i], b = title.off[i + 1];
            if (a == b) continue;  // Title <> ''
            const char* p = title.data + a;
            size_t n = (size_t)(b - a);
            uint64_t h = hash_bytes(p, n);
            int64_t* cnt = m.find_or_insert(h, p, n, title.data, a);
            *cnt += 1;
        }
    }

    // Merge per-thread maps into one.
    StrMap merged;
    for (auto& m : maps) {
        for (auto& e : m.entries) {
            uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
            int64_t* tgt = merged.find_or_insert(e.hash, title.data + off, e.len, title.data, off);
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

    std::printf("Title,c\n");
    for (auto& r : rows) {
        auto& e = merged.entries[r.second];
        uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
        std::fwrite(title.data + off, 1, e.len, stdout);
        std::printf(",%lld\n", (long long)r.first);
    }
    return 0;
}
