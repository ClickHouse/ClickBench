// Q20: SELECT UserID FROM hits WHERE UserID = 435090932899640449;
//
// Parallel scan over UserID (int64, ~800 MB). For a specific UserID the
// match count is tiny relative to 100M rows, so per-thread std::vector
// append + serial concat is cheap. The hot loop is a straight equality
// check; branch predictor wins because matches are extremely rare.

#include "../utils/storage.h"
#include "../utils/timing.h"

#include <cstdint>
#include <cstdio>
#include <omp.h>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q20 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];
    const int64_t* uid = gendb::mmap_col<int64_t>(dir, "UserID");

    constexpr int64_t TARGET = 435090932899640449LL;

    int nthreads = 1;
    #pragma omp parallel
    {
        #pragma omp single
        nthreads = omp_get_num_threads();
    }

    std::vector<std::vector<int64_t>> partials(nthreads);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        std::vector<int64_t>& local = partials[tid];
        local.reserve(64);
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            if (uid[i] == TARGET) {
                local.push_back(uid[i]);
            }
        }
    }

    std::printf("UserID\n");
    for (const auto& v : partials) {
        for (int64_t x : v) {
            std::printf("%lld\n", (long long)x);
        }
    }
    return 0;
}
