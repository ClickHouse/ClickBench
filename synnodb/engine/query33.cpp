#include "query33.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

// SQL:
/** SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits
    GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10; */

namespace {

constexpr uint64_t kSlice = 1ull << 20;
constexpr size_t kParts = 256;
constexpr size_t kTop = 10;

inline uint64_t mix64(uint64_t x)
{
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

inline uint64_t hash_key(int64_t wid, int32_t ip)
{
    return mix64(static_cast<uint64_t>(wid) ^ (static_cast<uint64_t>(static_cast<uint32_t>(ip)) * 0x9E3779B97F4A7C15ULL));
}

struct Pair
{
    int64_t wid;
    int32_t ip;
    int16_t w;
    uint8_t r;
};

struct Parts
{
    std::vector<std::vector<Pair>> b;
};

struct Ent
{
    int64_t wid = 0;
    uint64_t cnt = 0;  // cnt == 0 marks an empty slot
    uint64_t sr = 0;
    int64_t sw = 0;
    int32_t ip = 0;
};

struct Table
{
    std::vector<Ent> slots;
    size_t used = 0;
    size_t mask = 0;

    void reset(size_t cap)
    {
        slots.assign(cap, Ent{});
        mask = cap - 1;
        used = 0;
    }

    Ent& find_or_insert(int64_t wid, int32_t ip, uint64_t h)
    {
        if ((used + 1) * 2 > slots.size())
            grow();
        size_t i = h & mask;
        while (true)
        {
            Ent& e = slots[i];
            if (e.cnt == 0)
            {
                e.wid = wid;
                e.ip = ip;
                ++used;
                return e;
            }
            if (e.wid == wid && e.ip == ip)
                return e;
            i = (i + 1) & mask;
        }
    }

    void grow()
    {
        std::vector<Ent> old;
        old.swap(slots);
        slots.assign(old.size() * 2, Ent{});
        mask = slots.size() - 1;
        for (const Ent& e : old)
        {
            if (e.cnt == 0)
                continue;
            size_t i = (hash_key(e.wid, e.ip) >> 8) & mask;
            while (slots[i].cnt != 0)
                i = (i + 1) & mask;
            slots[i] = e;
        }
    }
};

struct Res
{
    std::vector<Ent> top;
};

inline bool better(const Ent& a, const Ent& b)
{
    if (a.cnt != b.cnt)
        return a.cnt > b.cnt;
    if (a.wid != b.wid)
        return a.wid < b.wid;
    return a.ip < b.ip;  // deterministic tie-break (SQL leaves ties unspecified)
}

void trim(std::vector<Ent>& v)
{
    if (v.size() > kTop)
    {
        std::partial_sort(v.begin(), v.begin() + kTop, v.end(), better);
        v.resize(kTop);
    }
}

}

std::shared_ptr<arrow::Table> run_q33(Database* db, const Q33Args& args) {
    if (!db) {
        throw std::runtime_error("run_q33: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    const std::vector<int64_t>& watch = db->WatchID;
    const std::vector<int32_t>& ip = db->ClientIP;
    const std::vector<uint8_t>& refresh = db->IsRefresh;
    const std::vector<int16_t>& width = db->ResolutionWidth;
    if (watch.size() != n_rows || ip.size() != n_rows || refresh.size() != n_rows
        || width.size() != n_rows) {
        throw std::runtime_error("run_q33: column row count does not match the table");
    }

    // Phase 1: radix-partition (key, IsRefresh, width) by the key hash.
    const int64_t n_slices = static_cast<int64_t>((n_rows + kSlice - 1) / kSlice);
    Parts parts = parallel_reduce<Parts>(
        get_query_pool(), n_slices, Parts{},
        [&](Parts& acc, int64_t s) {
            if (acc.b.empty())
                acc.b.resize(kParts);
            const uint64_t lo = static_cast<uint64_t>(s) * kSlice;
            const uint64_t hi = std::min<uint64_t>(lo + kSlice, n_rows);
            for (uint64_t i = lo; i < hi; ++i)
            {
                acc.b[hash_key(watch[i], ip[i]) & (kParts - 1)].push_back(Pair{watch[i], ip[i], width[i], refresh[i]});
            }
        },
        [&](Parts& acc, const Parts& part) {
            if (part.b.empty())
                return;
            if (acc.b.empty())
            {
                acc.b = std::move(const_cast<Parts&>(part).b);
                return;
            }
            for (size_t p = 0; p < kParts; ++p)
            {
                std::vector<Pair>& src = const_cast<Parts&>(part).b[p];
                if (acc.b[p].size() < src.size())
                    acc.b[p].swap(src);
                acc.b[p].insert(acc.b[p].end(), src.begin(), src.end());
            }
        });

    // Phase 2: each partition owns a disjoint key set; aggregate it in a private table, keep its top 10.
    Res res = parallel_reduce<Res>(
        get_query_pool(), static_cast<int64_t>(kParts), Res{},
        [&](Res& acc, int64_t p) {
            if (parts.b.empty())
                return;
            const std::vector<Pair>& rows = parts.b[static_cast<size_t>(p)];
            if (rows.empty())
                return;
            Table t;
            {
                size_t cap = 1024;
                while (cap < rows.size() * 2)
                    cap <<= 1;
                t.reset(cap);
            }
            for (const Pair& r : rows)
            {
                Ent& e = t.find_or_insert(r.wid, r.ip, hash_key(r.wid, r.ip) >> 8);
                ++e.cnt;
                e.sr += r.r;
                e.sw += r.w;
            }
            for (const Ent& e : t.slots)
                if (e.cnt != 0)
                    acc.top.push_back(e);
            trim(acc.top);
        },
        [&](Res& acc, const Res& part) {
            acc.top.insert(acc.top.end(), part.top.begin(), part.top.end());
            trim(acc.top);
        });

    std::vector<Ent> top = std::move(res.top);
    std::sort(top.begin(), top.end(), better);
    if (top.size() > kTop)
        top.resize(kTop);

    std::vector<int64_t> wids;
    std::vector<int32_t> ips;
    std::vector<int64_t> counts;
    std::vector<__int128> sums;
    std::vector<double> avgs;
    for (const Ent& e : top)
    {
        wids.push_back(e.wid);
        ips.push_back(e.ip);
        counts.push_back(static_cast<int64_t>(e.cnt));
        sums.push_back(static_cast<__int128>(e.sr));
        avgs.push_back(static_cast<double>(e.sw) / static_cast<double>(e.cnt));
    }

    return make_table({
        {"WatchID", integer_column(wids, {}, arrow::int64())},
        {"ClientIP", integer_column(ips, {}, arrow::int32())},
        {"c", integer_column(counts, {}, arrow::int64())},
        {"sum(IsRefresh)", hugeint_column(sums)},
        {"avg(ResolutionWidth)", double_column(avgs)},
    });
}