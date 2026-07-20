// Q19: SELECT UserID, extract(minute FROM EventTime) AS m, SearchPhrase,
//             COUNT(*)
//      FROM hits
//      GROUP BY UserID, m, SearchPhrase
//      ORDER BY COUNT(*) DESC
//      LIMIT 10;
//
// Strategy:
//   The grouping key is a composite of (int64 UserID, int8 minute-of-hour,
//   string SearchPhrase). The string component dominates cardinality, so we
//   reuse q13's open-addressing string-keyed hashtable shape and mix the
//   UserID and minute into the hash. The entry stores (hash, UserID, minute,
//   string-offset, string-length, count) and the equality check compares all
//   three components.
//
//   minute(EventTime) for a Unix epoch in seconds is (EventTime % 3600) / 60,
//   range [0, 59]. EventTime is int32 in storage.
//
//   Per-thread aggregation table; serial merge at the end; TopK by count.

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

namespace {

struct Entry {
    uint64_t hash;
    int64_t  user_id;
    uint32_t off_lo;  // offset into SearchPhrase _data.bin
    uint32_t off_hi;
    uint32_t len;
    int8_t   minute;
    int64_t  count;
};

// FNV-1a-style cheap hash on the string bytes; mixed with UserID and minute
// using gendb::mix64 so identical SearchPhrase but different UserID/minute
// land in different slots.
static inline uint64_t hash_bytes(const char* p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; ++i) {
        h ^= (uint8_t)p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

static inline uint64_t combine_hash(uint64_t str_hash, int64_t user_id, int8_t minute) {
    // Mix UserID and minute into the string hash. Multiplier is the
    // golden-ratio constant used in boost::hash_combine.
    uint64_t h = str_hash;
    h ^= gendb::mix64((uint64_t)user_id) + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
    h ^= gendb::mix64((uint64_t)(uint8_t)minute) + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
    return h;
}

struct CompMap {
    static constexpr size_t INIT_CAP = 1 << 15;
    std::vector<int32_t> slots;  // -1 = empty, else index into entries
    std::vector<Entry>   entries;
    size_t mask;
    size_t live = 0;

    CompMap() : slots(INIT_CAP, -1), entries(), mask(INIT_CAP - 1) {
        entries.reserve(4096);
    }

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

    // Find or insert the composite key (user_id, minute, [p, p+n)). On
    // insertion, the entry stores `row_off` so we can resolve the string
    // bytes later from the original data buffer.
    inline int64_t* find_or_insert(uint64_t h, int64_t user_id, int8_t minute,
                                   const char* p, size_t n,
                                   const char* data_base, uint64_t row_off) {
        size_t pos = h & mask;
        while (true) {
            int32_t idx = slots[pos];
            if (idx == -1) {
                Entry e;
                e.hash    = h;
                e.user_id = user_id;
                e.off_lo  = (uint32_t)(row_off & 0xffffffffu);
                e.off_hi  = (uint32_t)(row_off >> 32);
                e.len     = (uint32_t)n;
                e.minute  = minute;
                e.count   = 0;
                entries.push_back(e);
                slots[pos] = (int32_t)(entries.size() - 1);
                ++live;
                int64_t* ret = &entries.back().count;
                maybe_grow();
                // entries vector was not reallocated by maybe_grow (it only
                // rebuilds the slots index), so the pointer remains valid.
                return ret;
            }
            Entry& e = entries[idx];
            if (e.hash == h && e.user_id == user_id && e.minute == minute && e.len == n) {
                uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
                if (memcmp(data_base + off, p, n) == 0) return &e.count;
            }
            pos = (pos + 1) & mask;
        }
    }
};

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q19 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int32_t* et  = gendb::mmap_col<int32_t>(dir, "EventTime");
    const int64_t* uid = gendb::mmap_col<int64_t>(dir, "UserID");
    auto sp = gendb::mmap_strcol(dir, "SearchPhrase");

    int T = omp_get_max_threads();
    std::vector<CompMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        CompMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            uint64_t a = sp.off[i], b = sp.off[i + 1];
            const char* p = sp.data + a;
            size_t n = (size_t)(b - a);
            int64_t user_id = uid[i];
            // minute-of-hour for a Unix epoch in seconds.
            int8_t minute = (int8_t)((et[i] % 3600) / 60);
            uint64_t sh = hash_bytes(p, n);
            uint64_t h = combine_hash(sh, user_id, minute);
            int64_t* cnt = m.find_or_insert(h, user_id, minute, p, n, sp.data, a);
            *cnt += 1;
        }
    }

    // Merge per-thread maps into one.
    CompMap merged;
    for (auto& m : maps) {
        for (auto& e : m.entries) {
            uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
            int64_t* tgt = merged.find_or_insert(e.hash, e.user_id, e.minute,
                                                 sp.data + off, e.len,
                                                 sp.data, off);
            *tgt += e.count;
        }
        // Release per-thread memory eagerly.
        std::vector<int32_t>().swap(m.slots);
        std::vector<Entry>().swap(m.entries);
    }

    // TopK by count.
    using Row = std::pair<int64_t, int>;  // (count, index into merged.entries)
    gendb::TopK<Row> top(10);
    for (size_t i = 0; i < merged.entries.size(); ++i) {
        top.try_push({merged.entries[i].count, (int)i});
    }
    auto rows = top.sorted_desc();

    std::printf("UserID,m,SearchPhrase,c\n");
    for (auto& r : rows) {
        const Entry& e = merged.entries[r.second];
        uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
        std::printf("%lld,%d,", (long long)e.user_id, (int)e.minute);
        std::fwrite(sp.data + off, 1, e.len, stdout);
        std::printf(",%lld\n", (long long)r.first);
    }
    return 0;
}
