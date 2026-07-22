// Q3: SELECT SUM(AdvEngineID), COUNT(*), AVG(ResolutionWidth) FROM hits;
//
// Three-way reduction over the whole table. We scan two columns in parallel.

#include "../utils/storage.h"
#include "../utils/timing.h"

#include <cstdint>
#include <cstdio>
#include <omp.h>
#include <string>

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q3 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];
    const int16_t* aei = gendb::mmap_col<int16_t>(dir, "AdvEngineID");
    const int16_t* rw  = gendb::mmap_col<int16_t>(dir, "ResolutionWidth");

    int64_t sum_aei = 0, sum_rw = 0;
    #pragma omp parallel for reduction(+:sum_aei,sum_rw) schedule(static)
    for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
        sum_aei += aei[i];
        sum_rw  += rw[i];
    }
    double avg = (double)sum_rw / (double)gendb::HITS_ROWS;
    std::printf("sum_aei,c,avg_rw\n%lld,%lld,%.6f\n",
                (long long)sum_aei, (long long)gendb::HITS_ROWS, avg);
    return 0;
}
