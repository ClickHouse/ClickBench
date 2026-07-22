// Q40: SELECT TraficSourceID, SearchEngineID, AdvEngineID,
//             CASE WHEN (SearchEngineID = 0 AND AdvEngineID = 0)
//                  THEN Referer ELSE '' END AS Src,
//             URL AS Dst, COUNT(*) AS PageViews
//      FROM hits
//      WHERE CounterID = 62
//        AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31'
//        AND IsRefresh = 0
//      GROUP BY TraficSourceID, SearchEngineID, AdvEngineID, Src, Dst
//      ORDER BY PageViews DESC LIMIT 10 OFFSET 1000;
//
// Five-column composite key: (int16 tsi, int16 sei, int16 aei,
// string Src, string Dst). Src is Referer when both engines are 0,
// otherwise the empty string. Dst is always URL.
//
// Strategy:
//   1. Parallel scan; apply fixed-width filters first.
//   2. Build composite hash = mix64(tsi) ^ (mix64(sei) << 1)
//                            ^ (mix64(aei) << 2)
//                            ^ fnv1a(src_bytes)
//                            ^ (fnv1a(dst_bytes) * 0x9e3779b97f4a7c15).
//   3. Per-thread open-addressing hashmap keyed by the 5-tuple. On collision
//      compare ints + both byte ranges via memcmp.
//   4. Serial merge of per-thread maps; TopK 1010 by count; emit rows 1001..1010.

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
    uint64_t hash;          // composite hash of (tsi, sei, aei, Src, Dst)
    uint32_t src_off_lo;    // Referer offset (or 0 if Src is empty)
    uint32_t src_off_hi;
    uint32_t src_len;       // Src byte length (0 if Src is empty)
    uint32_t dst_off_lo;    // URL offset
    uint32_t dst_off_hi;
    uint32_t dst_len;
    int16_t  tsi;
    int16_t  sei;
    int16_t  aei;
    int64_t  count;
};

// FNV-1a over a byte range, identical to q13/q15/q37.
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

    StrMap() : slots(INIT_CAP, -1), mask(INIT_CAP - 1) { entries.reserve(1024); }

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

    // Locate (or create) the entry for (tsi, sei, aei, Src bytes, Dst bytes)
    // keyed by the pre-computed composite hash `h`. The Src/Dst byte ranges
    // are passed by (offset, length) into shared string data buffers.
    int64_t* find_or_insert(uint64_t h,
                            int16_t tsi, int16_t sei, int16_t aei,
                            const char* src_p, size_t src_n,
                            uint64_t src_off,
                            const char* dst_p, size_t dst_n,
                            uint64_t dst_off,
                            const char* referer_base,
                            const char* url_base) {
        size_t pos = h & mask;
        while (true) {
            int32_t idx = slots[pos];
            if (idx == -1) {
                Entry e;
                e.hash = h;
                e.src_off_lo = (uint32_t)(src_off & 0xffffffffu);
                e.src_off_hi = (uint32_t)(src_off >> 32);
                e.src_len = (uint32_t)src_n;
                e.dst_off_lo = (uint32_t)(dst_off & 0xffffffffu);
                e.dst_off_hi = (uint32_t)(dst_off >> 32);
                e.dst_len = (uint32_t)dst_n;
                e.tsi = tsi;
                e.sei = sei;
                e.aei = aei;
                e.count = 0;
                entries.push_back(e);
                slots[pos] = (int32_t)(entries.size() - 1);
                ++live;
                int64_t* ret = &entries.back().count;
                // maybe_grow only rebuilds `slots`, not `entries`, so the
                // pointer above stays valid.
                maybe_grow();
                return ret;
            }
            Entry& e = entries[idx];
            if (e.hash == h && e.tsi == tsi && e.sei == sei && e.aei == aei
                && e.src_len == src_n && e.dst_len == dst_n) {
                uint64_t so = ((uint64_t)e.src_off_hi << 32) | e.src_off_lo;
                uint64_t doff = ((uint64_t)e.dst_off_hi << 32) | e.dst_off_lo;
                bool src_eq = (src_n == 0) ||
                              (memcmp(referer_base + so, src_p, src_n) == 0);
                if (src_eq && memcmp(url_base + doff, dst_p, dst_n) == 0)
                    return &e.count;
            }
            pos = (pos + 1) & mask;
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q40 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int32_t* counter_id  = gendb::mmap_col<int32_t>(dir, "CounterID");
    const int32_t* event_date  = gendb::mmap_col<int32_t>(dir, "EventDate");
    const int16_t* is_refresh  = gendb::mmap_col<int16_t>(dir, "IsRefresh");
    const int16_t* tsi_col     = gendb::mmap_col<int16_t>(dir, "TraficSourceID");
    const int16_t* sei_col     = gendb::mmap_col<int16_t>(dir, "SearchEngineID");
    const int16_t* aei_col     = gendb::mmap_col<int16_t>(dir, "AdvEngineID");
    gendb::StrCol  referer     = gendb::mmap_strcol(dir, "Referer");
    gendb::StrCol  url         = gendb::mmap_strcol(dir, "URL");

    // EventDate range: 2013-07-01 .. 2013-07-31 (inclusive).
    constexpr int32_t DATE_LO = 15887;
    constexpr int32_t DATE_HI = 15917;

    // Pre-compute the empty-string FNV-1a so we can use it without branching
    // through hash_bytes when Src is the empty literal.
    const uint64_t FNV_EMPTY = 0xcbf29ce484222325ULL;

    int T = omp_get_max_threads();
    std::vector<StrMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        StrMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < url.n; ++i) {
            if (counter_id[i] != 62) continue;
            int32_t d = event_date[i];
            if (d < DATE_LO || d > DATE_HI) continue;
            if (is_refresh[i] != 0) continue;

            int16_t tsi = tsi_col[i];
            int16_t sei = sei_col[i];
            int16_t aei = aei_col[i];

            // Src: Referer if both engines are 0, else empty string.
            uint64_t src_off;
            size_t   src_n;
            const char* src_p;
            uint64_t src_h;
            if (sei == 0 && aei == 0) {
                uint64_t ra = referer.off[i], rb = referer.off[i + 1];
                src_off = ra;
                src_n   = (size_t)(rb - ra);
                src_p   = referer.data + ra;
                src_h   = (src_n == 0) ? FNV_EMPTY : hash_bytes(src_p, src_n);
            } else {
                src_off = 0;
                src_n   = 0;
                src_p   = nullptr;
                src_h   = FNV_EMPTY;
            }

            // Dst: URL bytes (always).
            uint64_t ua = url.off[i], ub = url.off[i + 1];
            uint64_t dst_off = ua;
            size_t   dst_n   = (size_t)(ub - ua);
            const char* dst_p = url.data + ua;
            uint64_t dst_h = (dst_n == 0) ? FNV_EMPTY : hash_bytes(dst_p, dst_n);

            // Composite hash mixing all five components.
            uint64_t h = gendb::mix64((uint64_t)(uint16_t)tsi)
                       ^ (gendb::mix64((uint64_t)(uint16_t)sei) << 1)
                       ^ (gendb::mix64((uint64_t)(uint16_t)aei) << 2)
                       ^ src_h
                       ^ (dst_h * 0x9e3779b97f4a7c15ULL);

            int64_t* cnt = m.find_or_insert(
                h, tsi, sei, aei,
                src_p, src_n, src_off,
                dst_p, dst_n, dst_off,
                referer.data, url.data);
            *cnt += 1;
        }
    }

    // Serial merge of per-thread maps.
    StrMap merged;
    for (auto& m : maps) {
        for (auto& e : m.entries) {
            uint64_t so = ((uint64_t)e.src_off_hi << 32) | e.src_off_lo;
            uint64_t doff = ((uint64_t)e.dst_off_hi << 32) | e.dst_off_lo;
            const char* src_p = (e.src_len == 0) ? nullptr : (referer.data + so);
            const char* dst_p = url.data + doff;
            int64_t* tgt = merged.find_or_insert(
                e.hash, e.tsi, e.sei, e.aei,
                src_p, e.src_len, so,
                dst_p, e.dst_len, doff,
                referer.data, url.data);
            *tgt += e.count;
        }
    }

    // Top 1010 by count; output rows 1001..1010 (LIMIT 10 OFFSET 1000).
    constexpr size_t TOP = 1010;
    constexpr size_t OFFSET = 1000;
    using Row = std::pair<int64_t, int>;  // (count, entry index)
    gendb::TopK<Row> top(TOP);
    for (size_t i = 0; i < merged.entries.size(); ++i) {
        top.try_push({merged.entries[i].count, (int)i});
    }
    auto rows = top.sorted_desc();

    std::printf("TraficSourceID,SearchEngineID,AdvEngineID,Src,Dst,c\n");
    for (size_t i = OFFSET; i < rows.size() && i < OFFSET + 10; ++i) {
        auto& r = rows[i];
        auto& e = merged.entries[r.second];
        uint64_t so = ((uint64_t)e.src_off_hi << 32) | e.src_off_lo;
        uint64_t doff = ((uint64_t)e.dst_off_hi << 32) | e.dst_off_lo;
        std::printf("%d,%d,%d,", (int)e.tsi, (int)e.sei, (int)e.aei);
        if (e.src_len > 0) std::fwrite(referer.data + so, 1, e.src_len, stdout);
        std::printf(",");
        std::fwrite(url.data + doff, 1, e.dst_len, stdout);
        std::printf(",%lld\n", (long long)r.first);
    }
    return 0;
}
