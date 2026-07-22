// Q7: SELECT MIN(EventDate), MAX(EventDate) FROM hits;
//
// EventDate is int32 days-since-epoch (1970-01-01). Single linear scan with
// a parallel min/max reduction over 96 cores. ~400 MB column, so the scan is
// memory-bandwidth bound; OpenMP's built-in min/max reductions give us
// per-thread locals merged at the end with no atomics in the hot loop.

#include "../utils/storage.h"
#include "../utils/timing.h"

#include <cstdint>
#include <cstdio>
#include <limits>
#include <omp.h>
#include <string>

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q7 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];
    const int32_t* ed = gendb::mmap_col<int32_t>(dir, "EventDate");

    int32_t mn = std::numeric_limits<int32_t>::max();
    int32_t mx = std::numeric_limits<int32_t>::min();
    #pragma omp parallel for reduction(min:mn) reduction(max:mx) schedule(static)
    for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
        int32_t v = ed[i];
        if (v < mn) mn = v;
        if (v > mx) mx = v;
    }
    std::printf("mn,mx\n%d,%d\n", (int)mn, (int)mx);
    return 0;
}
