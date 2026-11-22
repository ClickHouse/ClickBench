#include "query4.hpp"
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
/** SELECT AVG(UserID) FROM hits; */

namespace
{
struct Q4Acc
{
    __int128 sum = 0;
    uint64_t count = 0;
};
}

std::shared_ptr<arrow::Table> run_q4(Database* db, const Q4Args& args) {
    if (!db) {
        throw std::runtime_error("run_q4: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    const std::vector<int64_t>& user = db->UserID;
    if (user.size() != n_rows) {
        throw std::runtime_error("run_q4: column length does not match row count");
    }

    // Morsels are contiguous row ranges. UserID is a 64-bit value, so a slice keeps an exact sum
    // as (wrapping 64-bit sum of the two's-complement words, carry count, negative count):
    //   sum(signed) = acc + (carries - negatives) * 2^64.
    // The partials merge by exact 128-bit addition.
    ThreadPool& pool = get_query_pool();
    constexpr uint64_t MORSEL = 1ull << 16;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + MORSEL - 1) / MORSEL);
    const int64_t* pu = user.data();

    const Q4Acc total = parallel_reduce<Q4Acc>(
        pool, n_morsels, Q4Acc{},
        [&](Q4Acc& local, int64_t m) {
            const uint64_t lo = static_cast<uint64_t>(m) * MORSEL;
            const uint64_t hi = std::min<uint64_t>(lo + MORSEL, n_rows);
            uint64_t acc = 0;
            uint64_t carries = 0;
            uint64_t negatives = 0;
            for (uint64_t i = lo; i < hi; ++i)
            {
                const uint64_t v = static_cast<uint64_t>(pu[i]);
                acc += v;
                carries += static_cast<uint64_t>(acc < v);
                negatives += v >> 63;
            }
            __int128 s = static_cast<__int128>(acc);
            s += (static_cast<__int128>(carries) - static_cast<__int128>(negatives)) * (static_cast<__int128>(1) << 64);
            local.sum += s;
            local.count += hi - lo;
        },
        [](Q4Acc& acc, const Q4Acc& part) {
            acc.sum += part.sum;
            acc.count += part.count;
        });

    // AVG(BIGINT) is DOUBLE in DuckDB; it is NULL on an empty input.
    const bool non_empty = total.count > 0;
    std::vector<double> avg_user{
        non_empty ? static_cast<double>(total.sum) / static_cast<double>(total.count) : 0.0};
    Validity valid{static_cast<uint8_t>(non_empty ? 1 : 0)};

    return make_table({
        {"avg(UserID)", double_column(avg_user, valid)},
    });
}
