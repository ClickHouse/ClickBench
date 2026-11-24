#include "query9.hpp"
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
/** SELECT RegionID, COUNT(DISTINCT UserID) AS u FROM hits GROUP BY RegionID ORDER BY u DESC LIMIT 10; */

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
// Direct-indexed per-region counters are used when the stored RegionID range is small.
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

// Per-worker accumulator: distinct-pair count per region (dense when the range is small).
struct Acc
{
    std::vector<uint64_t> dense;
    std::unordered_map<int32_t, uint64_t> sparse;
};
}

std::shared_ptr<arrow::Table> run_q9(Database* db, const Q9Args& args) {
    if (!db) {
        throw std::runtime_error("run_q9: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    if (db->UserID.size() != n_rows || db->RegionID.size() != n_rows) {
        throw std::runtime_error("run_q9: column length does not match row count");
    }
    const int64_t* pu = db->UserID.data();
    const int32_t* pr = db->RegionID.data();

    const int64_t rmin = db->RegionID_min;
    const int64_t rmax = db->RegionID_max;
    const bool use_dense = n_rows > 0 && rmax >= rmin && static_cast<uint64_t>(rmax - rmin) < kDenseMaxRange;
    const uint64_t dense_n = use_dense ? static_cast<uint64_t>(rmax - rmin) + 1 : 0;

    ThreadPool& pool = get_query_pool();

    // Phase 1: contiguous slices; each slice radix-partitions its (UserID, RegionID) pairs by the
    // hash of UserID into private buffers. All pairs of a given UserID land in one partition.
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
            const uint64_t expect = (hi - lo) / kParts;
            for (auto& v : parts)
                v.reserve(expect + expect / 4 + 16);
            for (uint64_t i = lo; i < hi; ++i)
            {
                const uint64_t k = static_cast<uint64_t>(pu[i]);
                parts[mix64(k) >> (64 - kPartBits)].push_back(Pair{pu[i], pr[i], 0});
            }
        },
        [](Acc&, const Acc&) {});

    // Phase 2: partitions are disjoint in UserID, hence in (UserID, RegionID) pairs. Dedup pairs
    // in a private open-addressing set and count each new pair into its region.
    Acc total = parallel_reduce<Acc>(
        pool, static_cast<int64_t>(kParts), Acc{},
        [&](Acc& acc, int64_t p) {
            uint64_t n = 0;
            for (int64_t s = 0; s < n_slices; ++s)
                n += bufs[static_cast<size_t>(s)][static_cast<size_t>(p)].size();
            if (n == 0)
                return;
            if (use_dense && acc.dense.empty())
                acc.dense.assign(dense_n, 0);
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
                            if (use_dense)
                            {
                                const uint64_t idx = static_cast<uint64_t>(static_cast<int64_t>(e.region) - rmin);
                                if (idx >= dense_n)
                                    throw std::runtime_error("run_q9: RegionID outside the stored [min,max]");
                                ++acc.dense[idx];
                            }
                            else
                                ++acc.sparse[e.region];
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
        [](Acc& acc, const Acc& part) {
            if (!part.dense.empty())
            {
                if (acc.dense.empty())
                    acc.dense = part.dense;
                else
                    for (size_t k = 0; k < part.dense.size(); ++k)
                        acc.dense[k] += part.dense[k];
            }
            for (const auto& kv : part.sparse)
                acc.sparse[kv.first] += kv.second;
        });

    std::vector<std::pair<int32_t, uint64_t>> groups;
    for (size_t k = 0; k < total.dense.size(); ++k)
        if (total.dense[k] != 0)
            groups.emplace_back(static_cast<int32_t>(rmin + static_cast<int64_t>(k)), total.dense[k]);
    for (const auto& kv : total.sparse)
        groups.emplace_back(kv.first, kv.second);

    // ORDER BY u DESC LIMIT 10 (ties broken by RegionID ascending for determinism).
    auto cmp = [](const auto& x, const auto& y) {
        if (x.second != y.second)
            return x.second > y.second;
        return x.first < y.first;
    };
    const size_t limit = std::min<size_t>(10, groups.size());
    std::partial_sort(groups.begin(), groups.begin() + static_cast<std::ptrdiff_t>(limit), groups.end(), cmp);
    groups.resize(limit);

    std::vector<int32_t> regions;
    std::vector<int64_t> counts;
    for (const auto& g : groups)
    {
        if (g.second > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
            throw std::runtime_error("run_q9: count exceeds BIGINT");
        regions.push_back(g.first);
        counts.push_back(static_cast<int64_t>(g.second));
    }

    return make_table({
        {"RegionID", integer_column(regions, {}, arrow::int32())},
        {"u", integer_column(counts, {}, arrow::int64())},
    });
}
