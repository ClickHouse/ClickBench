// Q12: SELECT MobilePhone, MobilePhoneModel, COUNT(DISTINCT UserID) AS u
//      FROM hits
//      WHERE MobilePhoneModel <> ''
//      GROUP BY MobilePhone, MobilePhoneModel
//      ORDER BY u DESC LIMIT 10;
//
// Inner-loop strategy (cf. q13 for the string-keyed pattern, q5 for the
// distinct-UserID hashset):
//   1. Per-row, skip rows where MobilePhoneModel is empty.
//   2. Build a composite 64-bit hash:
//        h = mix64(MobilePhone) ^ fnv1a(MobilePhoneModel)
//      This lets us probe a single open-addressing slot for the (phone,
//      model) group without materializing an actual concatenated key.
//   3. Each map entry holds (hash, phone, model_off, model_len) plus an
//      embedded open-addressing int64 hashset of UserIDs — distinct
//      UserID count is just `users.live`.
//   4. Per-thread maps; serial merge at the end (union of distinct UserIDs
//      across threads). Final TopK by users.live.

#include "../utils/storage.h"
#include "../utils/timing.h"
#include "../utils/hashmap.h"
#include "../utils/topn.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <omp.h>
#include <string>
#include <vector>

// Per-group hashset of seen UserIDs. UserID is int64 and positive in this
// dataset, so INT64_MIN is a safe empty sentinel (q5 uses the same trick).
struct UidSet {
    std::vector<int64_t> slots;
    size_t mask;
    size_t live = 0;
    static constexpr int64_t EMPTY = INT64_MIN;

    UidSet() : slots(8, EMPTY), mask(7) {}

    inline void insert(int64_t v) {
        if (v == EMPTY) v = EMPTY + 1;
        if ((live + 1) * 2 > slots.size()) grow();
        size_t pos = gendb::mix64((uint64_t)v) & mask;
        while (true) {
            int64_t s = slots[pos];
            if (s == EMPTY) { slots[pos] = v; ++live; return; }
            if (s == v) return;
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

struct Entry {
    uint64_t hash;     // composite hash: mix64(phone) ^ fnv1a(model_bytes)
    uint64_t str_hash; // fnv1a(model_bytes) alone, used to dedup the model
    uint32_t off_lo;
    uint32_t off_hi;
    uint32_t len;
    int16_t  phone;
    UidSet   users;
};

// FNV-1a on the model byte range — same family as q13's hash_bytes.
static inline uint64_t hash_bytes(const char* p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; ++i) {
        h ^= (uint8_t)p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

struct StrMap {
    static constexpr size_t INIT_CAP = 1 << 12;
    std::vector<int32_t> slots;  // -1 = empty, else index into entries
    std::vector<Entry>   entries;
    size_t mask;
    size_t live = 0;

    StrMap() : slots(INIT_CAP, -1), mask(INIT_CAP - 1) { entries.reserve(256); }

    void maybe_grow() {
        if (live * 2 <= slots.size()) return;
        size_t newcap = slots.size() * 2;
        std::vector<int32_t> ns(newcap, -1);
        size_t nm = newcap - 1;
        for (size_t i = 0; i < entries.size(); ++i) {
            uint64_t h = entries[i].hash;
            size_t pos = h & nm;
            while (ns[pos] != -1) pos = (pos + 1) & nm;
            ns[pos] = (int32_t)i;
        }
        slots = std::move(ns);
        mask = nm;
    }

    // Locate (or create) the entry for (phone, model_bytes) keyed by the
    // pre-computed composite hash `h` and the model's own `str_hash`. We
    // store `str_hash` so the merge step can re-feed the exact same hash
    // value into a fresh map without recomputing it from bytes.
    Entry* find_or_insert(uint64_t h, uint64_t str_hash,
                          int16_t phone,
                          const char* p, size_t n,
                          const char* data_base, uint64_t row_off) {
        size_t pos = h & mask;
        while (true) {
            int32_t idx = slots[pos];
            if (idx == -1) {
                Entry e;
                e.hash = h;
                e.str_hash = str_hash;
                e.off_lo = (uint32_t)(row_off & 0xffffffffu);
                e.off_hi = (uint32_t)(row_off >> 32);
                e.len = (uint32_t)n;
                e.phone = phone;
                entries.push_back(std::move(e));
                slots[pos] = (int32_t)(entries.size() - 1);
                ++live;
                Entry* ret = &entries.back();
                // maybe_grow only rebuilds `slots`, not `entries`, so the
                // pointer we just took remains valid. Any reallocation of
                // `entries` already happened inside push_back above.
                maybe_grow();
                return ret;
            }
            Entry& e = entries[idx];
            if (e.hash == h && e.phone == phone && e.len == n) {
                uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
                if (memcmp(data_base + off, p, n) == 0) return &e;
            }
            pos = (pos + 1) & mask;
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q12 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    auto mpm = gendb::mmap_strcol(dir, "MobilePhoneModel");
    const int16_t* mp  = gendb::mmap_col<int16_t>(dir, "MobilePhone");
    const int64_t* uid = gendb::mmap_col<int64_t>(dir, "UserID");

    int T = omp_get_max_threads();
    std::vector<StrMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        StrMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < mpm.n; ++i) {
            uint64_t a = mpm.off[i], b = mpm.off[i + 1];
            if (a == b) continue;  // MobilePhoneModel <> ''
            const char* p = mpm.data + a;
            size_t n = (size_t)(b - a);
            int16_t phone = mp[i];
            uint64_t sh = hash_bytes(p, n);
            uint64_t h  = gendb::mix64((uint64_t)(uint16_t)phone) ^ sh;
            Entry* e = m.find_or_insert(h, sh, phone, p, n, mpm.data, a);
            e->users.insert(uid[i]);
        }
    }

    // Merge per-thread maps. We union the UserID sets per (phone, model)
    // group so that COUNT(DISTINCT UserID) is correct across threads.
    StrMap merged;
    for (auto& m : maps) {
        for (auto& e : m.entries) {
            uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
            Entry* tgt = merged.find_or_insert(
                e.hash, e.str_hash, e.phone,
                mpm.data + off, e.len, mpm.data, off);
            for (int64_t v : e.users.slots) {
                if (v != UidSet::EMPTY) tgt->users.insert(v);
            }
        }
    }

    // TopK by distinct user count.
    using Row = std::pair<int64_t, int>;  // (u, index into merged.entries)
    gendb::TopK<Row> top(10);
    for (size_t i = 0; i < merged.entries.size(); ++i) {
        top.try_push({(int64_t)merged.entries[i].users.live, (int)i});
    }
    auto rows = top.sorted_desc();

    std::printf("MobilePhone,MobilePhoneModel,u\n");
    for (auto& r : rows) {
        auto& e = merged.entries[r.second];
        uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
        std::printf("%d,", (int)e.phone);
        std::fwrite(mpm.data + off, 1, e.len, stdout);
        std::printf(",%lld\n", (long long)r.first);
    }
    return 0;
}
