// Q10: SELECT RegionID, SUM(AdvEngineID), COUNT(*) AS c,
//             AVG(ResolutionWidth), COUNT(DISTINCT UserID)
//      FROM hits GROUP BY RegionID ORDER BY c DESC LIMIT 10;
//
// RegionID is int32 (millions of distinct values are *theoretically* possible
// but in this dataset the cardinality is on the order of ~10k). We use a
// per-thread open-addressing hashmap keyed by RegionID; each value carries
// SUM(AdvEngineID), COUNT, SUM(ResolutionWidth), and an I64Set of UserIDs for
// COUNT(DISTINCT). Threads merge at the end (sets unioned), then TopK by
// count.
//
// RegionID values are non-negative in this dataset; we use INT32_MIN as the
// empty-key sentinel.

#include "../utils/storage.h"
#include "../utils/timing.h"
#include "../utils/hashmap.h"
#include "../utils/topn.h"

#include <algorithm>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <omp.h>
#include <string>
#include <vector>

// Open-addressing hashset on int64 (UserID). Sentinel: INT64_MIN.
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
        live = 0;
        for (int64_t v : old) {
            if (v != EMPTY) {
                size_t pos = gendb::mix64((uint64_t)v) & mask;
                while (slots[pos] != EMPTY) pos = (pos + 1) & mask;
                slots[pos] = v;
                ++live;
            }
        }
    }
};

struct Agg {
    int64_t sum_aei = 0;
    int64_t count = 0;
    int64_t sum_rw = 0;
    I64Set  uids;
};

// Open-addressing hashmap: int32 RegionID -> Agg. Sentinel INT32_MIN.
struct RegionMap {
    std::vector<int32_t> keys;
    std::vector<Agg>     vals;
    size_t mask;
    size_t live = 0;
    static constexpr int32_t EMPTY = INT_MIN;

    RegionMap() : keys(1024, EMPTY), vals(1024), mask(1023) {}

    inline Agg* get(int32_t k) {
        size_t pos = gendb::mix32((uint32_t)k) & mask;
        while (true) {
            int32_t s = keys[pos];
            if (s == EMPTY) {
                keys[pos] = k;
                ++live;
                if (live * 2 > keys.size()) {
                    grow();
                    return get(k);
                }
                return &vals[pos];
            }
            if (s == k) return &vals[pos];
            pos = (pos + 1) & mask;
        }
    }

    void grow() {
        std::vector<int32_t> ok = std::move(keys);
        std::vector<Agg>     ov = std::move(vals);
        size_t newcap = ok.size() * 2;
        keys.assign(newcap, EMPTY);
        vals.assign(newcap, Agg{});
        mask = newcap - 1;
        live = 0;
        for (size_t i = 0; i < ok.size(); ++i) {
            if (ok[i] != EMPTY) {
                size_t pos = gendb::mix32((uint32_t)ok[i]) & mask;
                while (keys[pos] != EMPTY) pos = (pos + 1) & mask;
                keys[pos] = ok[i];
                vals[pos] = std::move(ov[i]);
                ++live;
            }
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q10 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int32_t* rid = gendb::mmap_col<int32_t>(dir, "RegionID");
    const int16_t* aei = gendb::mmap_col<int16_t>(dir, "AdvEngineID");
    const int16_t* rw  = gendb::mmap_col<int16_t>(dir, "ResolutionWidth");
    const int64_t* uid = gendb::mmap_col<int64_t>(dir, "UserID");

    int T = omp_get_max_threads();
    std::vector<RegionMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        RegionMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            int32_t r = rid[i];
            Agg* a = m.get(r);
            a->sum_aei += aei[i];
            a->count   += 1;
            a->sum_rw  += rw[i];
            a->uids.insert(uid[i]);
        }
    }

    // Serial merge of per-thread maps.
    RegionMap merged;
    for (auto& m : maps) {
        for (size_t i = 0; i < m.keys.size(); ++i) {
            if (m.keys[i] == RegionMap::EMPTY) continue;
            Agg* dst = merged.get(m.keys[i]);
            const Agg& src = m.vals[i];
            dst->sum_aei += src.sum_aei;
            dst->count   += src.count;
            dst->sum_rw  += src.sum_rw;
            // Union UserID sets.
            for (int64_t v : src.uids.slots) {
                if (v != I64Set::EMPTY) dst->uids.insert(v);
            }
        }
    }

    // TopK by count.
    using Row = std::pair<int64_t, int32_t>;  // (count, RegionID)
    gendb::TopK<Row> top(10);
    for (size_t i = 0; i < merged.keys.size(); ++i) {
        if (merged.keys[i] == RegionMap::EMPTY) continue;
        top.try_push({merged.vals[i].count, merged.keys[i]});
    }
    auto rows = top.sorted_desc();

    std::printf("RegionID,sum_aei,c,avg_rw,ndv\n");
    for (auto& r : rows) {
        // Re-lookup the full aggregate by RegionID.
        Agg* a = merged.get(r.second);
        double avg_rw = a->count ? (double)a->sum_rw / (double)a->count : 0.0;
        std::printf("%d,%lld,%lld,%.6f,%zu\n",
                    (int)r.second,
                    (long long)a->sum_aei,
                    (long long)a->count,
                    avg_rw,
                    a->uids.live);
    }
    return 0;
}
