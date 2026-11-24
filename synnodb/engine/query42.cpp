#include "query42.hpp"
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
/** SELECT WindowClientWidth, WindowClientHeight, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND DontCountHits = 0 AND URLHash = 2868770270353813622 GROUP BY WindowClientWidth, WindowClientHeight ORDER BY PageViews DESC LIMIT 10 OFFSET 10000; */

namespace {

constexpr size_t kLimit = 10;
constexpr size_t kOffset = 10000;

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
constexpr int64_t kUrlHash = 2868770270353813622LL;

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
    uint64_t key = 0;  // uint16(width)<<16 | uint16(height)
    uint64_t cnt = 0;  // 0 == empty
};

struct Table
{
    std::vector<Ent> slots;
    uint64_t used = 0;
};

inline uint64_t hash_key(uint64_t k)
{
    return mix64(k);
}

}

std::shared_ptr<arrow::Table> run_q42(Database* db, const Q42Args& args) {
    if (!db) {
        throw std::runtime_error("run_q42: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + kChunkRows - 1) / kChunkRows);

    const int32_t* counter = db->CounterID.data();
    const uint16_t* date = db->EventDate.data();
    const uint8_t* refresh = db->IsRefresh.data();
    const uint8_t* dch = db->DontCountHits.data();
    const int64_t* uhash = db->URLHash.data();
    const int16_t* ww = db->WindowClientWidth.data();
    const int16_t* wh = db->WindowClientHeight.data();

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
            uint64_t p = hash_key(e.key) & mask;
            while (t.slots[p].cnt != 0)
                p = (p + 1) & mask;
            t.slots[p] = e;
        }
    };

    auto add = [&](Table& t, uint64_t k, uint64_t c)
    {
        if (t.slots.empty() || (t.used + 1) * 2 > t.slots.size())
            grow(t);
        const uint64_t mask = t.slots.size() - 1;
        uint64_t p = hash_key(k) & mask;
        for (;;)
        {
            Ent& e = t.slots[p];
            if (e.cnt == 0)
            {
                e.key = k;
                e.cnt = c;
                ++t.used;
                return;
            }
            if (e.key == k)
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
            if (db->zone_DontCountHits.mn[c] != 0)
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
                    nc += (counter[r] == kCounter) & (uhash[r] == kUrlHash);
                }
                for (size_t k = 0; k < nc; ++k)
                {
                    const uint64_t r = b + cand[k];
                    const int64_t d = date[r];
                    if (d < kDateLo || d > kDateHi)
                        continue;
                    if (refresh[r] != 0)
                        continue;
                    if (dch[r] != 0)
                        continue;
                    const uint64_t gk = (static_cast<uint64_t>(static_cast<uint16_t>(ww[r])) << 16)
                        | static_cast<uint64_t>(static_cast<uint16_t>(wh[r]));
                    add(acc, gk, 1);
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
                    add(acc, e.key, e.cnt);
        });

    std::vector<Ent> top;
    for (const Ent& e : res.slots)
        if (e.cnt != 0)
            top.push_back(e);

    auto better = [](const Ent& a, const Ent& b)
    {
        if (a.cnt != b.cnt)
            return a.cnt > b.cnt;
        const int16_t aw = static_cast<int16_t>(a.key >> 16), bw = static_cast<int16_t>(b.key >> 16);
        if (aw != bw)
            return aw < bw;
        return static_cast<int16_t>(a.key) < static_cast<int16_t>(b.key);
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

    std::vector<int16_t> widths, heights;
    std::vector<int64_t> counts;
    for (const Ent& e : top)
    {
        widths.push_back(static_cast<int16_t>(e.key >> 16));
        heights.push_back(static_cast<int16_t>(e.key));
        counts.push_back(static_cast<int64_t>(e.cnt));
    }

    return make_table({
        {"WindowClientWidth", integer_column(widths, {}, arrow::int16())},
        {"WindowClientHeight", integer_column(heights, {}, arrow::int16())},
        {"PageViews", integer_column(counts, {}, arrow::int64())},
    });
}
