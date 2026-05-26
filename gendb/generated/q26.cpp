// Q26: SELECT SearchPhrase FROM hits WHERE SearchPhrase <> ''
//      ORDER BY SearchPhrase LIMIT 10;
//
// Strategy:
//   - Parallel scan; per-thread TopK<RowRef> of size 10 keyed by the byte
//     range of SearchPhrase, comparing with memcmp.
//   - We want the 10 lex-SMALLEST strings. TopK keeps the K largest under
//     `Less`, so define Less(a, b) := "a is lex-greater than b". The heap
//     root is then the largest-so-far candidate; when we see a smaller one
//     we pop+replace, which converges to the K smallest seen.
//   - String memory is the mmap'd data buffer; RowRef just stores the
//     (offset, len) pair into it. memcmp on those byte ranges does the work.
//   - Final merge: union per-thread top-10 lists, re-run them through one
//     TopK, then sort the 10 results lex-ASCENDING for printing.
//
// Note: SearchPhrase is mmap'd PROT_READ for the program's lifetime, so
// raw (offset, len) pointers into it are stable for the duration.

#include "../utils/storage.h"
#include "../utils/timing.h"
#include "../utils/topn.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <omp.h>
#include <string>
#include <vector>

namespace {

struct RowRef {
    uint64_t off;
    uint32_t len;
};

// Compare two byte ranges in the same data buffer; returns <0, 0, >0 as memcmp.
static inline int cmp_ref(const char* base, const RowRef& a, const RowRef& b) {
    size_t m = a.len < b.len ? a.len : b.len;
    int c = std::memcmp(base + a.off, base + b.off, m);
    if (c != 0) return c;
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

// Less functor used by TopK. "a < b" iff a is lexicographically GREATER than
// b. The heap root is then the lex-largest candidate; when we encounter a
// row that is lex-smaller than the root, we replace the root. Over the full
// scan this converges to the 10 lex-smallest distinct rows we've seen.
struct RefGreaterLess {
    const char* base;
    bool operator()(const RowRef& a, const RowRef& b) const {
        return cmp_ref(base, a, b) > 0;
    }
};

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q26 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    auto sp = gendb::mmap_strcol(dir, "SearchPhrase");
    const char* base = sp.data;

    int T = omp_get_max_threads();
    std::vector<std::vector<RowRef>> per_thread_top(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        RefGreaterLess less{base};
        gendb::TopK<RowRef, RefGreaterLess> top(10, less);

        #pragma omp for schedule(static)
        for (int64_t i = 0; i < sp.n; ++i) {
            uint64_t a = sp.off[i], b = sp.off[i + 1];
            if (a == b) continue;  // skip empty SearchPhrase
            RowRef r{a, (uint32_t)(b - a)};
            top.try_push(r);
        }

        per_thread_top[tid] = std::move(top.heap);
    }

    // Merge: push each thread's candidates through one more TopK.
    RefGreaterLess less{base};
    gendb::TopK<RowRef, RefGreaterLess> merged(10, less);
    for (auto& v : per_thread_top) {
        for (auto& r : v) merged.try_push(r);
    }

    // Re-sort the surviving 10 candidates lex-ASCENDING for final output.
    std::vector<RowRef> out = merged.heap;
    std::sort(out.begin(), out.end(), [base](const RowRef& a, const RowRef& b) {
        return cmp_ref(base, a, b) < 0;
    });

    std::printf("SearchPhrase\n");
    for (auto& r : out) {
        std::fwrite(base + r.off, 1, r.len, stdout);
        std::fputc('\n', stdout);
    }
    return 0;
}
