#include "query6.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <utility>
#include <vector>

// SQL:
/** SELECT COUNT(DISTINCT SearchPhrase) FROM hits; */

namespace
{
// Private presence bitset over dictionary ids; allocated lazily on first use.
struct Seen
{
    std::vector<uint64_t> bits;
};
}

std::shared_ptr<arrow::Table> run_q6(Database* db, const Q6Args& args) {
    if (!db) {
        throw std::runtime_error("run_q6: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    const auto& col = db->SearchPhrase;
    if (col.ids.size() != n_rows) {
        throw std::runtime_error("run_q6: column length does not match row count");
    }
    const uint32_t* ids = col.ids.data();
    // Dictionary ids are dense in [0, dict.size()); id 0 is the empty string, which is a regular
    // (non-NULL) value for COUNT(DISTINCT).
    const uint64_t dict_n = col.dict.size();
    const uint64_t words = (dict_n + 63) / 64;

    constexpr uint64_t MORSEL = 1ull << 20;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + MORSEL - 1) / MORSEL);

    const Seen total = parallel_reduce<Seen>(
        get_query_pool(), n_morsels, Seen{},
        [&](Seen& acc, int64_t m) {
            if (acc.bits.empty())
                acc.bits.assign(words, 0);
            uint64_t* b = acc.bits.data();
            const uint64_t lo = static_cast<uint64_t>(m) * MORSEL;
            const uint64_t hi = std::min<uint64_t>(lo + MORSEL, n_rows);
            for (uint64_t i = lo; i < hi; ++i)
            {
                const uint32_t id = ids[i];
                b[id >> 6] |= 1ull << (id & 63);
            }
        },
        [](Seen& acc, const Seen& part) {
            if (part.bits.empty())
                return;
            if (acc.bits.empty())
            {
                acc.bits = part.bits;
                return;
            }
            const size_t n = acc.bits.size();
            for (size_t w = 0; w < n; ++w)
                acc.bits[w] |= part.bits[w];
        });

    uint64_t distinct = 0;
    for (const uint64_t w : total.bits)
        distinct += static_cast<uint64_t>(__builtin_popcountll(w));

    if (distinct > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
        throw std::runtime_error("run_q6: count exceeds BIGINT");
    }
    std::vector<int64_t> count_distinct{static_cast<int64_t>(distinct)};

    return make_table({
        {"count(DISTINCT SearchPhrase)", integer_column(count_distinct, {}, arrow::int64())},
    });
}
