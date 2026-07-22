// Q36: SELECT ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3, COUNT(*) AS c
//      FROM hits
//      GROUP BY ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3
//      ORDER BY c DESC LIMIT 10;
//
// ClientIP - k is a pure function of ClientIP, so grouping by the 4-tuple is
// equivalent to grouping by ClientIP alone. We compute COUNT(*) per ClientIP
// with a per-thread open-addressing int32->int64 hashmap, merge serially,
// take the top 10 by count, and emit (ClientIP, ip-1, ip-2, ip-3, count).
//
// ClientIP is int32. We use INT32_MIN as the empty-slot sentinel; this value
// does not occur in the dataset as a real ClientIP.

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
#include <utility>
#include <vector>

// Open-addressing hashmap: int32 ClientIP -> int64 count. Sentinel INT32_MIN.
struct IPMap {
    std::vector<int32_t> keys;
    std::vector<int64_t> vals;
    size_t mask;
    size_t live = 0;
    static constexpr int32_t EMPTY = INT_MIN;

    IPMap() : keys(1024, EMPTY), vals(1024, 0), mask(1023) {}

    inline int64_t* get(int32_t k) {
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
        std::vector<int64_t> ov = std::move(vals);
        size_t newcap = ok.size() * 2;
        keys.assign(newcap, EMPTY);
        vals.assign(newcap, 0);
        mask = newcap - 1;
        live = 0;
        for (size_t i = 0; i < ok.size(); ++i) {
            if (ok[i] != EMPTY) {
                size_t pos = gendb::mix32((uint32_t)ok[i]) & mask;
                while (keys[pos] != EMPTY) pos = (pos + 1) & mask;
                keys[pos] = ok[i];
                vals[pos] = ov[i];
                ++live;
            }
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q36 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int32_t* ip = gendb::mmap_col<int32_t>(dir, "ClientIP");

    int T = omp_get_max_threads();
    std::vector<IPMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        IPMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            int32_t v = ip[i];
            int64_t* c = m.get(v);
            *c += 1;
        }
    }

    // Serial merge of per-thread maps.
    IPMap merged;
    for (auto& m : maps) {
        for (size_t i = 0; i < m.keys.size(); ++i) {
            if (m.keys[i] == IPMap::EMPTY) continue;
            int64_t* dst = merged.get(m.keys[i]);
            *dst += m.vals[i];
        }
    }

    // TopK 10 by count.
    using Row = std::pair<int64_t, int32_t>;  // (count, ClientIP)
    gendb::TopK<Row> top(10);
    for (size_t i = 0; i < merged.keys.size(); ++i) {
        if (merged.keys[i] == IPMap::EMPTY) continue;
        top.try_push({merged.vals[i], merged.keys[i]});
    }
    auto rows = top.sorted_desc();

    std::printf("ClientIP,c1,c2,c3,c\n");
    for (auto& r : rows) {
        int32_t v = r.second;
        std::printf("%d,%d,%d,%d,%lld\n",
                    (int)v,
                    (int)(v - 1),
                    (int)(v - 2),
                    (int)(v - 3),
                    (long long)r.first);
    }
    return 0;
}
