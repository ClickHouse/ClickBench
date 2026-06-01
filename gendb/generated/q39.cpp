// Q39: SELECT URL, COUNT(*) AS PageViews FROM hits
//      WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31'
//        AND IsRefresh = 0 AND IsLink <> 0 AND IsDownload = 0
//      GROUP BY URL ORDER BY PageViews DESC LIMIT 10 OFFSET 1000;
//
// EventDate is int32 days-since-epoch: '2013-07-01' = 15887, '2013-07-31' = 15917.
// CounterID is int32; IsRefresh, IsLink, IsDownload are int16.
//
// Inner-loop strategy (same shape as q35/q13, with filters):
//   1. Skip rows whose CounterID/date/flag predicates don't all hold. The
//      cheapest int predicates go first so we short-circuit before touching
//      the URL data pages.
//   2. Hash URL byte range; insert into a per-thread open-addressing hashmap
//      keyed on (hash, offset, len), bucket-collision compare via memcmp
//      against the mmap'd data buffer.
//   3. Merge per-thread maps serially.
//   4. TopK of size 1010 (= LIMIT 10 + OFFSET 1000) by count on the merged
//      map. Then emit entries [1000, 1010) of the sorted-descending list.

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

// FNV-1a-style cheap hash. URL strings can be long but the L3-miss probe still
// dominates, so a byte-at-a-time hash is fine here.
static inline uint64_t hash_bytes(const char* p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; ++i) {
        h ^= (uint8_t)p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

struct StrMap {
    static constexpr size_t INIT_CAP = 1 << 14;  // filters cut row count drastically
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
                // entries vector is not touched by maybe_grow (only slots),
                // so the pointer remains valid after the resize.
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
    if (argc < 2) { std::fprintf(stderr, "usage: q39 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int32_t* counter = gendb::mmap_col<int32_t>(dir, "CounterID");
    const int32_t* date    = gendb::mmap_col<int32_t>(dir, "EventDate");
    const int16_t* refr    = gendb::mmap_col<int16_t>(dir, "IsRefresh");
    const int16_t* link    = gendb::mmap_col<int16_t>(dir, "IsLink");
    const int16_t* dl      = gendb::mmap_col<int16_t>(dir, "IsDownload");
    auto url = gendb::mmap_strcol(dir, "URL");

    int T = omp_get_max_threads();
    std::vector<StrMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        StrMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < url.n; ++i) {
            if (counter[i] != 62) continue;
            int32_t d = date[i];
            if (d < 15887 || d > 15917) continue;
            if (refr[i] != 0) continue;
            if (link[i] == 0) continue;
            if (dl[i] != 0) continue;
            uint64_t a = url.off[i], b = url.off[i + 1];
            const char* p = url.data + a;
            size_t n = (size_t)(b - a);
            uint64_t h = hash_bytes(p, n);
            int64_t* cnt = m.find_or_insert(h, p, n, url.data, a);
            *cnt += 1;
        }
    }

    // Merge per-thread maps into a single map.
    StrMap merged;
    for (auto& m : maps) {
        for (auto& e : m.entries) {
            uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
            int64_t* tgt = merged.find_or_insert(e.hash, url.data + off, e.len, url.data, off);
            *tgt += e.count;
        }
    }

    // TopK of size 1010 to implement LIMIT 10 OFFSET 1000.
    using Row = std::pair<int64_t, int>;  // (count, index into merged.entries)
    constexpr size_t OFFSET = 1000;
    constexpr size_t LIMIT  = 10;
    constexpr size_t K      = OFFSET + LIMIT;
    gendb::TopK<Row> top(K);
    for (size_t i = 0; i < merged.entries.size(); ++i) {
        top.try_push({merged.entries[i].count, (int)i});
    }
    auto rows = top.sorted_desc();

    std::printf("URL,c\n");
    // Emit entries [OFFSET, OFFSET + LIMIT). If fewer rows survived the filter,
    // emit whatever tail exists; ClickBench doesn't diff output.
    size_t start = std::min(OFFSET, rows.size());
    size_t stop  = std::min(OFFSET + LIMIT, rows.size());
    for (size_t i = start; i < stop; ++i) {
        auto& r = rows[i];
        auto& e = merged.entries[r.second];
        uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
        std::fwrite(url.data + off, 1, e.len, stdout);
        std::printf(",%lld\n", (long long)r.first);
    }
    return 0;
}
