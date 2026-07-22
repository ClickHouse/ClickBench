// Q28: SELECT CounterID, AVG(STRLEN(URL)) AS l, COUNT(*) AS c FROM hits
//      WHERE URL <> '' GROUP BY CounterID
//      HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25;
//
// For every row with a non-empty URL we accumulate sum(URL byte length) and
// count grouped by CounterID. CounterID is int32 with moderate cardinality
// (tens of thousands in practice). We use a per-thread open-addressing
// hashmap keyed by CounterID and serially merge afterward, then filter on
// count > 100000, compute avg = sum_len / count, and emit the 25 groups
// with the largest avg.
//
// URL length comes for free from the offset array: off[i+1] - off[i],
// which is also exactly the predicate ("URL <> ''" means len > 0).
//
// Sentinel for empty key: INT32_MIN (CounterID values are non-negative in
// this dataset).

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

namespace {

struct Agg {
    int64_t sum_len = 0;
    int64_t count   = 0;
};

// Open-addressing hashmap: int32 CounterID -> Agg. Sentinel INT32_MIN.
struct CounterMap {
    std::vector<int32_t> keys;
    std::vector<Agg>     vals;
    size_t mask;
    size_t live = 0;
    static constexpr int32_t EMPTY = INT_MIN;

    CounterMap() : keys(1024, EMPTY), vals(1024), mask(1023) {}

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
                vals[pos] = ov[i];
                ++live;
            }
        }
    }
};

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q28 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int32_t* cid = gendb::mmap_col<int32_t>(dir, "CounterID");
    gendb::StrCol  url = gendb::mmap_strcol(dir, "URL");
    const uint64_t* off = url.off;

    int T = omp_get_max_threads();
    std::vector<CounterMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        CounterMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            uint64_t len = off[i + 1] - off[i];
            if (len == 0) continue;  // URL <> ''
            Agg* a = m.get(cid[i]);
            a->sum_len += (int64_t)len;
            a->count   += 1;
        }
    }

    // Serial merge of per-thread maps.
    CounterMap merged;
    for (auto& m : maps) {
        for (size_t i = 0; i < m.keys.size(); ++i) {
            if (m.keys[i] == CounterMap::EMPTY) continue;
            Agg* dst = merged.get(m.keys[i]);
            const Agg& src = m.vals[i];
            dst->sum_len += src.sum_len;
            dst->count   += src.count;
        }
    }

    // HAVING COUNT(*) > 100000, ORDER BY avg(len) DESC LIMIT 25.
    // Min-heap of size 25 keyed on avg (double).
    using Row = std::tuple<double, int32_t, int64_t>;  // (avg_len, CounterID, count)
    struct LessByAvg {
        bool operator()(const Row& a, const Row& b) const {
            return std::get<0>(a) < std::get<0>(b);
        }
    };
    gendb::TopK<Row, LessByAvg> top(25);
    for (size_t i = 0; i < merged.keys.size(); ++i) {
        if (merged.keys[i] == CounterMap::EMPTY) continue;
        const Agg& a = merged.vals[i];
        if (a.count <= 100000) continue;
        double avg = (double)a.sum_len / (double)a.count;
        top.try_push(Row{avg, merged.keys[i], a.count});
    }
    auto rows = top.sorted_desc();

    std::printf("CounterID,l,c\n");
    for (auto& r : rows) {
        std::printf("%d,%.6f,%lld\n",
                    (int)std::get<1>(r),
                    std::get<0>(r),
                    (long long)std::get<2>(r));
    }
    return 0;
}
