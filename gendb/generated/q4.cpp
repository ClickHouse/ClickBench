// Q4: SELECT AVG(UserID) FROM hits;
//
// UserID is int64; the sum easily exceeds int64 range (mean ~1e18, N=1e8
// → sum ~1e26). Switch to long double accumulation per thread to retain
// precision, then reduce.

#include "../utils/storage.h"
#include "../utils/timing.h"

#include <cstdint>
#include <cstdio>
#include <omp.h>
#include <string>

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q4 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];
    const int64_t* uid = gendb::mmap_col<int64_t>(dir, "UserID");

    long double sum = 0.0L;
    #pragma omp parallel for reduction(+:sum) schedule(static)
    for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
        sum += (long double)uid[i];
    }
    double avg = (double)(sum / (long double)gendb::HITS_ROWS);
    std::printf("avg_userid\n%.6f\n", avg);
    return 0;
}
