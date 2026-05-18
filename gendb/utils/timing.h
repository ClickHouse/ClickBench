// Wall-clock timing for per-query binaries. Each binary prints a single
// `time: <seconds>` line to stderr on exit; ./query parses the last line of
// stderr (per ClickBench convention) to record the run.
//
// Total wall-clock is measured from the binary's main() entry. Loading is
// part of the query — for an in-memory-after-restart engine like ours, the
// cold cycle's drop_caches eviction makes the first run reread columns from
// disk and the warm runs from pagecache, exactly the property ClickBench's
// cold/warm distinction is designed to expose.

#pragma once

#include <chrono>
#include <cstdio>

namespace gendb {

struct WallClock {
    std::chrono::steady_clock::time_point t0 = std::chrono::steady_clock::now();
    ~WallClock() {
        auto t1 = std::chrono::steady_clock::now();
        double secs = std::chrono::duration<double>(t1 - t0).count();
        // Bare decimal so the harness's `^[0-9]+(\.[0-9]+)?$` regex
        // picks it up as the last numeric line on stderr.
        std::fprintf(stderr, "%.6f\n", secs);
    }
};

}  // namespace gendb
