// Q22: SELECT SearchPhrase, MIN(URL), COUNT(*) AS c FROM hits
//      WHERE URL LIKE '%google%' AND SearchPhrase <> ''
//      GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;
//
// Strategy:
//   1. Parallel scan over rows. For each row:
//      - skip if SearchPhrase is empty
//      - skip if URL doesn't contain "google" (memmem via str_contains)
//      - hash SearchPhrase bytes, find_or_insert into per-thread StrMap
//      - bump count; update MIN(URL) by memcmp against currently-stored bytes
//   2. Merge per-thread maps serially (merge counts; pick lexicographically
//      smaller MIN URL across thread results).
//   3. TopK by count, emit (SearchPhrase, min_url, c).
//
// Each map entry stores (hash, sp_off/sp_len) for the SearchPhrase key plus
// (url_off/url_len) for the current MIN(URL).

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
    uint64_t sp_off;
    uint32_t sp_len;
    uint64_t url_off;   // offset into URL_data for current MIN URL
    uint32_t url_len;
    int64_t  count;
};

static inline uint64_t hash_bytes(const char* p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; ++i) {
        h ^= (uint8_t)p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

// memcmp-based lexicographic compare: returns true iff a < b.
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

    // Find by SearchPhrase bytes (p,n); insert if missing with given initial
    // URL min. Returns pointer to the StrEntry so caller can update min/count.
    StrEntry* find_or_insert(uint64_t h, const char* p, size_t n,
                             const char* sp_data,
                             uint64_t sp_row_off,
                             uint64_t url_row_off, uint32_t url_row_len) {
        size_t pos = h & mask;
        while (true) {
            int32_t idx = slots[pos];
            if (idx == -1) {
                StrEntry e;
                e.hash = h;
                e.sp_off = sp_row_off;
                e.sp_len = (uint32_t)n;
                e.url_off = url_row_off;
                e.url_len = url_row_len;
                e.count = 0;
                entries.push_back(e);
                slots[pos] = (int32_t)(entries.size() - 1);
                ++live;
                StrEntry* ret = &entries.back();
                if (live * 2 > slots.size()) {
                    // Rebuild slots; entries vector is untouched so pointer stays valid.
                    size_t newcap = slots.size() * 2;
                    std::vector<int32_t> ns(newcap, -1);
                    size_t nm = newcap - 1;
                    for (size_t i = 0; i < entries.size(); ++i) {
                        uint64_t hh = entries[i].hash;
                        size_t pp = hh & nm;
                        while (ns[pp] != -1) pp = (pp + 1) & nm;
                        ns[pp] = (int32_t)i;
                    }
                    slots = std::move(ns);
                    mask = nm;
                }
                return ret;
            }
            StrEntry& e = entries[idx];
            if (e.hash == h && e.sp_len == n &&
                memcmp(sp_data + e.sp_off, p, n) == 0) {
                return &e;
            }
            pos = (pos + 1) & mask;
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q22 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    gendb::StrCol sp  = gendb::mmap_strcol(dir, "SearchPhrase");
    gendb::StrCol url = gendb::mmap_strcol(dir, "URL");

    static constexpr char PAT[] = "google";
    static constexpr size_t PLEN = sizeof(PAT) - 1;

    int T = omp_get_max_threads();
    std::vector<StrMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        StrMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < sp.n; ++i) {
            uint64_t sa = sp.off[i], sb = sp.off[i + 1];
            if (sa == sb) continue;  // empty SearchPhrase
            uint64_t ua = url.off[i], ub = url.off[i + 1];
            size_t ulen = (size_t)(ub - ua);
            if (ulen < PLEN) continue;
            const char* up = url.data + ua;
            if (memmem(up, ulen, PAT, PLEN) == nullptr) continue;

            const char* spp = sp.data + sa;
            size_t spn = (size_t)(sb - sa);
            uint64_t h = hash_bytes(spp, spn);
            StrEntry* e = m.find_or_insert(h, spp, spn, sp.data, sa, ua, (uint32_t)ulen);
            e->count += 1;
            // Update MIN(URL) if the new URL is lex-smaller than stored one.
            // (On insert, url_off/url_len already equal the current row.)
            if (e->count > 1) {
                const char* cur = url.data + e->url_off;
                if (lex_less(up, ulen, cur, e->url_len)) {
                    e->url_off = ua;
                    e->url_len = (uint32_t)ulen;
                }
            }
        }
    }

    // Merge per-thread maps. Merged key bytes live in sp.data (offsets are
    // global); merged URL bytes live in url.data.
    StrMap merged;
    for (auto& m : maps) {
        for (auto& e : m.entries) {
            StrEntry* tgt = merged.find_or_insert(
                e.hash, sp.data + e.sp_off, e.sp_len,
                sp.data, e.sp_off, e.url_off, e.url_len);
            if (tgt->count == 0) {
                // freshly inserted — url_off/url_len already set from this entry
                tgt->count = e.count;
            } else {
                tgt->count += e.count;
                const char* a = url.data + e.url_off;
                const char* b = url.data + tgt->url_off;
                if (lex_less(a, e.url_len, b, tgt->url_len)) {
                    tgt->url_off = e.url_off;
                    tgt->url_len = e.url_len;
                }
            }
        }
    }

    // TopK by count.
    using Row = std::pair<int64_t, int>;
    gendb::TopK<Row> top(10);
    for (size_t i = 0; i < merged.entries.size(); ++i) {
        top.try_push({merged.entries[i].count, (int)i});
    }
    auto rows = top.sorted_desc();

    std::printf("SearchPhrase,min_url,c\n");
    for (auto& r : rows) {
        auto& e = merged.entries[r.second];
        std::fwrite(sp.data + e.sp_off, 1, e.sp_len, stdout);
        std::fputc(',', stdout);
        std::fwrite(url.data + e.url_off, 1, e.url_len, stdout);
        std::printf(",%lld\n", (long long)r.first);
    }
    return 0;
}
