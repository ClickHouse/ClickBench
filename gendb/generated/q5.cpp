// Q5: SELECT COUNT(DISTINCT UserID) FROM hits;
//
// UserID is int64 with high cardinality. We accumulate seen IDs in a
// per-thread open-addressing hashset, then merge thread-local sets. The
// final answer is the union's size — no need to materialize the set, just
// count distinct insertions.

#include "../utils/storage.h"
#include "../utils/timing.h"
#include "../utils/hashmap.h"

#include <cstdint>
#include <cstdio>
#include <omp.h>
#include <string>
#include <vector>

// Open-addressing hashset on int64. Sentinel for empty: INT64_MIN (UserID
// values are positive in this dataset).
struct I64Set {
    std::vector<int64_t> slots;
    size_t mask;
    size_t live = 0;
    static constexpr int64_t EMPTY = INT64_MIN;

    explicit I64Set(size_t cap_pow2) : slots(cap_pow2, EMPTY), mask(cap_pow2 - 1) {}

    inline bool insert(int64_t v) {
        if (v == EMPTY) v = EMPTY + 1;  // remap the one collision value
        size_t pos = gendb::mix64((uint64_t)v) & mask;
        while (true) {
            int64_t s = slots[pos];
            if (s == EMPTY) {
                slots[pos] = v;
                ++live;
                if (live * 2 > slots.size()) grow();
                return true;
            }
            if (s == v) return false;
            pos = (pos + 1) & mask;
        }
    }

    void grow() {
        std::vector<int64_t> old = std::move(slots);
        size_t newcap = old.size() * 2;
        slots.assign(newcap, EMPTY);
        mask = newcap - 1;
        live = 0;
        for (int64_t v : old) {
            if (v != EMPTY) {
                size_t pos = gendb::mix64((uint64_t)v) & mask;
                while (slots[pos] != EMPTY) pos = (pos + 1) & mask;
                slots[pos] = v;
                ++live;
            }
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q5 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];
    const int64_t* uid = gendb::mmap_col<int64_t>(dir, "UserID");

    int T = omp_get_max_threads();
    std::vector<I64Set> sets;
    sets.reserve(T);
    for (int i = 0; i < T; ++i) sets.emplace_back(1 << 18);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        I64Set& s = sets[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            s.insert(uid[i]);
        }
    }

    // Merge: union all thread-local sets into one.
    I64Set merged(1 << 20);
    for (auto& s : sets) {
        for (int64_t v : s.slots) {
            if (v != I64Set::EMPTY) merged.insert(v);
        }
    }
    std::printf("ndv\n%zu\n", merged.live);
    return 0;
}
