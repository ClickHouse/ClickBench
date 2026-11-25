#include "query30.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

// SQL:
/** SELECT SUM(ResolutionWidth), SUM(ResolutionWidth + 1), ..., SUM(ResolutionWidth + 89) FROM hits; */

namespace {

struct Acc
{
    int64_t sum = 0;  // per-morsel sums are small enough for int64; widened on merge
    __int128 total = 0;
    uint64_t cnt = 0;
};

}

std::shared_ptr<arrow::Table> run_q30(Database* db, const Q30Args& args) {
    if (!db) {
        throw std::runtime_error("run_q30: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const std::vector<int16_t>& w = db->ResolutionWidth;
    const uint64_t n_rows = db->n_rows;
    if (w.size() != n_rows) {
        throw std::runtime_error("run_q30: column row count does not match the table");
    }
    constexpr uint64_t kMorsel = 1ull << 18;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + kMorsel - 1) / kMorsel);

    // SUM(w + k) = SUM(w) + k * COUNT(*): one pass computes SUM(w) and the row count exactly.
    Acc total = parallel_reduce<Acc>(
        get_query_pool(), n_morsels, Acc{},
        [&](Acc& acc, int64_t m) {
            const uint64_t lo = static_cast<uint64_t>(m) * kMorsel;
            const uint64_t hi = std::min<uint64_t>(lo + kMorsel, n_rows);
            int64_t s = 0;  // at most 2^18 * 32768 < 2^33
            for (uint64_t i = lo; i < hi; ++i)
                s += w[i];
            acc.total += s;
            acc.cnt += hi - lo;
        },
        [&](Acc& acc, const Acc& part) {
            acc.total += part.total;
            acc.cnt += part.cnt;
        });

    std::vector<Column> cols;
    Validity valid(1, total.cnt != 0 ? 1 : 0);  // SUM over an empty table is NULL
    for (int k = 0; k < 90; ++k)
    {
        std::vector<__int128> v(1, total.total + static_cast<__int128>(k) * static_cast<__int128>(total.cnt));
        const std::string name = k == 0 ? "sum(ResolutionWidth)" : "sum((ResolutionWidth + " + std::to_string(k) + "))";
        cols.emplace_back(name, hugeint_column(v, valid));
    }
    return make_table(cols);
}
