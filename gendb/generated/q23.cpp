// Q23: SELECT SearchPhrase, MIN(URL), MIN(Title), COUNT(*) AS c,
//             COUNT(DISTINCT UserID)
//      FROM hits
//      WHERE Title LIKE '%Google%' AND URL NOT LIKE '%.google.%'
//        AND SearchPhrase <> ''
//      GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;
//
// Strategy:
//   Per-thread open-addressing string-keyed hashtable (q13 pattern) on
//   SearchPhrase. Each entry stores:
//       count, min_url (off,len), min_title (off,len), and a small
//       open-addressing int64 hashset of UserIDs for COUNT(DISTINCT).
//
//   Inner loop per row:
//     1. Skip empty SearchPhrase (cheapest test; eliminates the vast majority).
//     2. Skip rows where URL contains ".google." (memmem).
//     3. Skip rows where Title doesn't contain "Google" (memmem).
//     4. Look up SearchPhrase in the per-thread map. Bump count, update
//        MIN(URL) / MIN(Title) via lexicographic memcmp, insert UserID into
//        the entry's I64Set.
//
//   Merge thread maps serially: sum counts, take min of URL/Title, union sets.
//   Final TopK<10> by count.

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

// FNV-1a-style cheap hash for short strings.
static inline uint64_t hash_bytes(const char* p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; ++i) {
        h ^= (uint8_t)p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

// Lexicographic less-than: returns true iff [a, a+an) < [b, b+bn).
static inline bool lex_lt(const char* a, size_t an, const char* b, size_t bn) {
    size_t m = an < bn ? an : bn;
    int c = std::memcmp(a, b, m);
    if (c != 0) return c < 0;
    return an < bn;
}

// Small open-addressing int64 hashset with sentinel = 0 (UserID=0 is treated
// as a valid value via the `has_zero` flag — actual UserID=0 rows are rare
// but we handle them to keep semantics matching COUNT(DISTINCT)).
struct I64Set {
    std::vector<int64_t> slots;
    size_t mask;
    size_t live = 0;
    bool   has_zero = false;

    I64Set() : slots(8, 0), mask(7) {}

    inline void insert(int64_t k) {
        if (k == 0) { has_zero = true; return; }
        if ((live + 1) * 2 > slots.size()) grow();
        uint64_t h = gendb::mix64((uint64_t)k);
        size_t pos = h & mask;
        while (true) {
            int64_t cur = slots[pos];
            if (cur == 0) { slots[pos] = k; ++live; return; }
            if (cur == k) return;
            pos = (pos + 1) & mask;
        }
    }

    void grow() {
        size_t newcap = slots.size() * 2;
        if (newcap < 16) newcap = 16;
        std::vector<int64_t> ns(newcap, 0);
        size_t nm = newcap - 1;
        for (int64_t v : slots) {
            if (v == 0) continue;
            uint64_t h = gendb::mix64((uint64_t)v);
            size_t pos = h & nm;
            while (ns[pos] != 0) pos = (pos + 1) & nm;
            ns[pos] = v;
        }
        slots = std::move(ns);
        mask = nm;
    }

    size_t size() const { return live + (has_zero ? 1 : 0); }

    // Union another set into this one.
    void merge(const I64Set& other) {
        if (other.has_zero) has_zero = true;
        for (int64_t v : other.slots) {
            if (v != 0) insert(v);
        }
    }
};

struct Entry {
    uint64_t hash;
    // SearchPhrase byte range in SearchPhrase _data.bin
    uint32_t sp_off_lo;
    uint32_t sp_off_hi;
    uint32_t sp_len;
    // MIN(URL) byte range in URL _data.bin
    uint32_t url_off_lo;
    uint32_t url_off_hi;
    uint32_t url_len;
    // MIN(Title) byte range in Title _data.bin
    uint32_t ttl_off_lo;
    uint32_t ttl_off_hi;
    uint32_t ttl_len;
    int64_t  count;
    I64Set   users;
};

struct StrMap {
    static constexpr size_t INIT_CAP = 1 << 14;
    std::vector<int32_t> slots;  // -1 = empty, else index into entries
    std::vector<Entry>   entries;
    size_t mask;
    size_t live = 0;

    StrMap() : slots(INIT_CAP, -1), entries(), mask(INIT_CAP - 1) {
        entries.reserve(1024);
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

    // Look up by SearchPhrase bytes. On insert, initialize MIN(URL) and
    // MIN(Title) from the current row's values. Returns pointer to entry
    // so caller can update aggregates.
    inline Entry* find_or_insert(
        uint64_t h,
        const char* sp_p, size_t sp_n, const char* sp_data, uint64_t sp_row_off,
        const char* url_p, size_t url_n, const char* url_data, uint64_t url_row_off,
        const char* ttl_p, size_t ttl_n, const char* ttl_data, uint64_t ttl_row_off)
    {
        size_t pos = h & mask;
        while (true) {
            int32_t idx = slots[pos];
            if (idx == -1) {
                Entry e;
                e.hash       = h;
                e.sp_off_lo  = (uint32_t)(sp_row_off & 0xffffffffu);
                e.sp_off_hi  = (uint32_t)(sp_row_off >> 32);
                e.sp_len     = (uint32_t)sp_n;
                e.url_off_lo = (uint32_t)(url_row_off & 0xffffffffu);
                e.url_off_hi = (uint32_t)(url_row_off >> 32);
                e.url_len    = (uint32_t)url_n;
                e.ttl_off_lo = (uint32_t)(ttl_row_off & 0xffffffffu);
                e.ttl_off_hi = (uint32_t)(ttl_row_off >> 32);
                e.ttl_len    = (uint32_t)ttl_n;
                e.count      = 0;
                entries.push_back(std::move(e));
                slots[pos] = (int32_t)(entries.size() - 1);
                ++live;
                Entry* ret = &entries.back();
                maybe_grow();
                // entries vector wasn't reallocated by maybe_grow (only the
                // slots index moved). The push_back above was the only
                // potential realloc and we captured the pointer after it.
                return ret;
            }
            Entry& e = entries[idx];
            if (e.hash == h && e.sp_len == (uint32_t)sp_n) {
                uint64_t off = ((uint64_t)e.sp_off_hi << 32) | e.sp_off_lo;
                if (std::memcmp(sp_data + off, sp_p, sp_n) == 0) return &e;
            }
            pos = (pos + 1) & mask;
        }
    }
};

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q23 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    auto sp  = gendb::mmap_strcol(dir, "SearchPhrase");
    auto url = gendb::mmap_strcol(dir, "URL");
    auto ttl = gendb::mmap_strcol(dir, "Title");
    const int64_t* uid = gendb::mmap_col<int64_t>(dir, "UserID");

    static constexpr char PAT_GOOGLE[] = "Google";
    static constexpr size_t PAT_GOOGLE_LEN = sizeof(PAT_GOOGLE) - 1;
    static constexpr char PAT_DOTGOOGLE[] = ".google.";
    static constexpr size_t PAT_DOTGOOGLE_LEN = sizeof(PAT_DOTGOOGLE) - 1;

    int T = omp_get_max_threads();
    std::vector<StrMap> maps(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        StrMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            // 1. SearchPhrase non-empty.
            uint64_t sp_a = sp.off[i], sp_b = sp.off[i + 1];
            if (sp_a == sp_b) continue;
            size_t sp_n = (size_t)(sp_b - sp_a);
            const char* sp_p = sp.data + sp_a;

            // 2. URL does NOT contain ".google."
            uint64_t url_a = url.off[i], url_b = url.off[i + 1];
            size_t url_n = (size_t)(url_b - url_a);
            const char* url_p = url.data + url_a;
            if (url_n >= PAT_DOTGOOGLE_LEN &&
                memmem(url_p, url_n, PAT_DOTGOOGLE, PAT_DOTGOOGLE_LEN) != nullptr) {
                continue;
            }

            // 3. Title contains "Google".
            uint64_t ttl_a = ttl.off[i], ttl_b = ttl.off[i + 1];
            size_t ttl_n = (size_t)(ttl_b - ttl_a);
            const char* ttl_p = ttl.data + ttl_a;
            if (ttl_n < PAT_GOOGLE_LEN ||
                memmem(ttl_p, ttl_n, PAT_GOOGLE, PAT_GOOGLE_LEN) == nullptr) {
                continue;
            }

            // 4. Aggregate.
            uint64_t h = hash_bytes(sp_p, sp_n);
            Entry* e = m.find_or_insert(
                h,
                sp_p, sp_n, sp.data, sp_a,
                url_p, url_n, url.data, url_a,
                ttl_p, ttl_n, ttl.data, ttl_a);
            e->count += 1;
            // MIN(URL)
            uint64_t cur_url_off = ((uint64_t)e->url_off_hi << 32) | e->url_off_lo;
            if (lex_lt(url_p, url_n,
                       url.data + cur_url_off, e->url_len)) {
                e->url_off_lo = (uint32_t)(url_a & 0xffffffffu);
                e->url_off_hi = (uint32_t)(url_a >> 32);
                e->url_len    = (uint32_t)url_n;
            }
            // MIN(Title)
            uint64_t cur_ttl_off = ((uint64_t)e->ttl_off_hi << 32) | e->ttl_off_lo;
            if (lex_lt(ttl_p, ttl_n,
                       ttl.data + cur_ttl_off, e->ttl_len)) {
                e->ttl_off_lo = (uint32_t)(ttl_a & 0xffffffffu);
                e->ttl_off_hi = (uint32_t)(ttl_a >> 32);
                e->ttl_len    = (uint32_t)ttl_n;
            }
            e->users.insert(uid[i]);
        }
    }

    // Merge per-thread maps serially.
    StrMap merged;
    for (auto& m : maps) {
        for (auto& e : m.entries) {
            uint64_t sp_off  = ((uint64_t)e.sp_off_hi  << 32) | e.sp_off_lo;
            uint64_t url_off = ((uint64_t)e.url_off_hi << 32) | e.url_off_lo;
            uint64_t ttl_off = ((uint64_t)e.ttl_off_hi << 32) | e.ttl_off_lo;
            Entry* tgt = merged.find_or_insert(
                e.hash,
                sp.data + sp_off, e.sp_len, sp.data, sp_off,
                url.data + url_off, e.url_len, url.data, url_off,
                ttl.data + ttl_off, e.ttl_len, ttl.data, ttl_off);
            tgt->count += e.count;
            // MIN(URL) across thread-locals.
            uint64_t cur_url_off = ((uint64_t)tgt->url_off_hi << 32) | tgt->url_off_lo;
            if (lex_lt(url.data + url_off, e.url_len,
                       url.data + cur_url_off, tgt->url_len)) {
                tgt->url_off_lo = (uint32_t)(url_off & 0xffffffffu);
                tgt->url_off_hi = (uint32_t)(url_off >> 32);
                tgt->url_len    = e.url_len;
            }
            // MIN(Title) across thread-locals.
            uint64_t cur_ttl_off = ((uint64_t)tgt->ttl_off_hi << 32) | tgt->ttl_off_lo;
            if (lex_lt(ttl.data + ttl_off, e.ttl_len,
                       ttl.data + cur_ttl_off, tgt->ttl_len)) {
                tgt->ttl_off_lo = (uint32_t)(ttl_off & 0xffffffffu);
                tgt->ttl_off_hi = (uint32_t)(ttl_off >> 32);
                tgt->ttl_len    = e.ttl_len;
            }
            tgt->users.merge(e.users);
        }
        // Free per-thread memory eagerly.
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

    std::printf("SearchPhrase,min_url,min_title,c,ndv\n");
    for (auto& r : rows) {
        const Entry& e = merged.entries[r.second];
        uint64_t sp_off  = ((uint64_t)e.sp_off_hi  << 32) | e.sp_off_lo;
        uint64_t url_off = ((uint64_t)e.url_off_hi << 32) | e.url_off_lo;
        uint64_t ttl_off = ((uint64_t)e.ttl_off_hi << 32) | e.ttl_off_lo;
        std::fwrite(sp.data + sp_off, 1, e.sp_len, stdout);
        std::fputc(',', stdout);
        std::fwrite(url.data + url_off, 1, e.url_len, stdout);
        std::fputc(',', stdout);
        std::fwrite(ttl.data + ttl_off, 1, e.ttl_len, stdout);
        std::printf(",%lld,%zu\n", (long long)r.first, e.users.size());
    }
    return 0;
}
