#include "query13.hpp"
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
/** SELECT SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10; */

namespace
{
// Per-worker histogram over dictionary ids (allocated lazily, sized from the dictionary).
struct Hist
{
    std::vector<uint64_t> counts;
};
}

std::shared_ptr<arrow::Table> run_q13(Database* db, const Q13Args& args) {
    if (!db) {
        throw std::runtime_error("run_q13: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    const auto& col = db->SearchPhrase;
    if (col.ids.size() != n_rows) {
        throw std::runtime_error("run_q13: column length does not match row count");
    }
    const auto* ids = col.ids.data();
    const uint64_t dict_n = col.dict.size();

    constexpr uint64_t MORSEL = 1ull << 18;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + MORSEL - 1) / MORSEL);

    Hist total = parallel_reduce<Hist>(
        get_query_pool(), n_morsels, Hist{},
        [&](Hist& h, int64_t m) {
            if (h.counts.empty())
                h.counts.assign(dict_n, 0);
            uint64_t* cnt = h.counts.data();
            const uint64_t lo = static_cast<uint64_t>(m) * MORSEL;
            const uint64_t hi = std::min<uint64_t>(lo + MORSEL, n_rows);
            for (uint64_t i = lo; i < hi; ++i)
            {
                const uint64_t id = ids[i];
                if (id >= dict_n)
                    throw std::runtime_error("run_q13: SearchPhrase id outside the dictionary");
                ++cnt[id];
            }
        },
        [](Hist& acc, const Hist& part) {
            if (part.counts.empty())
                return;
            if (acc.counts.empty())
            {
                acc.counts = part.counts;
                return;
            }
            for (size_t k = 0; k < part.counts.size(); ++k)
                acc.counts[k] += part.counts[k];
        });

    // id 0 is the empty string, which the WHERE clause removes.
    std::vector<std::pair<uint64_t, uint64_t>> groups;  // (id, count)
    for (size_t k = 1; k < total.counts.size(); ++k)
        if (total.counts[k] != 0)
            groups.emplace_back(k, total.counts[k]);

    // ORDER BY c DESC LIMIT 10 (ties by dictionary id, i.e. string bytes ascending).
    auto cmp = [](const auto& x, const auto& y) {
        if (x.second != y.second)
            return x.second > y.second;
        return x.first < y.first;
    };
    const size_t limit = std::min<size_t>(10, groups.size());
    std::partial_sort(groups.begin(), groups.begin() + static_cast<std::ptrdiff_t>(limit), groups.end(), cmp);
    groups.resize(limit);

    std::vector<std::string> phrases;
    std::vector<int64_t> counts;
    for (const auto& g : groups)
    {
        if (g.second > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
            throw std::runtime_error("run_q13: count exceeds BIGINT");
        phrases.emplace_back(col.dict.get(g.first));
        counts.push_back(static_cast<int64_t>(g.second));
    }

    return make_table({
        {"SearchPhrase", string_column(phrases)},
        {"c", integer_column(counts, {}, arrow::int64())},
    });
}
