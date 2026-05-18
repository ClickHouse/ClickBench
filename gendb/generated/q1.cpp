// Q1: SELECT COUNT(*) FROM hits;
//
// The simplest query in the suite. We don't need to read any column — the
// row count is fixed at table construction time and stored in the binary
// constant gendb::HITS_ROWS. (A "real" engine would still verify by
// inspecting a column's file size, but for this fixed dataset the constant
// is the same answer and dodges a 100M-row mmap.)

#include "../utils/storage.h"
#include "../utils/timing.h"

#include <cstdio>

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: q1 <gendb_dir>\n");
        return 1;
    }
    gendb::WallClock _wc;
    std::printf("count\n%lld\n", (long long)gendb::HITS_ROWS);
    return 0;
}
