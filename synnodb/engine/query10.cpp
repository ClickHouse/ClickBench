#include "query10.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

// SQL:
/** SELECT RegionID, SUM(AdvEngineID), COUNT(*) AS c, AVG(ResolutionWidth), COUNT(DISTINCT UserID) FROM hits GROUP BY RegionID ORDER BY c DESC LIMIT 10; */

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
// Direct-indexed per-region state is used when the stored RegionID range is small.
constexpr uint64_t kDenseMaxRange = 1ull << 22;

struct Pair
{
    int64_t user;
    int32_t region;
    int32_t pad;
};

struct Slot
{
    int64_t user;
    int32_t region;
    int32_t used;
};

// Per-region exact aggregates. Sums are exact in int64 (rows * 2^15 cannot overflow).
struct Agg
{
    int64_t sum_adv = 0;
    int64_t sum_width = 0;
    uint64_t count = 0;
    uint64_t distinct = 0;
};

inline void add(Agg& a, const Agg& b)
{
    a.sum_adv += b.sum_adv;
    a.sum_width += b.sum_width;
    a.count += b.count;
    a.distinct += b.distinct;
}

// Per-worker accumulator: dense when the RegionID range is small, hash map otherwise.
struct Acc
{
    std::vector<Agg> dense;
    std::unordered_map<int32_t, Agg> sparse;
};

void merge_acc(Acc& acc, const Acc& part)
{
    if (!part.dense.empty())
    {
        if (acc.dense.empty())
            acc.dense = part.dense;
        else
            for (size_t k = 0; k < part.dense.size(); ++k)
                add(acc.dense[k], part.dense[k]);
    }
    for (const auto& kv : part.sparse)
        add(acc.sparse[kv.first], kv.second);
}
}

std::shared_ptr<arrow::Table> run_q10(Database* db, const Q10Args& args) {
    if (!db) {
        throw std::runtime_error("run_q10: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    if (db->UserID.size() != n_rows || db->RegionID.size() != n_rows || db->AdvEngineID.size() != n_rows
        || db->ResolutionWidth.size() != n_rows) {
        throw std::runtime_error("run_q10: column length does not match row count");
    }
    const int64_t* pu = db->UserID.data();
    const int32_t* pr = db->RegionID.data();
    const int16_t* padv = db->AdvEngineID.data();
    const int16_t* pw = db->ResolutionWidth.data();

    const int64_t rmin = db->RegionID_min;
    const int64_t rmax = db->RegionID_max;
    const bool use_dense = n_rows > 0 && rmax >= rmin && static_cast<uint64_t>(rmax - rmin) < kDenseMaxRange;
    const uint64_t dense_n = use_dense ? static_cast<uint64_t>(rmax - rmin) + 1 : 0;

    auto slot_of = [&](Acc& acc, int32_t region) -> Agg& {
        if (use_dense)
        {
            const uint64_t idx = static_cast<uint64_t>(static_cast<int64_t>(region) - rmin);
            if (idx >= dense_n)
                throw std::runtime_error("run_q10: RegionID outside the stored [min,max]");
            return acc.dense[idx];
        }
        return acc.sparse[region];
    };

    ThreadPool& pool = get_query_pool();

    // Phase 1: contiguous slices. Each slice (a) folds SUM/COUNT/AVG state into its worker's
    // private per-region accumulator and (b) radix-partitions its (UserID, RegionID) pairs by the
    // hash of UserID into private buffers for the distinct count.
    constexpr uint64_t SLICE = 1ull << 20;
    const int64_t n_slices = static_cast<int64_t>((n_rows + SLICE - 1) / SLICE);
    std::vector<std::vector<std::vector<Pair>>> bufs(static_cast<size_t>(n_slices));
    Acc totals = parallel_reduce<Acc>(
        pool, n_slices, Acc{},
        [&](Acc& acc, int64_t s) {
            if (use_dense && acc.dense.empty())
                acc.dense.assign(dense_n, Agg{});
            const uint64_t lo = static_cast<uint64_t>(s) * SLICE;
            const uint64_t hi = std::min<uint64_t>(lo + SLICE, n_rows);
            auto& parts = bufs[static_cast<size_t>(s)];
            parts.resize(kParts);
            const uint64_t expect = (hi - lo) / kParts;
            for (auto& v : parts)
                v.reserve(expect + expect / 4 + 16);
            for (uint64_t i = lo; i < hi; ++i)
            {
                Agg& a = slot_of(acc, pr[i]);
                a.sum_adv += padv[i];
                a.sum_width += pw[i];
                ++a.count;
                const uint64_t k = static_cast<uint64_t>(pu[i]);
                parts[mix64(k) >> (64 - kPartBits)].push_back(Pair{pu[i], pr[i], 0});
            }
        },
        merge_acc);

    // Phase 2: partitions are disjoint in UserID, hence in (UserID, RegionID) pairs. Dedup pairs
    // in a private open-addressing set and count each new pair into its region.
    Acc distinct = parallel_reduce<Acc>(
        pool, static_cast<int64_t>(kParts), Acc{},
        [&](Acc& acc, int64_t p) {
            uint64_t n = 0;
            for (int64_t s = 0; s < n_slices; ++s)
                n += bufs[static_cast<size_t>(s)][static_cast<size_t>(p)].size();
            if (n == 0)
                return;
            if (use_dense && acc.dense.empty())
                acc.dense.assign(dense_n, Agg{});
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
                    uint64_t h = mix64(static_cast<uint64_t>(e.user) + static_cast<uint64_t>(static_cast<uint32_t>(e.region)) * 0x9E3779B97F4A7C15ULL) & mask;
                    for (;;)
                    {
                        Slot& sl = set[h];
                        if (!sl.used)
                        {
                            sl.user = e.user;
                            sl.region = e.region;
                            sl.used = 1;
                            ++slot_of(acc, e.region).distinct;
                            break;
                        }
                        if (sl.user == e.user && sl.region == e.region)
                            break;
                        h = (h + 1) & mask;
                    }
                }
                std::vector<Pair>().swap(v);
            }
        },
        merge_acc);
    merge_acc(totals, distinct);

    std::vector<std::pair<int32_t, Agg>> groups;
    for (size_t k = 0; k < totals.dense.size(); ++k)
        if (totals.dense[k].count != 0)
            groups.emplace_back(static_cast<int32_t>(rmin + static_cast<int64_t>(k)), totals.dense[k]);
    for (const auto& kv : totals.sparse)
        groups.emplace_back(kv.first, kv.second);

    // ORDER BY c DESC LIMIT 10 (ties broken by RegionID ascending for determinism).
    auto cmp = [](const auto& x, const auto& y) {
        if (x.second.count != y.second.count)
            return x.second.count > y.second.count;
        return x.first < y.first;
    };
    const size_t limit = std::min<size_t>(10, groups.size());
    std::partial_sort(groups.begin(), groups.begin() + static_cast<std::ptrdiff_t>(limit), groups.end(), cmp);
    groups.resize(limit);

    std::vector<int32_t> regions;
    std::vector<__int128> sum_adv;
    std::vector<int64_t> counts;
    std::vector<double> avg_width;
    std::vector<int64_t> distinct_users;
    for (const auto& g : groups)
    {
        const Agg& a = g.second;
        if (a.count > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())
            || a.distinct > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
            throw std::runtime_error("run_q10: count exceeds BIGINT");
        regions.push_back(g.first);
        sum_adv.push_back(static_cast<__int128>(a.sum_adv));
        counts.push_back(static_cast<int64_t>(a.count));
        avg_width.push_back(static_cast<double>(a.sum_width) / static_cast<double>(a.count));
        distinct_users.push_back(static_cast<int64_t>(a.distinct));
    }

    return make_table({
        {"RegionID", integer_column(regions, {}, arrow::int32())},
        {"sum(AdvEngineID)", hugeint_column(sum_adv)},
        {"c", integer_column(counts, {}, arrow::int64())},
        {"avg(ResolutionWidth)", double_column(avg_width)},
        {"count(DISTINCT UserID)", integer_column(distinct_users, {}, arrow::int64())},
    });
}
