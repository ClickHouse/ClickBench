// Q15: SELECT SearchEngineID, SearchPhrase, COUNT(*) AS c FROM hits
//      WHERE SearchPhrase <> ''
//      GROUP BY SearchEngineID, SearchPhrase
//      ORDER BY c DESC LIMIT 10;
//
// Composite-key variant of q13: the group is (int16 SearchEngineID,
// SearchPhrase bytes), and the aggregate is a plain COUNT(*) — no
// distinct-set bookkeeping, so this is simpler than q12.
//
// Inner-loop strategy:
//   1. Per-row, skip empty SearchPhrase.
//   2. Composite 64-bit hash = mix64(SearchEngineID) ^ fnv1a(SearchPhrase).
//   3. Per-thread open-addressing hashmap keyed by (hash, engine_id, off,
//      len). Increment count on hit, insert with count=1 on miss.
//   4. Serial merge of per-thread maps, then TopK by count.

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

struct Entry {
    uint64_t hash;     // composite hash: mix64(engine) ^ fnv1a(phrase_bytes)
    uint32_t off_lo;   // low 32 bits of phrase offset into data buffer
    uint32_t off_hi;
    uint32_t len;
    int16_t  engine;
    int64_t  count;
};

// FNV-1a on the phrase byte range — matches q13's hash_bytes.
static inline uint64_t hash_bytes(const char* p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; ++i) {
        h ^= (uint8_t)p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

struct StrMap {
    static constexpr size_t INIT_CAP = 1 << 14;
    std::vector<int32_t> slots;  // -1 = empty, else index into entries
    std::vector<Entry>   entries;
    size_t mask;
    size_t live = 0;

    StrMap() : slots(INIT_CAP, -1), mask(INIT_CAP - 1) { entries.reserve(1024); }

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

    // Locate (or create) the entry for (engine, phrase_bytes) keyed by the
    // pre-computed composite hash `h`. Returns a pointer to the count slot.
    int64_t* find_or_insert(uint64_t h,
                            int16_t engine,
                            const char* p, size_t n,
                            const char* data_base, uint64_t row_off) {
        size_t pos = h & mask;
        while (true) {
            int32_t idx = slots[pos];
            if (idx == -1) {
                Entry e;
                e.hash = h;
                e.off_lo = (uint32_t)(row_off & 0xffffffffu);
                e.off_hi = (uint32_t)(row_off >> 32);
                e.len = (uint32_t)n;
                e.engine = engine;
                e.count = 0;
                entries.push_back(e);
                slots[pos] = (int32_t)(entries.size() - 1);
                ++live;
                int64_t* ret = &entries.back().count;
                // maybe_grow only rebuilds `slots`, not `entries`, so the
                // pointer above stays valid. Any reallocation of `entries`
                // already happened inside push_back.
                maybe_grow();
                return ret;
            }
            Entry& e = entries[idx];
            if (e.hash == h && e.engine == engine && e.len == n) {
                uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
                if (memcmp(data_base + off, p, n) == 0) return &e.count;
            }
            pos = (pos + 1) & mask;
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q15 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    auto sp = gendb::mmap_strcol(dir, "SearchPhrase");
    const int16_t* sei = gendb::mmap_col<int16_t>(dir, "SearchEngineID");

    int T = omp_get_max_threads();
    std::vector<StrMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        StrMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < sp.n; ++i) {
            uint64_t a = sp.off[i], b = sp.off[i + 1];
            if (a == b) continue;  // SearchPhrase <> ''
            const char* p = sp.data + a;
            size_t n = (size_t)(b - a);
            int16_t engine = sei[i];
            uint64_t sh = hash_bytes(p, n);
            uint64_t h  = gendb::mix64((uint64_t)(uint16_t)engine) ^ sh;
            int64_t* cnt = m.find_or_insert(h, engine, p, n, sp.data, a);
            *cnt += 1;
        }
    }

    // Merge per-thread maps. Each entry's hash already encodes (engine, phrase)
    // so we re-feed it directly into the merged map.
    StrMap merged;
    for (auto& m : maps) {
        for (auto& e : m.entries) {
            uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
            int64_t* tgt = merged.find_or_insert(
                e.hash, e.engine, sp.data + off, e.len, sp.data, off);
            *tgt += e.count;
        }
    }

    // TopK by count.
    using Row = std::pair<int64_t, int>;  // (count, index into merged.entries)
    gendb::TopK<Row> top(10);
    for (size_t i = 0; i < merged.entries.size(); ++i) {
        top.try_push({merged.entries[i].count, (int)i});
    }
    auto rows = top.sorted_desc();

    std::printf("SearchEngineID,SearchPhrase,c\n");
    for (auto& r : rows) {
        auto& e = merged.entries[r.second];
        uint64_t off = ((uint64_t)e.off_hi << 32) | e.off_lo;
        std::printf("%d,", (int)e.engine);
        std::fwrite(sp.data + off, 1, e.len, stdout);
        std::printf(",%lld\n", (long long)r.first);
    }
    return 0;
}
