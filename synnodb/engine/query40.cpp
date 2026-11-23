#include "query40.hpp"
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
/** SELECT TraficSourceID, SearchEngineID, AdvEngineID, CASE WHEN (SearchEngineID = 0 AND AdvEngineID = 0) THEN Referer ELSE '' END AS Src, URL AS Dst, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 GROUP BY TraficSourceID, SearchEngineID, AdvEngineID, Src, Dst ORDER BY PageViews DESC LIMIT 10 OFFSET 1000; */

namespace {

constexpr size_t kLimit = 10;
constexpr size_t kOffset = 1000;

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
    uint64_t meta = 0;  // uint16(trafic)<<32 | uint16(engine)<<16 | uint16(adv)
};

struct Table
{
    std::vector<Ent> slots;
    uint64_t used = 0;
};

inline bool has_src(uint64_t meta)
{
    return (meta & 0xFFFFFFFFULL) == 0;  // SearchEngineID == 0 and AdvEngineID == 0
}

}

std::shared_ptr<arrow::Table> run_q40(Database* db, const Q40Args& args) {
    if (!db) {
        throw std::runtime_error("run_q40: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    static_assert(kSuperRows % kChunkRows == 0, "morsels must not straddle super-chunks");

    const StringArena& url = db->URL;
    const StringArena& ref = db->Referer;
    const uint64_t n_rows = db->n_rows;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + kChunkRows - 1) / kChunkRows);
    if (url.rows != n_rows || ref.rows != n_rows) {
        throw std::runtime_error("run_q40: string column shape does not match the table");
    }

    const int32_t* counter = db->CounterID.data();
    const uint16_t* date = db->EventDate.data();
    const uint8_t* refresh = db->IsRefresh.data();
    const int16_t* trafic = db->TraficSourceID.data();
    const int16_t* engine = db->SearchEngineID.data();
    const int16_t* adv = db->AdvEngineID.data();

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

    auto add = [&](Table& t, uint64_t h, uint64_t row, uint64_t meta, uint64_t c)
    {
        if (t.slots.empty() || (t.used + 1) * 2 > t.slots.size())
            grow(t);
        const uint64_t mask = t.slots.size() - 1;
        const std::string_view key = url.get(row);
        const bool src = has_src(meta);
        const std::string_view rkey = src ? ref.get(row) : std::string_view();
        uint64_t p = h & mask;
        for (;;)
        {
            Ent& e = t.slots[p];
            if (e.cnt == 0)
            {
                e.hash = h;
                e.cnt = c;
                e.row = row;
                e.meta = meta;
                ++t.used;
                return;
            }
            if (e.hash == h && e.meta == meta && url.get(e.row) == key && (!src || ref.get(e.row) == rkey))
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
            const uint64_t lo = c * kChunkRows;
            const uint64_t hi = std::min<uint64_t>(lo + kChunkRows, n_rows);
            const uint64_t s = lo / kSuperRows;
            const uint64_t j0 = lo % kSuperRows;
            const uint32_t* uo = url.offs.data() + s * (kSuperRows + 1);
            const char* ub = url.bytes.data() + url.base[s];
            const uint32_t* ro = ref.offs.data() + s * (kSuperRows + 1);
            const char* rb = ref.bytes.data() + ref.base[s];

            // Branch-free, vectorizable candidate pass on the most selective predicate.
            constexpr uint64_t kBlock = 2048;
            std::array<uint32_t, kBlock> cand;
            for (uint64_t b = lo; b < hi; b += kBlock)
            {
                const uint64_t e = std::min<uint64_t>(b + kBlock, hi);
                size_t nc = 0;
                for (uint64_t r = b; r < e; ++r)
                {
                    cand[nc] = static_cast<uint32_t>(r - b);
                    nc += (counter[r] == kCounter);
                }
                for (size_t k = 0; k < nc; ++k)
                {
                    const uint64_t r = b + cand[k];
                    const int64_t d = date[r];
                    if (d < kDateLo || d > kDateHi)
                        continue;
                    if (refresh[r] != 0)
                        continue;
                    const uint64_t meta = (static_cast<uint64_t>(static_cast<uint16_t>(trafic[r])) << 32)
                        | (static_cast<uint64_t>(static_cast<uint16_t>(engine[r])) << 16)
                        | static_cast<uint64_t>(static_cast<uint16_t>(adv[r]));
                    const uint64_t j = j0 + (r - lo);
                    uint64_t h = hash_bytes(ub + uo[j], uo[j + 1] - uo[j]);
                    if (has_src(meta))
                        h = mix64(h ^ hash_bytes(rb + ro[j], ro[j + 1] - ro[j]));
                    h = mix64(h ^ (meta * 0x9E3779B97F4A7C15ULL));
                    add(acc, h, r, meta, 1);
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
                    add(acc, e.hash, e.row, e.meta, e.cnt);
        });

    struct Group
    {
        uint64_t cnt;
        uint64_t row;
        uint64_t meta;
    };
    std::vector<Group> top;
    for (const Ent& e : res.slots)
        if (e.cnt != 0)
            top.push_back(Group{e.cnt, e.row, e.meta});

    auto better = [&](const Group& a, const Group& b)
    {
        if (a.cnt != b.cnt)
            return a.cnt > b.cnt;
        // Deterministic tie-break: signed trafic, engine, adv, Src, Dst.
        const int16_t at = static_cast<int16_t>(a.meta >> 32), bt = static_cast<int16_t>(b.meta >> 32);
        if (at != bt)
            return at < bt;
        const int16_t ae = static_cast<int16_t>(a.meta >> 16), be = static_cast<int16_t>(b.meta >> 16);
        if (ae != be)
            return ae < be;
        const int16_t aa = static_cast<int16_t>(a.meta), ba = static_cast<int16_t>(b.meta);
        if (aa != ba)
            return aa < ba;
        if (has_src(a.meta))
        {
            const std::string_view ra = ref.get(a.row), rb2 = ref.get(b.row);
            if (ra != rb2)
                return ra < rb2;
        }
        return url.get(a.row) < url.get(b.row);
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

    std::vector<int16_t> traf, eng, ad;
    std::vector<std::string> srcs, dsts;
    std::vector<int64_t> counts;
    for (const Group& g : top)
    {
        traf.push_back(static_cast<int16_t>(g.meta >> 32));
        eng.push_back(static_cast<int16_t>(g.meta >> 16));
        ad.push_back(static_cast<int16_t>(g.meta));
        srcs.emplace_back(has_src(g.meta) ? ref.get(g.row) : std::string_view());
        dsts.emplace_back(url.get(g.row));
        counts.push_back(static_cast<int64_t>(g.cnt));
    }

    return make_table({
        {"TraficSourceID", integer_column(traf, {}, arrow::int16())},
        {"SearchEngineID", integer_column(eng, {}, arrow::int16())},
        {"AdvEngineID", integer_column(ad, {}, arrow::int16())},
        {"Src", string_column(srcs)},
        {"Dst", string_column(dsts)},
        {"PageViews", integer_column(counts, {}, arrow::int64())},
    });
}
