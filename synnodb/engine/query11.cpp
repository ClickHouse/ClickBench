#include "query11.hpp"
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
/** SELECT MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM hits WHERE MobilePhoneModel <> '' GROUP BY MobilePhoneModel ORDER BY u DESC LIMIT 10; */

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

constexpr unsigned kPartBits = 8;
constexpr uint64_t kParts = 1ull << kPartBits;

struct Pair
{
    int64_t user;
    uint32_t model;
    uint32_t pad;
};

struct Slot
{
    int64_t user;
    uint32_t model;
    uint32_t used;
};

// Per-worker accumulator: distinct-user count per dictionary id of MobilePhoneModel.
struct Acc
{
    std::vector<uint64_t> counts;
};
}

std::shared_ptr<arrow::Table> run_q11(Database* db, const Q11Args& args) {
    if (!db) {
        throw std::runtime_error("run_q11: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    const auto& col = db->MobilePhoneModel;
    if (db->UserID.size() != n_rows || col.ids.size() != n_rows) {
        throw std::runtime_error("run_q11: column length does not match row count");
    }
    const int64_t* pu = db->UserID.data();
    const uint16_t* pm = col.ids.data();
    const uint64_t dict_n = col.dict.size();

    ThreadPool& pool = get_query_pool();

    // Phase 1: contiguous slices; rows with a non-empty model (id != 0) are radix-partitioned by
    // the hash of UserID, so all pairs of a given UserID land in one partition.
    constexpr uint64_t SLICE = 1ull << 20;
    const int64_t n_slices = static_cast<int64_t>((n_rows + SLICE - 1) / SLICE);
    std::vector<std::vector<std::vector<Pair>>> bufs(static_cast<size_t>(n_slices));
    parallel_reduce<Acc>(
        pool, n_slices, Acc{},
        [&](Acc&, int64_t s) {
            const uint64_t lo = static_cast<uint64_t>(s) * SLICE;
            const uint64_t hi = std::min<uint64_t>(lo + SLICE, n_rows);
            auto& parts = bufs[static_cast<size_t>(s)];
            parts.resize(kParts);
            uint64_t cnt = 0;
            for (uint64_t i = lo; i < hi; ++i)
                cnt += (pm[i] != 0);
            const uint64_t expect = cnt / kParts;
            for (auto& v : parts)
                v.reserve(expect + expect / 4 + 16);
            for (uint64_t i = lo; i < hi; ++i)
            {
                const uint32_t m = pm[i];
                if (m == 0)
                    continue;
                if (m >= dict_n)
                    throw std::runtime_error("run_q11: MobilePhoneModel id outside the dictionary");
                parts[mix64(static_cast<uint64_t>(pu[i])) >> (64 - kPartBits)].push_back(Pair{pu[i], m, 0});
            }
        },
        [](Acc&, const Acc&) {});

    // Phase 2: partitions are disjoint in UserID, hence in (UserID, model) pairs. Dedup pairs in a
    // private open-addressing set and count each new pair into its model.
    Acc total = parallel_reduce<Acc>(
        pool, static_cast<int64_t>(kParts), Acc{},
        [&](Acc& acc, int64_t p) {
            uint64_t n = 0;
            for (int64_t s = 0; s < n_slices; ++s)
                n += bufs[static_cast<size_t>(s)][static_cast<size_t>(p)].size();
            if (n == 0)
                return;
            if (acc.counts.empty())
                acc.counts.assign(dict_n, 0);
            uint64_t cap = 16;
            while (cap < n * 2)
                cap <<= 1;
            const uint64_t mask = cap - 1;
            std::vector<Slot> set(cap, Slot{0, 0, 0});
            for (int64_t s = 0; s < n_slices; ++s)
            {
                auto& v = bufs[static_cast<size_t>(s)][static_cast<size_t>(p)];
                for (const Pair& e : v)
                {
                    uint64_t h = mix64(static_cast<uint64_t>(e.user) + static_cast<uint64_t>(e.model) * 0x9E3779B97F4A7C15ULL) & mask;
                    for (;;)
                    {
                        Slot& sl = set[h];
                        if (!sl.used)
                        {
                            sl.user = e.user;
                            sl.model = e.model;
                            sl.used = 1;
                            ++acc.counts[e.model];
                            break;
                        }
                        if (sl.user == e.user && sl.model == e.model)
                            break;
                        h = (h + 1) & mask;
                    }
                }
                std::vector<Pair>().swap(v);
            }
        },
        [](Acc& acc, const Acc& part) {
            if (part.counts.empty())
                return;
            if (acc.counts.empty())
                acc.counts = part.counts;
            else
                for (size_t k = 0; k < part.counts.size(); ++k)
                    acc.counts[k] += part.counts[k];
        });

    std::vector<std::pair<uint32_t, uint64_t>> groups;
    for (size_t k = 0; k < total.counts.size(); ++k)
        if (total.counts[k] != 0)
            groups.emplace_back(static_cast<uint32_t>(k), total.counts[k]);

    // ORDER BY u DESC LIMIT 10 (ties by dictionary id, i.e. by string bytes ascending).
    auto cmp = [](const auto& x, const auto& y) {
        if (x.second != y.second)
            return x.second > y.second;
        return x.first < y.first;
    };
    const size_t limit = std::min<size_t>(10, groups.size());
    std::partial_sort(groups.begin(), groups.begin() + static_cast<std::ptrdiff_t>(limit), groups.end(), cmp);
    groups.resize(limit);

    std::vector<std::string> models;
    std::vector<int64_t> counts;
    for (const auto& g : groups)
    {
        if (g.second > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
            throw std::runtime_error("run_q11: count exceeds BIGINT");
        models.emplace_back(col.dict.get(g.first));
        counts.push_back(static_cast<int64_t>(g.second));
    }

    return make_table({
        {"MobilePhoneModel", string_column(models)},
        {"u", integer_column(counts, {}, arrow::int64())},
    });
}
