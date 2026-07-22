// Q41: SELECT URLHash, EventDate, COUNT(*) AS PageViews FROM hits
//      WHERE CounterID = 62
//        AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31'
//        AND IsRefresh = 0
//        AND TraficSourceID IN (-1, 6)
//        AND RefererHash = 3594120000172545465
//      GROUP BY URLHash, EventDate
//      ORDER BY PageViews DESC LIMIT 10 OFFSET 100;
//
// Strategy:
//   1. Parallel scan with five cheap fixed-width predicates; the
//      RefererHash equality is by far the most selective so it goes first.
//   2. Surviving rows are aggregated into a per-thread open-addressing
//      hashmap keyed on the composite (URLHash:int64, EventDate:int32),
//      mixed via gendb::mix_pair. Sentinel for empty: URLHash == INT64_MIN.
//   3. Serial merge of per-thread maps. The filters are very selective
//      (RefererHash on a single value, narrow date window, CounterID=62);
//      we expect a small number of surviving groups, so a 1<<14 start
//      capacity is plenty.
//   4. TopK 110 by count; emit rows 101..110 (the OFFSET 100 LIMIT 10 slice).

#include "../utils/storage.h"
#include "../utils/timing.h"
#include "../utils/hashmap.h"
#include "../utils/topn.h"

#include <algorithm>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <omp.h>
#include <string>
#include <vector>

struct GroupMap {
    std::vector<int64_t> k_url;   // URLHash
    std::vector<int32_t> k_date;  // EventDate
    std::vector<int64_t> counts;
    size_t mask;
    size_t live = 0;
    static constexpr int64_t EMPTY = INT64_MIN;

    explicit GroupMap(size_t cap_pow2 = (size_t)1 << 14)
        : k_url(cap_pow2, EMPTY), k_date(cap_pow2, 0), counts(cap_pow2, 0),
          mask(cap_pow2 - 1) {}

    inline int64_t* get(int64_t url, int32_t date) {
        gendb::Pair64 p{(uint64_t)url, (uint64_t)(uint32_t)date};
        size_t pos = gendb::mix_pair(p) & mask;
        while (true) {
            int64_t s = k_url[pos];
            if (s == EMPTY) {
                k_url[pos]  = url;
                k_date[pos] = date;
                ++live;
                if (live * 2 > k_url.size()) {
                    grow();
                    return get(url, date);
                }
                return &counts[pos];
            }
            if (s == url && k_date[pos] == date) return &counts[pos];
            pos = (pos + 1) & mask;
        }
    }

    void grow() {
        std::vector<int64_t> ou = std::move(k_url);
        std::vector<int32_t> od = std::move(k_date);
        std::vector<int64_t> oc = std::move(counts);
        size_t newcap = ou.size() * 2;
        k_url.assign(newcap, EMPTY);
        k_date.assign(newcap, 0);
        counts.assign(newcap, 0);
        mask = newcap - 1;
        live = 0;
        for (size_t i = 0; i < ou.size(); ++i) {
            if (ou[i] != EMPTY) {
                gendb::Pair64 p{(uint64_t)ou[i], (uint64_t)(uint32_t)od[i]};
                size_t pos = gendb::mix_pair(p) & mask;
                while (k_url[pos] != EMPTY) pos = (pos + 1) & mask;
                k_url[pos]  = ou[i];
                k_date[pos] = od[i];
                counts[pos] = oc[i];
                ++live;
            }
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q41 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int32_t* counter_id  = gendb::mmap_col<int32_t>(dir, "CounterID");
    const int32_t* event_date  = gendb::mmap_col<int32_t>(dir, "EventDate");
    const int16_t* is_refresh  = gendb::mmap_col<int16_t>(dir, "IsRefresh");
    const int16_t* trafic_src  = gendb::mmap_col<int16_t>(dir, "TraficSourceID");
    const int64_t* referer_h   = gendb::mmap_col<int64_t>(dir, "RefererHash");
    const int64_t* url_hash    = gendb::mmap_col<int64_t>(dir, "URLHash");

    constexpr int32_t DATE_LO = 15887;  // 2013-07-01
    constexpr int32_t DATE_HI = 15917;  // 2013-07-31
    constexpr int64_t REF_HASH = 3594120000172545465LL;

    int T = omp_get_max_threads();
    std::vector<GroupMap> maps;
    maps.reserve(T);
    for (int t = 0; t < T; ++t) maps.emplace_back((size_t)1 << 14);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        GroupMap& m = maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            // Most selective predicate first.
            if (referer_h[i] != REF_HASH) continue;
            if (counter_id[i] != 62) continue;
            int32_t d = event_date[i];
            if (d < DATE_LO || d > DATE_HI) continue;
            if (is_refresh[i] != 0) continue;
            int16_t ts = trafic_src[i];
            if (ts != -1 && ts != 6) continue;
            int64_t* c = m.get(url_hash[i], d);
            *c += 1;
        }
    }

    // Serial merge of per-thread maps.
    GroupMap merged((size_t)1 << 14);
    for (auto& m : maps) {
        for (size_t i = 0; i < m.k_url.size(); ++i) {
            if (m.k_url[i] == GroupMap::EMPTY) continue;
            int64_t* tgt = merged.get(m.k_url[i], m.k_date[i]);
            *tgt += m.counts[i];
        }
    }

    // TopK 110 by count; we want rows 101..110 (OFFSET 100 LIMIT 10).
    struct Row {
        int64_t count;
        int64_t url;
        int32_t date;
    };
    struct RowLess {
        bool operator()(const Row& a, const Row& b) const { return a.count < b.count; }
    };
    constexpr size_t TOPN = 110;
    gendb::TopK<Row, RowLess> top(TOPN);
    for (size_t i = 0; i < merged.k_url.size(); ++i) {
        if (merged.k_url[i] == GroupMap::EMPTY) continue;
        top.try_push(Row{merged.counts[i], merged.k_url[i], merged.k_date[i]});
    }
    auto rows = top.sorted_desc();

    std::printf("URLHash,EventDate,c\n");
    // Skip 100, emit up to 10.
    size_t start = rows.size() > 100 ? 100 : rows.size();
    size_t end   = rows.size() > 110 ? 110 : rows.size();
    for (size_t i = start; i < end; ++i) {
        const auto& r = rows[i];
        std::printf("%lld,%d,%lld\n",
                    (long long)r.url,
                    (int)r.date,
                    (long long)r.count);
    }
    return 0;
}
