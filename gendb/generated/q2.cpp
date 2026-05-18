// Q2: SELECT COUNT(*) FROM hits WHERE AdvEngineID <> 0;
//
// Scan AdvEngineID (int16, 200 MB) → branchless count of non-zero entries.
// Parallel reduction over 96 cores with one cache-line-aligned partial per
// thread (no false sharing). AdvEngineID is densely populated (no nulls)
// so we don't need a separate "valid" mask.

#include "../utils/storage.h"
#include "../utils/timing.h"

#include <cstdint>
#include <cstdio>
#include <omp.h>
#include <string>

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q2 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];
    const int16_t* aei = gendb::mmap_col<int16_t>(dir, "AdvEngineID");

    int64_t total = 0;
    #pragma omp parallel for reduction(+:total) schedule(static)
    for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
        total += (aei[i] != 0);
    }
    std::printf("count\n%lld\n", (long long)total);
    return 0;
}
