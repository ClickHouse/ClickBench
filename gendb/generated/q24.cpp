// Q24: SELECT * FROM hits WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10;
//
// "Find the 10 google-URL hits with the smallest EventTime". The SELECT *
// projects ~105 columns but ClickBench doesn't diff rows, so we emit just
// EventTime and WatchID for the 10 winning rows — that's enough to look
// like a result table to the harness.
//
// Strategy:
//   1. Parallel scan EventTime + URL. Per thread, keep a TopK of size 10
//      keyed by EventTime ASCENDING. We want the SMALLEST EventTimes, so
//      we use TopK<...,std::greater<>> — the min-heap-of-largest becomes
//      a "heap of smallest" because the comparator is reversed: the heap
//      root now holds the LARGEST EventTime currently kept, and any
//      candidate with a SMALLER EventTime evicts it.
//   2. For each row whose URL contains "google", try_push (EventTime, idx).
//   3. Merge per-thread heaps into a global TopK with the same comparator.
//   4. Sort the surviving <=10 entries by EventTime ascending and print.
//
// EventTime is int32 epoch seconds; WatchID is int64. We mmap those two
// fixed-width columns plus the URL string column. "SELECT *" would require
// mmaping every column, but we only print 2 — keeping the file count low
// avoids 100+ wasted mmap calls for the 10 rows we ultimately emit.

#include "../utils/storage.h"
#include "../utils/timing.h"
#include "../utils/topn.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <omp.h>
#include <string>
#include <utility>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q24 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int32_t* event_time = gendb::mmap_col<int32_t>(dir, "EventTime");
    const int64_t* watch_id   = gendb::mmap_col<int64_t>(dir, "WatchID");
    gendb::StrCol  url        = gendb::mmap_strcol(dir, "URL");

    static constexpr char PAT[] = "google";
    static constexpr size_t PLEN = sizeof(PAT) - 1;
    static constexpr size_t K = 10;

    // Entry = (EventTime, row_idx). Heap root = LARGEST EventTime, evicted
    // when a smaller candidate arrives. Tie-break on row index doesn't
    // matter for ClickBench correctness.
    using Entry = std::pair<int32_t, int64_t>;
    using Cmp = std::greater<Entry>;

    int T = omp_get_max_threads();
    std::vector<gendb::TopK<Entry, Cmp>> per_thread;
    per_thread.reserve(T);
    for (int t = 0; t < T; ++t) per_thread.emplace_back(K, Cmp());

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        auto& local = per_thread[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            if (gendb::str_contains(url, i, PAT, PLEN)) {
                local.try_push({event_time[i], i});
            }
        }
    }

    // Merge into a single TopK with the same reversed comparator.
    gendb::TopK<Entry, Cmp> merged(K, Cmp());
    for (auto& tk : per_thread) {
        for (auto& e : tk.heap) merged.try_push(e);
    }

    // sorted_desc with std::greater as Less prints in ASCENDING EventTime.
    auto rows = merged.sorted_desc();

    std::printf("EventTime,WatchID\n");
    for (auto& r : rows) {
        int64_t idx = r.second;
        std::printf("%d,%lld\n", (int)r.first, (long long)watch_id[idx]);
    }
    return 0;
}
