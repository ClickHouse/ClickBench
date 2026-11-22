#include "query3.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

// SQL:
/** SELECT SUM(AdvEngineID), COUNT(*), AVG(ResolutionWidth) FROM hits; */

namespace
{
struct Q3Acc
{
    __int128 sum_adv = 0;
    __int128 sum_width = 0;
    uint64_t count = 0;
};
}

std::shared_ptr<arrow::Table> run_q3(Database* db, const Q3Args& args) {
    if (!db) {
        throw std::runtime_error("run_q3: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    const std::vector<int16_t>& adv = db->AdvEngineID;
    const std::vector<int16_t>& width = db->ResolutionWidth;
    if (adv.size() != n_rows || width.size() != n_rows) {
        throw std::runtime_error("run_q3: column length does not match row count");
    }

    // Morsels are contiguous row ranges. Each fold keeps private exact integer sums (an int64
    // partial per morsel cannot overflow: 2^16 * 2^15 < 2^63) and the partials merge by addition.
    ThreadPool& pool = get_query_pool();
    constexpr uint64_t MORSEL = 1ull << 16;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + MORSEL - 1) / MORSEL);
    const int16_t* pa = adv.data();
    const int16_t* pw = width.data();

    const Q3Acc total = parallel_reduce<Q3Acc>(
        pool, n_morsels, Q3Acc{},
        [&](Q3Acc& local, int64_t m) {
            const uint64_t lo = static_cast<uint64_t>(m) * MORSEL;
            const uint64_t hi = std::min<uint64_t>(lo + MORSEL, n_rows);
            int64_t sa = 0;
            int64_t sw = 0;
            // Branch-free widening sums; the compiler vectorizes this loop for the target.
            for (uint64_t i = lo; i < hi; ++i)
            {
                sa += pa[i];
                sw += pw[i];
            }
            local.sum_adv += sa;
            local.sum_width += sw;
            local.count += hi - lo;
        },
        [](Q3Acc& acc, const Q3Acc& part) {
            acc.sum_adv += part.sum_adv;
            acc.sum_width += part.sum_width;
            acc.count += part.count;
        });

    if (total.count > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
        throw std::runtime_error("run_q3: count exceeds BIGINT");
    }

    // SUM(smallint) is HUGEINT in DuckDB; AVG(smallint) is DOUBLE. On an empty table SUM and AVG
    // are NULL.
    const bool non_empty = total.count > 0;
    std::vector<__int128> sum_adv{total.sum_adv};
    std::vector<int64_t> count_star{static_cast<int64_t>(total.count)};
    std::vector<double> avg_width{
        non_empty ? static_cast<double>(total.sum_width) / static_cast<double>(total.count) : 0.0};
    Validity valid{static_cast<uint8_t>(non_empty ? 1 : 0)};

    return make_table({
        {"sum(AdvEngineID)", hugeint_column(sum_adv, valid)},
        {"count_star()", integer_column(count_star, {}, arrow::int64())},
        {"avg(ResolutionWidth)", double_column(avg_width, valid)},
    });
}
