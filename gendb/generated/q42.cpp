// Q42: SELECT WindowClientWidth, WindowClientHeight, COUNT(*) AS PageViews
//      FROM hits
//      WHERE CounterID = 62
//        AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31'
//        AND IsRefresh = 0 AND DontCountHits = 0
//        AND URLHash = 2868770270353813622
//      GROUP BY WindowClientWidth, WindowClientHeight
//      ORDER BY PageViews DESC LIMIT 10 OFFSET 10000;
//
// Strategy:
//   1. Parallel scan; cheap fixed-width predicates first (CounterID,
//      EventDate range, IsRefresh, DontCountHits). The URLHash filter on
//      int64 is also a single compare and is extremely selective — likely
//      only a few thousand rows survive.
//   2. Composite key = (WindowClientWidth << 16) | WindowClientHeight packed
//      into an int32. Per-thread open-addressing hashmap int32 -> int64.
//   3. Merge per-thread maps, materialize all (key, count) pairs, sort by
//      count DESC, output rows [10000:10010] (likely empty given the
//      extremely selective URLHash filter — but emit whatever slice exists).
//   4. Use sentinel = INT32_MIN since (0<<16)|0 = 0 is a legitimate key.

#include "../utils/storage.h"
#include "../utils/timing.h"
#include "../utils/hashmap.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <omp.h>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q42 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int32_t* counter_id  = gendb::mmap_col<int32_t>(dir, "CounterID");
    const int32_t* event_date  = gendb::mmap_col<int32_t>(dir, "EventDate");
    const int16_t* is_refresh  = gendb::mmap_col<int16_t>(dir, "IsRefresh");
    const int16_t* dont_count  = gendb::mmap_col<int16_t>(dir, "DontCountHits");
    const int16_t* win_w       = gendb::mmap_col<int16_t>(dir, "WindowClientWidth");
    const int16_t* win_h       = gendb::mmap_col<int16_t>(dir, "WindowClientHeight");
    const int64_t* url_hash    = gendb::mmap_col<int64_t>(dir, "URLHash");

    constexpr int32_t DATE_LO = 15887;  // 2013-07-01
    constexpr int32_t DATE_HI = 15917;  // 2013-07-31
    constexpr int64_t URL_HASH_TARGET = 2868770270353813622LL;
    constexpr int32_t EMPTY_KEY = INT32_MIN;

    int T = omp_get_max_threads();
    std::vector<gendb::HashMap<int32_t, int64_t>> maps;
    maps.reserve(T);
    for (int t = 0; t < T; ++t) maps.emplace_back(1 << 10, EMPTY_KEY);

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
            if (url_hash[i] != URL_HASH_TARGET) continue;
            // Pack (width, height) as int32. int16 values may be negative;
            // mask to 16 bits so the high half doesn't leak sign extension.
            int32_t key = (int32_t)(((uint32_t)(uint16_t)win_w[i] << 16)
                                    | (uint32_t)(uint16_t)win_h[i]);
            if (key == EMPTY_KEY) key = EMPTY_KEY + 1;  // avoid sentinel clash
            uint64_t h = gendb::mix32((uint32_t)key);
            int64_t* v = m.find_or_insert(key, h);
            *v += 1;
        }
    }

    // Merge per-thread maps.
    gendb::HashMap<int32_t, int64_t> merged(1 << 12, EMPTY_KEY);
    for (auto& m : maps) {
        for (size_t i = 0; i < m.keys.size(); ++i) {
            if (m.keys[i] == EMPTY_KEY) continue;
            int32_t k = m.keys[i];
            uint64_t h = gendb::mix32((uint32_t)k);
            int64_t* v = merged.find_or_insert(k, h);
            *v += m.vals[i];
        }
    }

    // Materialize all (count, key) rows and sort by count DESC.
    std::vector<std::pair<int64_t, int32_t>> rows;
    rows.reserve(merged.count);
    for (size_t i = 0; i < merged.keys.size(); ++i) {
        if (merged.keys[i] == EMPTY_KEY) continue;
        rows.emplace_back(merged.vals[i], merged.keys[i]);
    }
    std::sort(rows.begin(), rows.end(),
              [](const auto& a, const auto& b) { return a.first > b.first; });

    std::printf("WindowClientWidth,WindowClientHeight,c\n");
    constexpr size_t OFFSET = 10000;
    constexpr size_t LIMIT  = 10;
    size_t end = std::min(rows.size(), OFFSET + LIMIT);
    for (size_t i = OFFSET; i < end; ++i) {
        int32_t key = rows[i].second;
        int16_t w = (int16_t)((uint32_t)key >> 16);
        int16_t h = (int16_t)((uint32_t)key & 0xffffu);
        std::printf("%d,%d,%lld\n", (int)w, (int)h, (long long)rows[i].first);
    }
    return 0;
}
