// Q32: SELECT WatchID, ClientIP, COUNT(*) AS c,
//             SUM(IsRefresh), AVG(ResolutionWidth)
//      FROM hits WHERE SearchPhrase <> ''
//      GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10;
//
// Composite key: (int64 WatchID, int32 ClientIP). WatchID is mostly-unique,
// so the group cardinality is essentially proportional to the filtered row
// count — i.e. several million entries per thread. A single-thread merge of
// huge maps would dominate; instead we keep per-thread open-addressing
// hashmaps that are pre-sized large enough to absorb that load, then do
// a serial merge.
//
// Hash mix: mix64(WatchID) ^ (mix32(ClientIP) * 0x9e3779b97f4a7c15ULL).
//
// Empty-slot encoding: each entry carries an explicit `occupied` flag rather
// than reserving a sentinel value for WatchID (it's int64 and we can't
// guarantee any concrete value is unused by the dataset).

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
    int64_t  watchid;
    int32_t  clientip;
    uint32_t occupied;   // 0 = empty slot, 1 = live
    int64_t  count;
    int64_t  sum_ref;
    int64_t  sum_rw;
};

struct PairMap {
    std::vector<Entry> slots;
    size_t mask;
    size_t live = 0;

    explicit PairMap(size_t cap_pow2) : slots(cap_pow2), mask(cap_pow2 - 1) {}

    static inline uint64_t hash_key(int64_t w, int32_t ip) {
        return gendb::mix64((uint64_t)w)
             ^ (gendb::mix32((uint32_t)ip) * 0x9e3779b97f4a7c15ULL);
    }

    inline Entry* get(int64_t w, int32_t ip, uint64_t h) {
        size_t pos = h & mask;
        while (true) {
            Entry& s = slots[pos];
            if (!s.occupied) {
                s.watchid  = w;
                s.clientip = ip;
                s.occupied = 1;
                ++live;
                if (live * 2 > slots.size()) {
                    grow();
                    return get(w, ip, h);
                }
                return &slots[pos];
            }
            if (s.watchid == w && s.clientip == ip) return &s;
            pos = (pos + 1) & mask;
        }
    }

    void grow() {
        std::vector<Entry> old = std::move(slots);
        size_t newcap = old.size() * 2;
        slots.assign(newcap, Entry{});
        mask = newcap - 1;
        live = 0;
        for (auto& e : old) {
            if (!e.occupied) continue;
            uint64_t h = hash_key(e.watchid, e.clientip);
            size_t pos = h & mask;
            while (slots[pos].occupied) pos = (pos + 1) & mask;
            slots[pos] = e;
            ++live;
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q32 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    const int64_t* wid = gendb::mmap_col<int64_t>(dir, "WatchID");
    const int32_t* cip = gendb::mmap_col<int32_t>(dir, "ClientIP");
    const int16_t* ref = gendb::mmap_col<int16_t>(dir, "IsRefresh");
    const int16_t* rw  = gendb::mmap_col<int16_t>(dir, "ResolutionWidth");
    auto sp = gendb::mmap_strcol(dir, "SearchPhrase");

    int T = omp_get_max_threads();
    // Pre-size aggressively: ~3-5M live entries per thread on 16 threads is
    // common for high-cardinality composite keys after the SearchPhrase filter.
    // 1<<22 = 4M slots → grows on demand if exceeded.
    std::vector<PairMap*> maps(T);
    for (int t = 0; t < T; ++t) maps[t] = new PairMap(1 << 22);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        PairMap& m = *maps[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < gendb::HITS_ROWS; ++i) {
            if (sp.off[i] == sp.off[i + 1]) continue;  // SearchPhrase == ''
            int64_t w  = wid[i];
            int32_t ip = cip[i];
            uint64_t h = PairMap::hash_key(w, ip);
            Entry* e = m.get(w, ip, h);
            e->count   += 1;
            e->sum_ref += ref[i];
            e->sum_rw  += rw[i];
        }
    }

    // Serial merge of per-thread maps into one big map.
    size_t total_live = 0;
    for (int t = 0; t < T; ++t) total_live += maps[t]->live;
    size_t mcap = 1;
    while (mcap < total_live * 2) mcap <<= 1;
    if (mcap < (1u << 14)) mcap = 1u << 14;
    PairMap merged(mcap);
    for (int t = 0; t < T; ++t) {
        PairMap& m = *maps[t];
        for (auto& e : m.slots) {
            if (!e.occupied) continue;
            uint64_t h = PairMap::hash_key(e.watchid, e.clientip);
            Entry* dst = merged.get(e.watchid, e.clientip, h);
            dst->count   += e.count;
            dst->sum_ref += e.sum_ref;
            dst->sum_rw  += e.sum_rw;
        }
        delete maps[t];
        maps[t] = nullptr;
    }

    // TopK by count. Tie-break by WatchID then ClientIP for determinism (not
    // strictly required by the SQL, but keeps output stable across runs).
    struct Row { int64_t count; int64_t watchid; int32_t clientip; int64_t sum_ref; int64_t sum_rw; };
    struct Less {
        bool operator()(const Row& a, const Row& b) const {
            if (a.count != b.count) return a.count < b.count;
            if (a.watchid != b.watchid) return a.watchid < b.watchid;
            return a.clientip < b.clientip;
        }
    };
    gendb::TopK<Row, Less> top(10);
    for (auto& e : merged.slots) {
        if (!e.occupied) continue;
        top.try_push(Row{e.count, e.watchid, e.clientip, e.sum_ref, e.sum_rw});
    }
    auto rows = top.sorted_desc();

    std::printf("WatchID,ClientIP,c,sum_ref,avg_rw\n");
    for (auto& r : rows) {
        double avg_rw = r.count ? (double)r.sum_rw / (double)r.count : 0.0;
        std::printf("%lld,%d,%lld,%lld,%.6f\n",
                    (long long)r.watchid,
                    (int)r.clientip,
                    (long long)r.count,
                    (long long)r.sum_ref,
                    avg_rw);
    }
    return 0;
}
