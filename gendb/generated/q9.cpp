// Q9: SELECT RegionID, COUNT(DISTINCT UserID) AS u FROM hits
//     GROUP BY RegionID ORDER BY u DESC LIMIT 10;
//
// Shape: a COUNT(DISTINCT) per group. RegionID is int32 with a moderate
// cardinality (tens of thousands in practice) while UserID is int64 with
// very high cardinality. A flat-array-per-region hashset is the natural
// data structure: maintain one open-addressing I64Set per RegionID and
// insert UserID into the appropriate set.
//
// Parallelism:
//   1. Per-thread: HashMap<int32 RegionID, I64Set*> + a vector of owned
//      I64Set objects (heap-allocated so growth of the map's value vector
//      can move pointers around without disturbing the sets themselves).
//   2. After the scan, merge each thread's per-region sets into a single
//      RegionID -> I64Set* map (union of the UserID sets).
//   3. TopK by .live count.
//
// The hot loop is one int32 read + one int64 read + a map probe + a hashset
// probe; both probes are open-addressing with mix32/mix64.

#include "../utils/storage.h"
#include "../utils/timing.h"
#include "../utils/hashmap.h"
#include "../utils/topn.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <climits>
#include <memory>
#include <omp.h>
#include <string>
#include <vector>

namespace {

// Open-addressing hashset on int64. Sentinel for empty: INT64_MIN (UserID
// values are positive in this dataset). Same shape as Q5's I64Set.
struct I64Set {
    std::vector<int64_t> slots;
    size_t mask;
    size_t live = 0;
    static constexpr int64_t EMPTY = INT64_MIN;

    explicit I64Set(size_t cap_pow2) : slots(cap_pow2, EMPTY), mask(cap_pow2 - 1) {}

    inline bool insert(int64_t v) {
        if (v == EMPTY) v = EMPTY + 1;
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

// Per-thread structure: a hashmap RegionID -> I64Set* with sentinel INT32_MIN.
// We can't use gendb::HashMap directly because its `vals` vector stores V by
// value and reallocates on grow; storing raw pointers there is fine (we
// re-locate by probing) and the pointed-to I64Set objects live in a separate
// owner vector that uses unique_ptr so addresses don't move on push_back.
struct RegionMap {
    static constexpr int32_t EMPTY_RID = INT32_MIN;
    std::vector<int32_t>   keys;
    std::vector<I64Set*>   vals;
    std::vector<std::unique_ptr<I64Set>> owned;
    size_t mask;
    size_t count = 0;

    explicit RegionMap(size_t cap_pow2 = 1 << 12)
        : keys(cap_pow2, EMPTY_RID), vals(cap_pow2, nullptr), mask(cap_pow2 - 1) {
        owned.reserve(1024);
    }

    inline I64Set* get_or_create(int32_t rid) {
        // Remap the (unlikely) sentinel collision so RegionID == INT32_MIN
        // still works. ClickBench's RegionID is non-negative anyway.
        int32_t k = (rid == EMPTY_RID) ? (EMPTY_RID + 1) : rid;
        size_t pos = gendb::mix32((uint32_t)k) & mask;
        while (true) {
            int32_t kp = keys[pos];
            if (kp == EMPTY_RID) {
                // Insert
                owned.emplace_back(new I64Set(1 << 10));  // 1024 initial slots per region
                I64Set* s = owned.back().get();
                keys[pos] = k;
                vals[pos] = s;
                ++count;
                if (count * 2 > keys.size()) {
                    grow();
                    // After grow, the I64Set pointer is unchanged (we only
                    // moved keys/vals around); the set we just created is
                    // findable by probing again.
                }
                return s;
            }
            if (kp == k) return vals[pos];
            pos = (pos + 1) & mask;
        }
    }

    void grow() {
        std::vector<int32_t> ok = std::move(keys);
        std::vector<I64Set*> ov = std::move(vals);
        size_t newcap = ok.size() * 2;
        keys.assign(newcap, EMPTY_RID);
        vals.assign(newcap, nullptr);
        mask = newcap - 1;
        for (size_t i = 0; i < ok.size(); ++i) {
            int32_t kp = ok[i];
            if (kp == EMPTY_RID) continue;
            size_t pos = gendb::mix32((uint32_t)kp) & mask;
            while (keys[pos] != EMPTY_RID) pos = (pos + 1) & mask;
            keys[pos] = kp;
            vals[pos] = ov[i];
        }
    }
};

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q9 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];
    const int32_t* rid = gendb::mmap_col<int32_t>(dir, "RegionID");
    const int64_t* uid = gendb::mmap_col<int64_t>(dir, "UserID");

    int T = omp_get_max_threads();
    std::vector<RegionMap> per_thread(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        RegionMap& rm = per_thread[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            I64Set* s = rm.get_or_create(rid[i]);
            s->insert(uid[i]);
        }
    }

    // Merge: build a single RegionID -> merged I64Set* map, unioning each
    // thread-local set's contents in.
    RegionMap merged(1 << 14);
    for (int t = 0; t < T; ++t) {
        RegionMap& src = per_thread[t];
        for (size_t i = 0; i < src.keys.size(); ++i) {
            int32_t k = src.keys[i];
            if (k == RegionMap::EMPTY_RID) continue;
            // Restore the original RegionID in case it was the remapped sentinel
            // value. (Only matters if RegionID actually equals INT32_MIN, which
            // shouldn't happen, but we keep the symmetry.)
            int32_t orig = k;
            I64Set* src_set = src.vals[i];
            I64Set* dst_set = merged.get_or_create(orig);
            // Union: iterate src slots and insert into dst.
            for (int64_t v : src_set->slots) {
                if (v != I64Set::EMPTY) dst_set->insert(v);
            }
        }
    }

    // TopK by distinct UserID count per region.
    using Row = std::pair<int64_t, int32_t>;  // (u, RegionID)
    gendb::TopK<Row> top(10);
    for (size_t i = 0; i < merged.keys.size(); ++i) {
        int32_t k = merged.keys[i];
        if (k == RegionMap::EMPTY_RID) continue;
        int64_t u = (int64_t)merged.vals[i]->live;
        top.try_push({u, k});
    }
    auto rows = top.sorted_desc();

    std::printf("RegionID,u\n");
    for (auto& r : rows) {
        std::printf("%d,%lld\n", (int)r.second, (long long)r.first);
    }
    return 0;
}
