// Q29: SELECT REGEXP_REPLACE(Referer, '^https?://(?:www\.)?([^/]+)/.*$', '\1') AS k,
//             AVG(STRLEN(Referer)) AS l, COUNT(*) AS c, MIN(Referer)
//      FROM hits WHERE Referer <> ''
//      GROUP BY k HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25;
//
// Strategy:
//   1. Parallel scan over rows. For each non-empty Referer:
//      - Manually parse the host: skip "http://"/"https://", optional "www.",
//        then take bytes until first '/' or end. Skip row if no scheme prefix.
//      - Hash host byte range; find_or_insert into per-thread StrMap.
//      - Accumulate: sum of Referer length, count, MIN(Referer) (lex).
//   2. Merge per-thread maps serially.
//   3. Filter count > 100,000, sort by avg DESC, take top 25.
//   4. Emit k, l (avg), c, min_referer.

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

struct StrEntry {
    uint64_t hash;
    // Host key bytes live inside Referer_data; record an (offset,len) into it.
    uint64_t key_off;
    uint32_t key_len;
    // Aggregate state.
    uint64_t sum_len;   // sum of STRLEN(Referer)
    int64_t  count;
    // MIN(Referer) tracked as (offset,len) into Referer_data.
    uint64_t min_off;
    uint32_t min_len;
};

static inline uint64_t hash_bytes(const char* p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; ++i) {
        h ^= (uint8_t)p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

static inline bool lex_less(const char* a, size_t alen, const char* b, size_t blen) {
    size_t m = alen < blen ? alen : blen;
    int c = std::memcmp(a, b, m);
    if (c != 0) return c < 0;
    return alen < blen;
}

struct StrMap {
    static constexpr size_t INIT_CAP = 1 << 14;
    std::vector<int32_t> slots;
    std::vector<StrEntry> entries;
    size_t mask;
    size_t live = 0;

    StrMap() : slots(INIT_CAP, -1), entries(), mask(INIT_CAP - 1) { entries.reserve(1024); }

    void rehash_to(size_t newcap) {
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

    // Find by host bytes (p,n); insert if missing, initializing aggregate
    // state from the supplied row. Returns pointer to the entry.
    StrEntry* find_or_insert(uint64_t h, const char* p, size_t n,
                             const char* ref_data,
                             uint64_t key_row_off,
                             uint64_t ref_row_off,
                             uint32_t ref_row_len) {
        size_t pos = h & mask;
        while (true) {
            int32_t idx = slots[pos];
            if (idx == -1) {
                StrEntry e;
                e.hash = h;
                e.key_off = key_row_off;
                e.key_len = (uint32_t)n;
                e.sum_len = 0;
                e.count = 0;
                e.min_off = ref_row_off;
                e.min_len = ref_row_len;
                entries.push_back(e);
                slots[pos] = (int32_t)(entries.size() - 1);
                ++live;
                StrEntry* ret = &entries.back();
                if (live * 2 > slots.size()) {
                    rehash_to(slots.size() * 2);
                }
                return ret;
            }
            StrEntry& e = entries[idx];
            if (e.hash == h && e.key_len == n &&
                memcmp(ref_data + e.key_off, p, n) == 0) {
                return &e;
            }
            pos = (pos + 1) & mask;
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q29 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    gendb::StrCol ref = gendb::mmap_strcol(dir, "Referer");

    int T = omp_get_max_threads();
    std::vector<StrMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        StrMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < ref.n; ++i) {
            uint64_t a = ref.off[i], b = ref.off[i + 1];
            if (a == b) continue;  // empty Referer
            const char* p = ref.data + a;
            size_t n = (size_t)(b - a);

            // Parse scheme prefix.
            size_t pos = 0;
            if (n >= 7 && memcmp(p, "http://", 7) == 0) {
                pos = 7;
            } else if (n >= 8 && memcmp(p, "https://", 8) == 0) {
                pos = 8;
            } else {
                continue;  // no scheme — skip this row
            }
            // Optional "www." prefix.
            if (n - pos >= 4 && memcmp(p + pos, "www.", 4) == 0) {
                pos += 4;
            }
            // Host runs until first '/' or end.
            size_t host_start = pos;
            while (pos < n && p[pos] != '/') ++pos;
            size_t host_len = pos - host_start;

            const char* hp = p + host_start;
            uint64_t key_off = a + host_start;
            uint64_t h = hash_bytes(hp, host_len);

            StrEntry* e = m.find_or_insert(h, hp, host_len, ref.data,
                                           key_off, a, (uint32_t)n);
            e->sum_len += n;
            e->count   += 1;
            // Update MIN(Referer). On fresh insert min_off/min_len already
            // equal the current row, so the comparison is a no-op then.
            if (e->count > 1) {
                const char* cur = ref.data + e->min_off;
                if (lex_less(p, n, cur, e->min_len)) {
                    e->min_off = a;
                    e->min_len = (uint32_t)n;
                }
            }
        }
    }

    // Merge per-thread maps.
    StrMap merged;
    for (auto& m : maps) {
        for (auto& e : m.entries) {
            const char* kp = ref.data + e.key_off;
            StrEntry* tgt = merged.find_or_insert(
                e.hash, kp, e.key_len, ref.data,
                e.key_off, e.min_off, e.min_len);
            if (tgt->count == 0) {
                // freshly inserted; min_off/min_len already from this entry
                tgt->sum_len = e.sum_len;
                tgt->count   = e.count;
            } else {
                tgt->sum_len += e.sum_len;
                tgt->count   += e.count;
                const char* a = ref.data + e.min_off;
                const char* b = ref.data + tgt->min_off;
                if (lex_less(a, e.min_len, b, tgt->min_len)) {
                    tgt->min_off = e.min_off;
                    tgt->min_len = e.min_len;
                }
            }
        }
    }

    // Filter count > 100,000 then sort by avg DESC; only top 25 needed.
    // The qualifying set is tiny relative to the merged size, so a full sort
    // of the survivors is fine (no TopK needed).
    struct Row { double avg; int64_t count; int idx; };
    std::vector<Row> kept;
    kept.reserve(64);
    for (size_t i = 0; i < merged.entries.size(); ++i) {
        const auto& e = merged.entries[i];
        if (e.count > 100000) {
            double avg = (double)e.sum_len / (double)e.count;
            kept.push_back({avg, e.count, (int)i});
        }
    }
    std::sort(kept.begin(), kept.end(), [](const Row& a, const Row& b) {
        return a.avg > b.avg;
    });
    if (kept.size() > 25) kept.resize(25);

    std::printf("k,l,c,min_referer\n");
    for (const auto& r : kept) {
        const auto& e = merged.entries[r.idx];
        std::fwrite(ref.data + e.key_off, 1, e.key_len, stdout);
        std::printf(",%.6f,%lld,", r.avg, (long long)r.count);
        std::fwrite(ref.data + e.min_off, 1, e.min_len, stdout);
        std::fputc('\n', stdout);
    }
    return 0;
}
