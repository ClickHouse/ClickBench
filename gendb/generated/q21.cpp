// Q21: SELECT COUNT(*) FROM hits WHERE URL LIKE '%google%';
//
// mmap the URL string column (offsets + data) and parallel-scan all rows,
// using memmem-based gendb::str_contains to test whether the byte range
// for each row contains the literal "google". Reduce per-thread match
// counts into a single int64 via OpenMP reduction.

#include "../utils/storage.h"
#include "../utils/timing.h"

#include <cstdint>
#include <cstdio>
#include <omp.h>
#include <string>

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q21 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];
    gendb::StrCol url = gendb::mmap_strcol(dir, "URL");

    static constexpr char PAT[] = "google";
    static constexpr size_t PLEN = sizeof(PAT) - 1;

    int64_t total = 0;
    #pragma omp parallel for reduction(+:total) schedule(static)
    for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
        total += gendb::str_contains(url, i, PAT, PLEN);
    }
    std::printf("count\n%lld\n", (long long)total);
    return 0;
}
