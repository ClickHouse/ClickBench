#include "query41.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

// SQL:
/** SELECT URLHash, EventDate, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND TraficSourceID IN (-1, 6) AND RefererHash = 3594120000172545465 GROUP BY URLHash, EventDate ORDER BY PageViews DESC LIMIT 10 OFFSET 100; */

namespace {

constexpr size_t kLimit = 10;
constexpr size_t kOffset = 100;

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
constexpr int64_t kRefererHash = 3594120000172545465LL;

inline uint64_t mix64(uint64_t x)
{
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

struct Ent
{
    int64_t url_hash = 0;
    uint64_t date = 0;
    uint64_t cnt = 0;  // 0 == empty
};

struct Table
{
    std::vector<Ent> slots;
    uint64_t used = 0;
};

inline uint64_t hash_key(int64_t u, uint64_t d)
{
    return mix64(static_cast<uint64_t>(u) ^ (d * 0x9E3779B97F4A7C15ULL));
}

}

std::shared_ptr<arrow::Table> run_q41(Database* db, const Q41Args& args) {
    if (!db) {
        throw std::runtime_error("run_q41: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + kChunkRows - 1) / kChunkRows);

    const int32_t* counter = db->CounterID.data();
    const uint16_t* date = db->EventDate.data();
    const uint8_t* refresh = db->IsRefresh.data();
    const int16_t* trafic = db->TraficSourceID.data();
    const int64_t* rhash = db->RefererHash.data();
    const int64_t* uhash = db->URLHash.data();

    auto grow = [](Table& t)
    {
        std::vector<Ent> old = std::move(t.slots);
        const size_t cap = old.empty() ? 256 : old.size() * 2;
        t.slots.assign(cap, Ent{});
        const uint64_t mask = cap - 1;
        for (const Ent& e : old)
        {
            if (e.cnt == 0)
                continue;
            uint64_t p = hash_key(e.url_hash, e.date) & mask;
            while (t.slots[p].cnt != 0)
                p = (p + 1) & mask;
            t.slots[p] = e;
        }
    };

    auto add = [&](Table& t, int64_t u, uint64_t d, uint64_t c)
    {
        if (t.slots.empty() || (t.used + 1) * 2 > t.slots.size())
            grow(t);
        const uint64_t mask = t.slots.size() - 1;
        uint64_t p = hash_key(u, d) & mask;
        for (;;)
        {
            Ent& e = t.slots[p];
            if (e.cnt == 0)
            {
                e.url_hash = u;
                e.date = d;
                e.cnt = c;
                ++t.used;
                return;
            }
            if (e.url_hash == u && e.date == d)
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
            if (db->zone_CounterID.mn[c] > kCounter || db->zone_CounterID.mx[c] < kCounter)
                return;
            if (static_cast<int64_t>(db->zone_EventDate.mx[c]) < kDateLo
                || static_cast<int64_t>(db->zone_EventDate.mn[c]) > kDateHi)
                return;
            if (db->zone_IsRefresh.mn[c] != 0)
                return;
            if (db->zone_TraficSourceID.mn[c] > 6 || db->zone_TraficSourceID.mx[c] < -1)
                return;
            const uint64_t lo = c * kChunkRows;
            const uint64_t hi = std::min<uint64_t>(lo + kChunkRows, n_rows);

            // Branch-free candidate pass on two cheap, selective predicates.
            constexpr uint64_t kBlock = 2048;
            std::array<uint32_t, kBlock> cand;
            for (uint64_t b = lo; b < hi; b += kBlock)
            {
                const uint64_t e = std::min<uint64_t>(b + kBlock, hi);
                size_t nc = 0;
                for (uint64_t r = b; r < e; ++r)
                {
                    cand[nc] = static_cast<uint32_t>(r - b);
                    nc += (counter[r] == kCounter) & (rhash[r] == kRefererHash);
                }
                for (size_t k = 0; k < nc; ++k)
                {
                    const uint64_t r = b + cand[k];
                    const int64_t d = date[r];
                    if (d < kDateLo || d > kDateHi)
                        continue;
                    if (refresh[r] != 0)
                        continue;
                    const int16_t t = trafic[r];
                    if (t != -1 && t != 6)
                        continue;
                    add(acc, uhash[r], static_cast<uint64_t>(d), 1);
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
                    add(acc, e.url_hash, e.date, e.cnt);
        });

    std::vector<Ent> top;
    for (const Ent& e : res.slots)
        if (e.cnt != 0)
            top.push_back(e);

    auto better = [](const Ent& a, const Ent& b)
    {
        if (a.cnt != b.cnt)
            return a.cnt > b.cnt;
        if (a.url_hash != b.url_hash)
            return a.url_hash < b.url_hash;
        return a.date < b.date;
    };
    if (top.size() > kOffset + kLimit)
    {
        std::partial_sort(top.begin(), top.begin() + (kOffset + kLimit), top.end(), better);
        top.resize(kOffset + kLimit);
    }
    else
        std::sort(top.begin(), top.end(), better);
    if (top.size() > kOffset)
        top.erase(top.begin(), top.begin() + kOffset);
    else
        top.clear();
    if (top.size() > kLimit)
        top.resize(kLimit);

    std::vector<int64_t> hashes;
    std::vector<int32_t> dates;
    std::vector<int64_t> counts;
    for (const Ent& e : top)
    {
        hashes.push_back(e.url_hash);
        dates.push_back(static_cast<int32_t>(e.date));
        counts.push_back(static_cast<int64_t>(e.cnt));
    }

    return make_table({
        {"URLHash", integer_column(hashes, {}, arrow::int64())},
        {"EventDate", date_column(dates, {})},
        {"PageViews", integer_column(counts, {}, arrow::int64())},
    });
}
