// Q8: SELECT AdvEngineID, COUNT(*) FROM hits WHERE AdvEngineID <> 0
//     GROUP BY AdvEngineID ORDER BY COUNT(*) DESC;
//
// AdvEngineID is int16. Distinct value space is small (the column is densely
// 0 with a handful of small enum codes), so a 65,536-bucket flat array is
// the right hash table — no hashing, no probing, one indexed write per row.
// We accumulate per-thread buckets and combine in a serial reduce afterward.

#include "../utils/storage.h"
#include "../utils/timing.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <omp.h>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q8 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];
    const int16_t* aei = gendb::mmap_col<int16_t>(dir, "AdvEngineID");

    constexpr int NBUCK = 65536;
    int T = omp_get_max_threads();
    std::vector<int64_t> all(NBUCK * T, 0);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        int64_t* my = all.data() + (size_t)tid * NBUCK;
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            // int16 to uint16 cast preserves bits → safe direct index.
            uint16_t v = (uint16_t)aei[i];
            my[v] += 1;
        }
    }
    // Merge — only need totals where aei != 0.
    std::vector<std::pair<int32_t, int64_t>> rows;
    rows.reserve(64);
    for (int v = 1; v < NBUCK; ++v) {
        int64_t c = 0;
        for (int t = 0; t < T; ++t) c += all[(size_t)t * NBUCK + v];
        if (c > 0) {
            // Reinterpret v as the signed int16 the column actually stored.
            int16_t signed_v = (int16_t)v;
            rows.emplace_back((int32_t)signed_v, c);
        }
    }
    std::sort(rows.begin(), rows.end(),
              [](const auto& a, const auto& b) { return a.second > b.second; });

    std::printf("AdvEngineID,c\n");
    for (auto& r : rows) std::printf("%d,%lld\n", r.first, (long long)r.second);
    return 0;
}
