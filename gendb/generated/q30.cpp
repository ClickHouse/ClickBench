// Q30: SELECT SUM(ResolutionWidth + 0), SUM(ResolutionWidth + 1), ...,
//                 SUM(ResolutionWidth + 89) FROM hits;
//
// Algebraic identity: SUM(rw + k) = SUM(rw) + k * N, where N is the row
// count of the (non-null) ResolutionWidth column. ResolutionWidth is
// densely populated int16, so N == HITS_ROWS. We therefore do a single
// parallel scan to compute SUM(rw) and derive all 90 outputs in O(1).

#include "../utils/storage.h"
#include "../utils/timing.h"

#include <cstdint>
#include <cstdio>
#include <omp.h>
#include <string>

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q30 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];
    const int16_t* rw = gendb::mmap_col<int16_t>(dir, "ResolutionWidth");

    int64_t sum_rw = 0;
    #pragma omp parallel for reduction(+:sum_rw) schedule(static)
    for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
        sum_rw += rw[i];
    }

    // Emit header s0,s1,...,s89.
    for (int k = 0; k < 90; ++k) {
        std::printf("%ss%d", (k == 0 ? "" : ","), k);
    }
    std::printf("\n");

    // SUM(rw + k) = sum_rw + k * HITS_ROWS.
    const int64_t N = gendb::HITS_ROWS;
    for (int k = 0; k < 90; ++k) {
        int64_t v = sum_rw + (int64_t)k * N;
        std::printf("%s%lld", (k == 0 ? "" : ","), (long long)v);
    }
    std::printf("\n");
    return 0;
}
