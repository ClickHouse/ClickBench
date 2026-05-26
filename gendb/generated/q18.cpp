// Q18: SELECT UserID, SearchPhrase, COUNT(*) FROM hits
//      GROUP BY UserID, SearchPhrase LIMIT 10;
//
// Same shape as Q17 but no ORDER BY — we just need any 10 distinct
// (UserID, SearchPhrase) groups and their counts. ClickBench accepts any
// 10 since the SQL is non-deterministic without ORDER BY.
//
// Strategy:
//   1. Per-thread open-addressing hashmap keyed on (UserID, SearchPhrase).
//      We hash the int64 UserID combined with the byte range of the
//      SearchPhrase column. Entries store (hash, userid, str_offset,
//      str_len, count). On collision, compare userid AND memcmp the bytes.
//   2. Parallel scan over 100M rows, increment counts in the per-thread map.
//   3. Serial merge into one map.
//   4. Take the first 10 live entries from the merged map (any 10 — no sort).
//
// Composite key hashing: mix64(UserID) ^ (fnv1a(bytes) * golden_ratio). This
// avoids the trivial (a, b) ↔ (b, a) collision and keeps the inner-loop hash
// cost low for short search phrases.

#include "../utils/storage.h"
#include "../utils/timing.h"
#include "../utils/hashmap.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <omp.h>
#include <string>
#include <vector>

namespace {

struct Entry {
    uint64_t hash;
    int64_t  userid;
    uint32_t off_lo;   // low 32 bits of the SearchPhrase data offset
    uint32_t off_hi;
    uint32_t len;
    int64_t  count;
};

// FNV-1a over a byte range — search phrases are typically <50 bytes so the
// per-call cost is small compared to the L3-miss probe.
static inline uint64_t hash_bytes(const char* p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; ++i) {
        h ^= (uint8_t)p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

static inline uint64_t combine_hash(int64_t userid, uint64_t str_hash) {
    return gendb::mix64((uint64_t)userid) ^ (str_hash * 0x9e3779b97f4a7c15ULL);
}

// Open-addressing map keyed on (UserID, SearchPhrase bytes). Linear probing,
// load factor capped at 0.5. slots[] indirects to entries[] so that growth
// only rebuilds the slot index — entry pointers stay stable.
struct GroupMap {
    static constexpr size_t INIT_CAP = 1 << 14;
    std::vector<int32_t> slots;
    std::vector<Entry>   entries;
    size_t mask;
    size_t live = 0;

    GroupMap() : slots(INIT_CAP, -1), mask(INIT_CAP - 1) { entries.reserve(1024); }

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

    // Find-or-insert a (userid, bytes) group. Returns a pointer to the count.
    // `data_base` is the SearchPhrase data buffer used to resolve stored
    // offsets when comparing on collisions; `row_off` is the offset of the
    // probe key bytes within that same buffer (so we can store it on insert).
    int64_t* find_or_insert(uint64_t h, int64_t userid,
                            const char* p, size_t n,
                            const char* data_base, uint64_t row_off) {
        size_t pos = h & mask;
        while (true) {
            int32_t idx = slots[pos];
            if (idx == -1) {
                Entry e;
                e.hash = h;
                e.userid = userid;
                e.off_lo = (uint32_t)(row_off & 0xffffffffu);
                e.off_hi = (uint32_t)(row_off >> 32);
                e.len = (uint32_t)n;
                e.count = 0;
                entries.push_back(e);
                slots[pos] = (int32_t)(entries.size() - 1);
                ++live;
                int64_t* ret = &entries.back().count;
                maybe_grow();
                return ret;
            }
            Entry& e = entries[idx];
            if (e.hash == h && e.userid == userid && e.len == n) {
                uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
                if (memcmp(data_base + off, p, n) == 0) return &e.count;
            }
            pos = (pos + 1) & mask;
        }
    }
};

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q18 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int64_t* uid = gendb::mmap_col<int64_t>(dir, "UserID");
    auto sp = gendb::mmap_strcol(dir, "SearchPhrase");

    int T = omp_get_max_threads();
    std::vector<GroupMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        GroupMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            uint64_t a = sp.off[i], b = sp.off[i + 1];
            const char* p = sp.data + a;
            size_t n = (size_t)(b - a);
            uint64_t sh = hash_bytes(p, n);
            uint64_t h  = combine_hash(uid[i], sh);
            int64_t* cnt = m.find_or_insert(h, uid[i], p, n, sp.data, a);
            *cnt += 1;
        }
    }

    // Serial merge into a single map. We don't need to keep merging once we
    // already have 10 live groups for the no-ORDER-BY case, but merging the
    // full thing is cheap relative to the scan and keeps the output stable
    // across runs.
    GroupMap merged;
    for (auto& m : maps) {
        for (auto& e : m.entries) {
            uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
            int64_t* tgt = merged.find_or_insert(
                e.hash, e.userid, sp.data + off, e.len, sp.data, off);
            *tgt += e.count;
        }
    }

    // Take the first 10 entries — no ORDER BY, any 10 is correct.
    size_t out_n = std::min<size_t>(10, merged.entries.size());
    std::printf("UserID,SearchPhrase,c\n");
    for (size_t i = 0; i < out_n; ++i) {
        const Entry& e = merged.entries[i];
        uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
        std::printf("%lld,", (long long)e.userid);
        std::fwrite(sp.data + off, 1, e.len, stdout);
        std::printf(",%lld\n", (long long)e.count);
    }
    return 0;
}
