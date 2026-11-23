#include "query15.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

// SQL:
/** SELECT SearchEngineID, SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' GROUP BY SearchEngineID, SearchPhrase ORDER BY c DESC LIMIT 10; */

namespace
{
inline uint64_t mix64(uint64_t x)
{
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

// Group key: (uint16 engine) << 32 | phrase dictionary id.
struct Ent
{
    uint64_t key;
    uint64_t cnt;  // 0 means the slot is empty (every stored group has count >= 1)
};

// Flat open-addressing key -> count table (linear probing, grows at 50% load).
struct Table
{
    std::vector<Ent> slots;
    uint64_t used = 0;

    void init(uint64_t cap)
    {
        slots.assign(cap, Ent{0, 0});
        used = 0;
    }

    void add(uint64_t key, uint64_t n)
    {
        if (slots.empty())
            init(1024);
        uint64_t mask = slots.size() - 1;
        uint64_t h = mix64(key) & mask;
        for (;;)
        {
            Ent& e = slots[h];
            if (e.cnt == 0)
            {
                e.key = key;
                e.cnt = n;
                if (++used * 2 > slots.size())
                    grow();
                return;
            }
            if (e.key == key)
            {
                e.cnt += n;
                return;
            }
            h = (h + 1) & mask;
        }
    }

    void grow()
    {
        std::vector<Ent> old;
        old.swap(slots);
        init(old.size() * 2);
        const uint64_t mask = slots.size() - 1;
        for (const Ent& e : old)
        {
            if (e.cnt == 0)
                continue;
            uint64_t h = mix64(e.key) & mask;
            while (slots[h].cnt != 0)
                h = (h + 1) & mask;
            slots[h] = e;
            ++used;
        }
    }
};

struct Acc
{
    Table t;
};
}

std::shared_ptr<arrow::Table> run_q15(Database* db, const Q15Args& args) {
    if (!db) {
        throw std::runtime_error("run_q15: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    const auto& col = db->SearchPhrase;
    if (db->SearchEngineID.size() != n_rows || col.ids.size() != n_rows) {
        throw std::runtime_error("run_q15: column length does not match row count");
    }
    const int16_t* pe = db->SearchEngineID.data();
    const auto* pm = col.ids.data();
    const uint64_t dict_n = col.dict.size();
    if (dict_n > std::numeric_limits<uint32_t>::max()) {
        throw std::runtime_error("run_q15: SearchPhrase dictionary too large");
    }

    constexpr uint64_t MORSEL = 1ull << 18;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + MORSEL - 1) / MORSEL);

    Acc total = parallel_reduce<Acc>(
        get_query_pool(), n_morsels, Acc{},
        [&](Acc& acc, int64_t m) {
            const uint64_t lo = static_cast<uint64_t>(m) * MORSEL;
            const uint64_t hi = std::min<uint64_t>(lo + MORSEL, n_rows);
            for (uint64_t i = lo; i < hi; ++i)
            {
                const uint64_t id = pm[i];
                if (id == 0)
                    continue;
                if (id >= dict_n)
                    throw std::runtime_error("run_q15: SearchPhrase id outside the dictionary");
                acc.t.add((static_cast<uint64_t>(static_cast<uint16_t>(pe[i])) << 32) | id, 1);
            }
        },
        [](Acc& acc, const Acc& part) {
            if (acc.t.slots.empty())
            {
                acc.t = part.t;
                return;
            }
            for (const Ent& e : part.t.slots)
                if (e.cnt != 0)
                    acc.t.add(e.key, e.cnt);
        });

    std::vector<std::pair<uint64_t, uint64_t>> groups;  // (key, count)
    for (const Ent& e : total.t.slots)
        if (e.cnt != 0)
            groups.emplace_back(e.key, e.cnt);

    // ORDER BY c DESC LIMIT 10 (ties by key: engine id, then dictionary id i.e. string ascending).
    // The engine is compared as a signed value.
    auto engine_of = [](uint64_t key) { return static_cast<int16_t>(static_cast<uint16_t>(key >> 32)); };
    auto cmp = [&](const auto& x, const auto& y) {
        if (x.second != y.second)
            return x.second > y.second;
        const int16_t ex = engine_of(x.first), ey = engine_of(y.first);
        if (ex != ey)
            return ex < ey;
        return static_cast<uint32_t>(x.first) < static_cast<uint32_t>(y.first);
    };
    const size_t limit = std::min<size_t>(10, groups.size());
    std::partial_sort(groups.begin(), groups.begin() + static_cast<std::ptrdiff_t>(limit), groups.end(), cmp);
    groups.resize(limit);

    std::vector<int16_t> engines;
    std::vector<std::string> phrases;
    std::vector<int64_t> counts;
    for (const auto& g : groups)
    {
        if (g.second > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
            throw std::runtime_error("run_q15: count exceeds BIGINT");
        engines.push_back(engine_of(g.first));
        phrases.emplace_back(col.dict.get(static_cast<uint32_t>(g.first)));
        counts.push_back(static_cast<int64_t>(g.second));
    }

    return make_table({
        {"SearchEngineID", integer_column(engines, {}, arrow::int16())},
        {"SearchPhrase", string_column(phrases)},
        {"c", integer_column(counts, {}, arrow::int64())},
    });
}
