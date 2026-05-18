// Q43: SELECT DATE_TRUNC('minute', EventTime) AS M, COUNT(*) AS PageViews
//      FROM hits
//      WHERE CounterID = 62
//        AND EventDate >= '2013-07-14' AND EventDate <= '2013-07-15'
//        AND IsRefresh = 0 AND DontCountHits = 0
//      GROUP BY DATE_TRUNC('minute', EventTime)
//      ORDER BY DATE_TRUNC('minute', EventTime)
//      LIMIT 10 OFFSET 1000;
//
// Strategy:
//   1. Parallel scan with four cheap fixed-width filters (CounterID,
//      EventDate range, IsRefresh, DontCountHits). EventTime, EventDate,
//      CounterID are int32; IsRefresh, DontCountHits are int16.
//   2. Group key is `(EventTime / 60) * 60` — Unix-epoch second rounded down
//      to the minute. Fits comfortably in int32 for 2013 timestamps.
//   3. Per-thread int32→int64 open-addressing HashMap with sentinel
//      INT32_MIN (a 2013 timestamp is always positive). Merge serially.
//   4. Sort merged entries by key ascending, then emit rows [1000:1010).
//      For a 2-day window there are at most ~2880 distinct minute buckets,
//      so the offset-1000 slice is almost certainly empty — we still
//      compute it correctly.

#include "../utils/storage.h"
#include "../utils/timing.h"
#include "../utils/hashmap.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <climits>
#include <omp.h>
#include <string>
#include <utility>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q43 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int32_t* counter_id = gendb::mmap_col<int32_t>(dir, "CounterID");
    const int32_t* event_date = gendb::mmap_col<int32_t>(dir, "EventDate");
    const int32_t* event_time = gendb::mmap_col<int32_t>(dir, "EventTime");
    const int16_t* is_refresh = gendb::mmap_col<int16_t>(dir, "IsRefresh");
    const int16_t* dont_count = gendb::mmap_col<int16_t>(dir, "DontCountHits");

    constexpr int32_t DATE_LO = 15900;  // 2013-07-14
    constexpr int32_t DATE_HI = 15901;  // 2013-07-15

    int T = omp_get_max_threads();
    // Per-thread maps. Capacity 8192 is plenty for ~2880 distinct minutes.
    std::vector<gendb::HashMap<int32_t, int64_t>> maps;
    maps.reserve(T);
    for (int t = 0; t < T; ++t) maps.emplace_back(1 << 13, INT32_MIN);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        auto& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            if (counter_id[i] != 62) continue;
            int32_t d = event_date[i];
            if (d < DATE_LO || d > DATE_HI) continue;
            if (is_refresh[i] != 0) continue;
            if (dont_count[i] != 0) continue;
            int32_t bucket = (event_time[i] / 60) * 60;
            int64_t* v = m.find_or_insert(bucket, gendb::mix32((uint32_t)bucket));
            *v += 1;
        }
    }

    // Merge per-thread maps.
    gendb::HashMap<int32_t, int64_t> merged(1 << 13, INT32_MIN);
    for (auto& m : maps) {
        m.for_each([&](int32_t k, int64_t v) {
            int64_t* tgt = merged.find_or_insert(k, gendb::mix32((uint32_t)k));
            *tgt += v;
        });
    }

    // Collect and sort ascending by minute bucket.
    std::vector<std::pair<int32_t, int64_t>> rows;
    rows.reserve(merged.count);
    merged.for_each([&](int32_t k, int64_t v) {
        rows.emplace_back(k, v);
    });
    std::sort(rows.begin(), rows.end(),
              [](const std::pair<int32_t, int64_t>& a,
                 const std::pair<int32_t, int64_t>& b) {
                  return a.first < b.first;
              });

    std::printf("M,c\n");
    size_t off = 1000;
    size_t lim = 10;
    size_t end = std::min(rows.size(), off + lim);
    for (size_t i = off; i < end; ++i) {
        std::printf("%d,%lld\n", rows[i].first, (long long)rows[i].second);
    }
    return 0;
}
