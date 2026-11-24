#include "query7.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <utility>
#include <vector>

// SQL:
/** SELECT MIN(EventDate), MAX(EventDate) FROM hits; */

namespace
{
struct MinMax
{
    uint16_t mn = std::numeric_limits<uint16_t>::max();
    uint16_t mx = 0;
    bool any = false;
};
}

std::shared_ptr<arrow::Table> run_q7(Database* db, const Q7Args& args) {
    if (!db) {
        throw std::runtime_error("run_q7: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    if (db->EventDate.size() != n_rows) {
        throw std::runtime_error("run_q7: column length does not match row count");
    }
    const uint16_t* d = db->EventDate.data();

    constexpr uint64_t MORSEL = 1ull << 18;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + MORSEL - 1) / MORSEL);

    // Computed from the base column at query time (branch-free, auto-vectorizable min/max loop).
    const MinMax r = parallel_reduce<MinMax>(
        get_query_pool(), n_morsels, MinMax{},
        [&](MinMax& acc, int64_t m) {
            const uint64_t lo = static_cast<uint64_t>(m) * MORSEL;
            const uint64_t hi = std::min<uint64_t>(lo + MORSEL, n_rows);
            uint16_t mn = acc.mn;
            uint16_t mx = acc.mx;
            for (uint64_t i = lo; i < hi; ++i)
            {
                const uint16_t v = d[i];
                mn = v < mn ? v : mn;
                mx = v > mx ? v : mx;
            }
            acc.mn = mn;
            acc.mx = mx;
            acc.any = acc.any || hi > lo;
        },
        [](MinMax& acc, const MinMax& part) {
            acc.mn = std::min(acc.mn, part.mn);
            acc.mx = std::max(acc.mx, part.mx);
            acc.any = acc.any || part.any;
        });

    // MIN/MAX over an empty table is NULL.
    const Validity valid{static_cast<uint8_t>(r.any ? 1 : 0)};
    std::vector<int32_t> mn{r.any ? static_cast<int32_t>(r.mn) : 0};
    std::vector<int32_t> mx{r.any ? static_cast<int32_t>(r.mx) : 0};

    return make_table({
        {"min(EventDate)", date_column(mn, valid)},
        {"max(EventDate)", date_column(mx, valid)},
    });
}
