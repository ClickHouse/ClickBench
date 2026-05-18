// Q33: SELECT WatchID, ClientIP, COUNT(*) AS c,
//             SUM(IsRefresh), AVG(ResolutionWidth)
//      FROM hits GROUP BY WatchID, ClientIP
//      ORDER BY c DESC LIMIT 10;
//
// Same shape as Q32 but WITHOUT the SearchPhrase filter — every one of the
// ~100M rows feeds the aggregation. WatchID is int64, ClientIP is int32; the
// composite (WatchID, ClientIP) is effectively row-unique (cardinality on the
// order of tens of millions), so per-thread hashmaps must be sized to absorb
// roughly HITS_ROWS / T entries each without thrashing.
//
// Strategy:
//   - Per-thread open-addressing hashmap keyed on (WatchID, ClientIP),
//     using gendb::mix_pair for distribution. Sentinel = WatchID == INT64_MIN
//     (no real row has it).
//   - Pre-size each per-thread map at 1<<22 slots (~4M) and rely on doubling.
//     With 8 threads and ~50M groups we expect each map to grow to 1<<23 or
//     1<<24; pre-sizing high amortizes the cost of the rehashes that do
//     happen and keeps the early hot loop out of the resize path.
//   - Serial merge into one final map, then TopK by count.
//
// Output: WatchID,ClientIP,c,sum_ref,avg_rw

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

// Open-addressing hashmap keyed on (WatchID:int64, ClientIP:int32) packed
// into a Pair64. Empty sentinel: WatchID == INT64_MIN.
struct GroupMap {
    std::vector<int64_t>  k_wid;   // WatchID
    std::vector<int32_t>  k_ip;    // ClientIP
    std::vector<Agg>      vals;
    size_t mask;
    size_t live = 0;
    static constexpr int64_t EMPTY = INT64_MIN;

    explicit GroupMap(size_t cap_pow2 = (size_t)1 << 22)
        : k_wid(cap_pow2, EMPTY), k_ip(cap_pow2, 0), vals(cap_pow2),
          mask(cap_pow2 - 1) {}

    inline Agg* get(int64_t wid, int32_t ip) {
        gendb::Pair64 p{(uint64_t)wid, (uint64_t)(uint32_t)ip};
        size_t pos = gendb::mix_pair(p) & mask;
        while (true) {
            int64_t s = k_wid[pos];
            if (s == EMPTY) {
                k_wid[pos] = wid;
                k_ip[pos]  = ip;
                ++live;
                if (live * 2 > k_wid.size()) {
                    grow();
                    return get(wid, ip);
                }
                return &vals[pos];
            }
            if (s == wid && k_ip[pos] == ip) return &vals[pos];
            pos = (pos + 1) & mask;
        }
    }

    void grow() {
        std::vector<int64_t> ow = std::move(k_wid);
        std::vector<int32_t> oi = std::move(k_ip);
        std::vector<Agg>     ov = std::move(vals);
        size_t newcap = ow.size() * 2;
        k_wid.assign(newcap, EMPTY);
        k_ip.assign(newcap, 0);
        vals.assign(newcap, Agg{});
        mask = newcap - 1;
        live = 0;
        for (size_t i = 0; i < ow.size(); ++i) {
            if (ow[i] != EMPTY) {
                gendb::Pair64 p{(uint64_t)ow[i], (uint64_t)(uint32_t)oi[i]};
                size_t pos = gendb::mix_pair(p) & mask;
                while (k_wid[pos] != EMPTY) pos = (pos + 1) & mask;
                k_wid[pos] = ow[i];
                k_ip[pos]  = oi[i];
                vals[pos]  = ov[i];
                ++live;
            }
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q33 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int64_t* wid = gendb::mmap_col<int64_t>(dir, "WatchID");
    const int32_t* ip  = gendb::mmap_col<int32_t>(dir, "ClientIP");
    const int16_t* ref = gendb::mmap_col<int16_t>(dir, "IsRefresh");
    const int16_t* rw  = gendb::mmap_col<int16_t>(dir, "ResolutionWidth");

    int T = omp_get_max_threads();
    std::vector<GroupMap> maps;
    maps.reserve(T);
    for (int t = 0; t < T; ++t) maps.emplace_back((size_t)1 << 22);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        GroupMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            Agg* a = m.get(wid[i], ip[i]);
            a->count   += 1;
            a->sum_ref += ref[i];
            a->sum_rw  += rw[i];
        }
    }

    // Serial merge of per-thread maps. The merged map may end up with ~50M
    // groups, so seed it generously too.
    GroupMap merged((size_t)1 << 23);
    for (auto& m : maps) {
        for (size_t i = 0; i < m.k_wid.size(); ++i) {
            if (m.k_wid[i] == GroupMap::EMPTY) continue;
            Agg* dst = merged.get(m.k_wid[i], m.k_ip[i]);
            const Agg& src = m.vals[i];
            dst->count   += src.count;
            dst->sum_ref += src.sum_ref;
            dst->sum_rw  += src.sum_rw;
        }
    }

    // TopK by count.
    struct Row {
        int64_t count;
        int64_t wid;
        int32_t ip;
    };
    struct RowLess {
        bool operator()(const Row& a, const Row& b) const { return a.count < b.count; }
    };
    gendb::TopK<Row, RowLess> top(10);
    for (size_t i = 0; i < merged.k_wid.size(); ++i) {
        if (merged.k_wid[i] == GroupMap::EMPTY) continue;
        top.try_push(Row{merged.vals[i].count, merged.k_wid[i], merged.k_ip[i]});
    }
    auto rows = top.sorted_desc();

    std::printf("WatchID,ClientIP,c,sum_ref,avg_rw\n");
    for (auto& r : rows) {
        Agg* a = merged.get(r.wid, r.ip);
        double avg_rw = a->count ? (double)a->sum_rw / (double)a->count : 0.0;
        std::printf("%lld,%d,%lld,%lld,%.6f\n",
                    (long long)r.wid,
                    (int)r.ip,
                    (long long)a->count,
                    (long long)a->sum_ref,
                    avg_rw);
    }
    return 0;
}
