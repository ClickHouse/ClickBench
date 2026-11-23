#include "query8.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <utility>
#include <vector>

// SQL:
/** SELECT AdvEngineID, COUNT(*) FROM hits WHERE AdvEngineID <> 0 GROUP BY AdvEngineID ORDER BY COUNT(*) DESC; */

namespace
{
// Private histogram over the full 16-bit key domain (indexed by the raw 16 bits of the key);
// allocated lazily on first non-skipped morsel.
struct Hist
{
    std::vector<uint64_t> cnt;
};
}

std::shared_ptr<arrow::Table> run_q8(Database* db, const Q8Args& args) {
    if (!db) {
        throw std::runtime_error("run_q8: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    if (db->AdvEngineID.size() != n_rows) {
        throw std::runtime_error("run_q8: column length does not match row count");
    }
    const int16_t* a = db->AdvEngineID.data();
    const auto& zmn = db->zone_AdvEngineID.mn;
    const auto& zmx = db->zone_AdvEngineID.mx;

    constexpr uint64_t CHUNK = 1ull << 16;  // one zone-map entry per chunk (kChunkRows)
    const int64_t n_chunks = static_cast<int64_t>((n_rows + CHUNK - 1) / CHUNK);
    if (zmn.size() != static_cast<size_t>(n_chunks) || zmx.size() != static_cast<size_t>(n_chunks)) {
        throw std::runtime_error("run_q8: zone map size does not match chunk count");
    }

    const Hist total = parallel_reduce<Hist>(
        get_query_pool(), n_chunks, Hist{},
        [&](Hist& acc, int64_t c) {
            // The chunk contains only the filtered-out value 0: skip it.
            if (zmn[static_cast<size_t>(c)] == 0 && zmx[static_cast<size_t>(c)] == 0)
                return;
            if (acc.cnt.empty())
                acc.cnt.assign(65536, 0);
            uint64_t* h = acc.cnt.data();
            const uint64_t lo = static_cast<uint64_t>(c) * CHUNK;
            const uint64_t hi = std::min<uint64_t>(lo + CHUNK, n_rows);
            for (uint64_t i = lo; i < hi; ++i)
                ++h[static_cast<uint16_t>(a[i])];
        },
        [](Hist& acc, const Hist& part) {
            if (part.cnt.empty())
                return;
            if (acc.cnt.empty())
            {
                acc.cnt = part.cnt;
                return;
            }
            for (size_t k = 0; k < 65536; ++k)
                acc.cnt[k] += part.cnt[k];
        });

    // Collect the groups with AdvEngineID <> 0.
    std::vector<std::pair<int16_t, uint64_t>> groups;
    if (!total.cnt.empty())
    {
        for (uint32_t k = 0; k < 65536; ++k)
        {
            const int16_t key = static_cast<int16_t>(static_cast<uint16_t>(k));
            if (key != 0 && total.cnt[k] != 0)
                groups.emplace_back(key, total.cnt[k]);
        }
    }
    // ORDER BY COUNT(*) DESC (ties broken by key ascending for determinism).
    std::sort(groups.begin(), groups.end(), [](const auto& x, const auto& y) {
        if (x.second != y.second)
            return x.second > y.second;
        return x.first < y.first;
    });

    std::vector<int16_t> keys;
    std::vector<int64_t> counts;
    keys.reserve(groups.size());
    counts.reserve(groups.size());
    for (const auto& g : groups)
    {
        if (g.second > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
            throw std::runtime_error("run_q8: count exceeds BIGINT");
        keys.push_back(g.first);
        counts.push_back(static_cast<int64_t>(g.second));
    }

    return make_table({
        {"AdvEngineID", integer_column(keys, {}, arrow::int16())},
        {"count_star()", integer_column(counts, {}, arrow::int64())},
    });
}
