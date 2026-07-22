// Q27: SELECT SearchPhrase FROM hits
//      WHERE SearchPhrase <> ''
//      ORDER BY EventTime, SearchPhrase LIMIT 10;
//
// Strategy:
//   1. Parallel scan over all rows. Skip empty SearchPhrase
//      (off[i+1] == off[i]).
//   2. Per-thread TopK of size 10 retaining the 10 lex-smallest
//      (EventTime, SearchPhrase) pairs. The element type stores
//      (EventTime, row_index); SearchPhrase bytes are fetched from the
//      mmap'd column on demand using row_index, both during the heap
//      compare and at output time.
//   3. The heap's Less comparator returns "a is lex-GREATER than b"
//      under the ordering (EventTime asc, then SearchPhrase asc). With
//      that, gendb::TopK keeps the 10 lex-smallest rows (the "largest
//      by greater" = smallest by less semantics).
//   4. On EventTime ties we memcmp the two SearchPhrase byte ranges.
//   5. Merge per-thread heaps into a global TopK and emit ascending.

#include "../utils/storage.h"
#include "../utils/timing.h"
#include "../utils/topn.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <omp.h>
#include <string>
#include <utility>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q27 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int32_t* event_time = gendb::mmap_col<int32_t>(dir, "EventTime");
    auto sp = gendb::mmap_strcol(dir, "SearchPhrase");

    // Row = (EventTime, row_index). The Less functor encodes
    // "a is lex-bigger than b" under (EventTime asc, SearchPhrase asc).
    // TopK retains the largest-by-this-Less entries, i.e. the lex-smallest
    // (EventTime, SearchPhrase) tuples.
    using Row = std::pair<int32_t, int64_t>;

    struct LexGreater {
        const uint64_t* off;
        const char*     data;
        // Returns true if `a` is "bigger than" `b` under (EventTime asc,
        // SearchPhrase asc) ordering — i.e. a should be ranked ABOVE b
        // in the TopK heap, so that b (the lex-smaller one) is kept when
        // it competes with a.
        //
        // Equivalent to: return tuple(a.EventTime, a.SearchPhrase)
        //                       >  tuple(b.EventTime, b.SearchPhrase).
        inline bool operator()(const Row& a, const Row& b) const {
            if (a.first != b.first) return a.first > b.first;
            // EventTime tie — compare SearchPhrase bytes lexicographically.
            uint64_t aa = off[a.second], ab = off[a.second + 1];
            uint64_t ba = off[b.second], bb = off[b.second + 1];
            size_t alen = (size_t)(ab - aa);
            size_t blen = (size_t)(bb - ba);
            size_t m = alen < blen ? alen : blen;
            int c = std::memcmp(data + aa, data + ba, m);
            if (c != 0) return c > 0;
            return alen > blen;
        }
    };

    LexGreater cmp{sp.off, sp.data};

    int T = omp_get_max_threads();
    std::vector<gendb::TopK<Row, LexGreater>> per_thread;
    per_thread.reserve(T);
    for (int i = 0; i < T; ++i) per_thread.emplace_back(10, cmp);

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
    gendb::TopK<Row, LexGreater> merged(10, cmp);
    for (auto& tk : per_thread) {
        for (auto& r : tk.heap) {
            merged.try_push(r);
        }
    }

    // sorted_desc() with Less = LexGreater returns rows in ascending
    // (EventTime, SearchPhrase) order — i.e. smallest first.
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
