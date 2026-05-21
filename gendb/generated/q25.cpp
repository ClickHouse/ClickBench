// Q25: SELECT SearchPhrase FROM hits
//      WHERE SearchPhrase <> '' ORDER BY EventTime LIMIT 10;
//
// Strategy:
//   1. Parallel scan over all rows. Skip rows where SearchPhrase is empty
//      (off[i+1] == off[i]).
//   2. Per-thread TopK of size 10, keyed by EventTime ASCENDING. We use
//      gendb::TopK with std::greater<Row> as the comparator: TopK keeps the
//      "largest by Less" entries, so with Less = greater, "largest by >" =
//      smallest by <, i.e. the 10 rows with smallest EventTime.
//   3. The element type carries (EventTime, row_index) so we can look up
//      SearchPhrase from the row index after the merge.
//   4. Merge all per-thread heaps into a single global TopK, then emit
//      SearchPhrase strings in ascending EventTime order (sorted_desc()
//      with std::greater returns ascending).

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
    if (argc < 2) { std::fprintf(stderr, "usage: q25 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int32_t* event_time = gendb::mmap_col<int32_t>(dir, "EventTime");
    auto sp = gendb::mmap_strcol(dir, "SearchPhrase");

    // Row = (EventTime, row_index). Using std::greater as the heap's "Less"
    // gives a TopK that retains the 10 *smallest* EventTimes.
    using Row = std::pair<int32_t, int64_t>;
    using Cmp = std::greater<Row>;

    int T = omp_get_max_threads();
    std::vector<gendb::TopK<Row, Cmp>> per_thread;
    per_thread.reserve(T);
    for (int i = 0; i < T; ++i) per_thread.emplace_back(10);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        auto& tk = per_thread[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < sp.n; ++i) {
            // Skip empty SearchPhrase.
            if (sp.off[i + 1] == sp.off[i]) continue;
            tk.try_push(Row{event_time[i], i});
        }
    }

    // Merge per-thread heaps into a single global TopK.
    gendb::TopK<Row, Cmp> merged(10);
    for (auto& tk : per_thread) {
        for (auto& r : tk.heap) {
            merged.try_push(r);
        }
    }

    // sorted_desc() with Less = std::greater returns rows in ascending
    // EventTime order (smallest first).
    auto rows = merged.sorted_desc();

    std::printf("SearchPhrase\n");
    for (auto& r : rows) {
        int64_t i = r.second;
        uint64_t a = sp.off[i], b = sp.off[i + 1];
        std::fwrite(sp.data + a, 1, (size_t)(b - a), stdout);
        std::fputc('\n', stdout);
    }
    return 0;
}
