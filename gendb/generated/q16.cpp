// Q16: SELECT UserID, COUNT(*) FROM hits GROUP BY UserID
//      ORDER BY COUNT(*) DESC LIMIT 10;
//
// UserID is int64 with very high cardinality. Per-thread int64->int64
// open-addressing hashmap (key = UserID, value = count). Sentinel for the
// empty slot is INT64_MIN since UserID values are positive in this dataset.
// After the parallel scan we serially merge the thread-local maps into one
// and run a min-heap TopK of size 10 on the (count, UserID) rows.
//
// We don't use gendb::HashMap directly because we want to avoid the
// find_or_insert recursion-on-grow it does and because keeping the slot
// layout (keys, counts) tight in one struct lets us share the grow path
// between insertion and merging.

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

namespace {

// Open-addressing int64 -> int64 hashmap with INT64_MIN as the empty
// sentinel. Linear probing, load factor capped at 0.5.
struct UidCountMap {
    std::vector<int64_t> keys;
    std::vector<int64_t> vals;
    size_t mask;
    size_t live = 0;
    static constexpr int64_t EMPTY = INT64_MIN;

    explicit UidCountMap(size_t cap_pow2)
        : keys(cap_pow2, EMPTY), vals(cap_pow2, 0), mask(cap_pow2 - 1) {}

    // Add `delta` to the count for UserID v. Inserts a fresh slot if needed.
    inline void add(int64_t v, int64_t delta) {
        // Remap the (extremely unlikely) sentinel collision so UserID==INT64_MIN
        // would still work. ClickBench UserIDs are positive.
        if (v == EMPTY) v = EMPTY + 1;
        size_t pos = gendb::mix64((uint64_t)v) & mask;
        while (true) {
            int64_t k = keys[pos];
            if (k == EMPTY) {
                keys[pos] = v;
                vals[pos] = delta;
                ++live;
                if (live * 2 > keys.size()) grow();
                return;
            }
            if (k == v) {
                vals[pos] += delta;
                return;
            }
            pos = (pos + 1) & mask;
        }
    }

    void grow() {
        std::vector<int64_t> ok = std::move(keys);
        std::vector<int64_t> ov = std::move(vals);
        size_t newcap = ok.size() * 2;
        keys.assign(newcap, EMPTY);
        vals.assign(newcap, 0);
        mask = newcap - 1;
        for (size_t i = 0; i < ok.size(); ++i) {
            int64_t k = ok[i];
            if (k == EMPTY) continue;
            size_t pos = gendb::mix64((uint64_t)k) & mask;
            while (keys[pos] != EMPTY) pos = (pos + 1) & mask;
            keys[pos] = k;
            vals[pos] = ov[i];
        }
    }
};

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q16 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];
    const int64_t* uid = gendb::mmap_col<int64_t>(dir, "UserID");

    int T = omp_get_max_threads();
    std::vector<UidCountMap> per_thread;
    per_thread.reserve(T);
    // Initial capacity 1<<18 = 262144 slots per thread; grows on demand.
    for (int i = 0; i < T; ++i) per_thread.emplace_back(1 << 18);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        UidCountMap& m = per_thread[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            m.add(uid[i], 1);
        }
    }

    // Merge thread-local maps into one. Start large enough to avoid most
    // growth during the merge (the final distinct count of UserID is on the
    // order of ~17M, so 1<<25 = ~33M slots fits at load <0.5).
    UidCountMap merged(1 << 25);
    for (auto& m : per_thread) {
        for (size_t i = 0; i < m.keys.size(); ++i) {
            int64_t k = m.keys[i];
            if (k == UidCountMap::EMPTY) continue;
            merged.add(k, m.vals[i]);
        }
        // Release per-thread memory eagerly once merged.
        std::vector<int64_t>().swap(m.keys);
        std::vector<int64_t>().swap(m.vals);
    }

    // TopK by count.
    using Row = std::pair<int64_t, int64_t>;  // (count, UserID)
    gendb::TopK<Row> top(10);
    for (size_t i = 0; i < merged.keys.size(); ++i) {
        int64_t k = merged.keys[i];
        if (k == UidCountMap::EMPTY) continue;
        top.try_push({merged.vals[i], k});
    }
    auto rows = top.sorted_desc();

    std::printf("UserID,c\n");
    for (auto& r : rows) {
        std::printf("%lld,%lld\n", (long long)r.second, (long long)r.first);
    }
    return 0;
}
