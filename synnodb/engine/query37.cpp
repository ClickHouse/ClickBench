#include "query37.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

// SQL:
/** SELECT URL, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND DontCountHits = 0 AND IsRefresh = 0 AND URL <> '' GROUP BY URL ORDER BY PageViews DESC LIMIT 10; */

namespace {

constexpr size_t kTop = 10;

// Days since 1970-01-01 of a proleptic Gregorian civil date.
constexpr int64_t days_from_civil(int64_t y, int64_t m, int64_t d)
{
    y -= m <= 2;
    const int64_t era = (y >= 0 ? y : y - 399) / 400;
    const int64_t yoe = y - era * 400;
    const int64_t doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

constexpr int32_t kCounter = 62;
constexpr int64_t kDateLo = days_from_civil(2013, 7, 1);
constexpr int64_t kDateHi = days_from_civil(2013, 7, 31);

inline uint64_t mix64(uint64_t x)
{
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

inline uint64_t hash_bytes(const char* p, size_t n)
{
    uint64_t h = 0x9E3779B97F4A7C15ULL ^ (static_cast<uint64_t>(n) * 0xC2B2AE3D27D4EB4FULL);
    while (n >= 8)
    {
        uint64_t v;
        std::memcpy(&v, p, 8);
        h = (h ^ v) * 0x9FB21C651E98DF25ULL;
        h ^= h >> 32;
        p += 8;
        n -= 8;
    }
    if (n)
    {
        uint64_t v = 0;
        std::memcpy(&v, p, n);
        h = (h ^ v) * 0x9FB21C651E98DF25ULL;
        h ^= h >> 32;
    }
    return mix64(h);
}

struct Ent
{
    uint64_t hash = 0;
    uint64_t cnt = 0;  // 0 == empty
    uint64_t row = 0;
};

struct Table
{
    std::vector<Ent> slots;
    uint64_t used = 0;
};

}

std::shared_ptr<arrow::Table> run_q37(Database* db, const Q37Args& args) {
    if (!db) {
        throw std::runtime_error("run_q37: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    static_assert(kSuperRows % kChunkRows == 0, "morsels must not straddle super-chunks");

    const StringArena& url = db->URL;
    const uint64_t n_rows = db->n_rows;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + kChunkRows - 1) / kChunkRows);
    if (url.rows != n_rows) {
        throw std::runtime_error("run_q37: URL column shape does not match the table");
    }

    const int32_t* counter = db->CounterID.data();
    const uint16_t* date = db->EventDate.data();
    const uint8_t* dch = db->DontCountHits.data();
    const uint8_t* refresh = db->IsRefresh.data();

    auto grow = [](Table& t)
    {
        std::vector<Ent> old = std::move(t.slots);
        const size_t cap = old.empty() ? 1024 : old.size() * 2;
        t.slots.assign(cap, Ent{});
        const uint64_t mask = cap - 1;
        for (const Ent& e : old)
        {
            if (e.cnt == 0)
                continue;
            uint64_t p = e.hash & mask;
            while (t.slots[p].cnt != 0)
                p = (p + 1) & mask;
            t.slots[p] = e;
        }
    };

    // Insert (hash,row) with count c; equal keys compared by full URL bytes.
    auto add = [&](Table& t, uint64_t h, uint64_t row, uint64_t c)
    {
        if (t.slots.empty() || (t.used + 1) * 2 > t.slots.size())
            grow(t);
        const uint64_t mask = t.slots.size() - 1;
        const std::string_view key = url.get(row);
        uint64_t p = h & mask;
        for (;;)
        {
            Ent& e = t.slots[p];
            if (e.cnt == 0)
            {
                e.hash = h;
                e.cnt = c;
                e.row = row;
                ++t.used;
                return;
            }
            if (e.hash == h && url.get(e.row) == key)
            {
                e.cnt += c;
                return;
            }
            p = (p + 1) & mask;
        }
    };

    Table res = parallel_reduce<Table>(
        get_query_pool(), n_morsels, Table{},
        [&](Table& acc, int64_t m) {
            const uint64_t c = static_cast<uint64_t>(m);
            // Zone-map skip: the chunk must be able to contain CounterID = 62, a date in range,
            // DontCountHits = 0 and IsRefresh = 0.
            if (db->zone_CounterID.mn[c] > kCounter || db->zone_CounterID.mx[c] < kCounter)
                return;
            if (static_cast<int64_t>(db->zone_EventDate.mx[c]) < kDateLo
                || static_cast<int64_t>(db->zone_EventDate.mn[c]) > kDateHi)
                return;
            if (db->zone_DontCountHits.mn[c] != 0 || db->zone_IsRefresh.mn[c] != 0)
                return;
            const uint64_t lo = c * kChunkRows;
            const uint64_t hi = std::min<uint64_t>(lo + kChunkRows, n_rows);
            const uint64_t s = lo / kSuperRows;
            const uint64_t j0 = lo % kSuperRows;
            const uint32_t* o = url.offs.data() + s * (kSuperRows + 1);
            const char* bytes = url.bytes.data() + url.base[s];
            // Branch-free candidate selection on CounterID (auto-vectorizable) per block of
            // rows, then the remaining predicates only on the few candidates.
            constexpr uint64_t kBlock = 2048;
            uint32_t cand[kBlock];
            for (uint64_t b0 = lo; b0 < hi; b0 += kBlock)
            {
            const uint64_t b1 = std::min<uint64_t>(b0 + kBlock, hi);
            uint32_t nc = 0;
            for (uint64_t r = b0; r < b1; ++r)
            {
                cand[nc] = static_cast<uint32_t>(r - b0);
                nc += (counter[r] == kCounter) ? 1u : 0u;
            }
            for (uint32_t ci = 0; ci < nc; ++ci)
            {
                const uint64_t r = b0 + cand[ci];
                const int64_t d = date[r];
                if (d < kDateLo || d > kDateHi)
                    continue;
                if (dch[r] != 0 || refresh[r] != 0)
                    continue;
                const uint64_t j = j0 + (r - lo);
                const uint32_t len = o[j + 1] - o[j];
                if (len == 0)
                    continue;
                add(acc, hash_bytes(bytes + o[j], len), r, 1);
            }
            }
        },
        [&](Table& acc, const Table& part) {
            if (part.used == 0)
                return;
            if (acc.used == 0)
            {
                acc = part;
                return;
            }
            for (const Ent& e : part.slots)
                if (e.cnt != 0)
                    add(acc, e.hash, e.row, e.cnt);
        });

    struct Group
    {
        uint64_t cnt;
        uint64_t row;
    };
    std::vector<Group> top;
    for (const Ent& e : res.slots)
        if (e.cnt != 0)
            top.push_back(Group{e.cnt, e.row});

    auto better = [&](const Group& a, const Group& b)
    {
        if (a.cnt != b.cnt)
            return a.cnt > b.cnt;
        return url.get(a.row) < url.get(b.row);
    };
    if (top.size() > kTop)
    {
        std::partial_sort(top.begin(), top.begin() + kTop, top.end(), better);
        top.resize(kTop);
    }
    else
        std::sort(top.begin(), top.end(), better);

    std::vector<std::string> urls;
    std::vector<int64_t> counts;
    for (const Group& g : top)
    {
        urls.emplace_back(url.get(g.row));
        counts.push_back(static_cast<int64_t>(g.cnt));
    }

    return make_table({
        {"URL", string_column(urls)},
        {"PageViews", integer_column(counts, {}, arrow::int64())},
    });
}
