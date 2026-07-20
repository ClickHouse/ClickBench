// Q31: SELECT SearchEngineID, ClientIP, COUNT(*) AS c, SUM(IsRefresh),
//             AVG(ResolutionWidth)
//      FROM hits WHERE SearchPhrase <> ''
//      GROUP BY SearchEngineID, ClientIP
//      ORDER BY c DESC LIMIT 10;
//
// Composite grouping key: int16 SearchEngineID + int32 ClientIP. Both fit
// into an int64:  key = ((uint64)(uint16)se << 32) | (uint32)cip.
// Filter: only rows whose SearchPhrase is non-empty.
//
// Per-thread open-addressing hashmap on the int64 composite key →
// {count, sum_isrefresh, sum_rw}. Merge thread maps, then TopK by count.
//
// Sentinel for the empty key: we choose a value that cannot occur as a real
// composite. SearchEngineID is non-negative in the schema (small enum), so
// se < 0 is impossible; we use UINT64_MAX as sentinel — its high 32 bits
// (= 0xFFFFFFFF) decode as a negative int16 SearchEngineID, which never
// appears in legitimate data.

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

struct Agg {
    int64_t count = 0;
    int64_t sum_ref = 0;
    int64_t sum_rw  = 0;
};

// Open-addressing hashmap: int64 composite key -> Agg. Sentinel UINT64_MAX.
struct KeyMap {
    std::vector<uint64_t> keys;
    std::vector<Agg>      vals;
    size_t mask;
    size_t live = 0;
    static constexpr uint64_t EMPTY = UINT64_MAX;

    KeyMap() : keys(1024, EMPTY), vals(1024), mask(1023) {}

    inline Agg* get(uint64_t k) {
        size_t pos = gendb::mix64(k) & mask;
        while (true) {
            uint64_t s = keys[pos];
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
        std::vector<uint64_t> ok = std::move(keys);
        std::vector<Agg>      ov = std::move(vals);
        size_t newcap = ok.size() * 2;
        keys.assign(newcap, EMPTY);
        vals.assign(newcap, Agg{});
        mask = newcap - 1;
        live = 0;
        for (size_t i = 0; i < ok.size(); ++i) {
            if (ok[i] != EMPTY) {
                size_t pos = gendb::mix64(ok[i]) & mask;
                while (keys[pos] != EMPTY) pos = (pos + 1) & mask;
                keys[pos] = ok[i];
                vals[pos] = ov[i];
                ++live;
            }
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q31 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int16_t* se  = gendb::mmap_col<int16_t>(dir, "SearchEngineID");
    const int32_t* cip = gendb::mmap_col<int32_t>(dir, "ClientIP");
    const int16_t* ref = gendb::mmap_col<int16_t>(dir, "IsRefresh");
    const int16_t* rw  = gendb::mmap_col<int16_t>(dir, "ResolutionWidth");
    gendb::StrCol  sp  = gendb::mmap_strcol(dir, "SearchPhrase");

    int T = omp_get_max_threads();
    std::vector<KeyMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        KeyMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            // Filter SearchPhrase <> ''
            if (sp.off[i + 1] == sp.off[i]) continue;
            uint64_t k = ((uint64_t)(uint16_t)se[i] << 32)
                       | (uint64_t)(uint32_t)cip[i];
            Agg* a = m.get(k);
            a->count   += 1;
            a->sum_ref += ref[i];
            a->sum_rw  += rw[i];
        }
    }

    // Serial merge of per-thread maps.
    KeyMap merged;
    for (auto& m : maps) {
        for (size_t i = 0; i < m.keys.size(); ++i) {
            if (m.keys[i] == KeyMap::EMPTY) continue;
            Agg* dst = merged.get(m.keys[i]);
            const Agg& src = m.vals[i];
            dst->count   += src.count;
            dst->sum_ref += src.sum_ref;
            dst->sum_rw  += src.sum_rw;
        }
    }

    // TopK by count.
    using Row = std::pair<int64_t, uint64_t>;  // (count, composite_key)
    gendb::TopK<Row> top(10);
    for (size_t i = 0; i < merged.keys.size(); ++i) {
        if (merged.keys[i] == KeyMap::EMPTY) continue;
        top.try_push({merged.vals[i].count, merged.keys[i]});
    }
    auto rows = top.sorted_desc();

    std::printf("SearchEngineID,ClientIP,c,sum_ref,avg_rw\n");
    for (auto& r : rows) {
        Agg* a = merged.get(r.second);
        int16_t  se_v  = (int16_t)((uint16_t)(r.second >> 32));
        int32_t  cip_v = (int32_t)(uint32_t)(r.second & 0xFFFFFFFFULL);
        double avg_rw = a->count ? (double)a->sum_rw / (double)a->count : 0.0;
        std::printf("%d,%d,%lld,%lld,%.6f\n",
                    (int)se_v,
                    (int)cip_v,
                    (long long)a->count,
                    (long long)a->sum_ref,
                    avg_rw);
    }
    return 0;
}
