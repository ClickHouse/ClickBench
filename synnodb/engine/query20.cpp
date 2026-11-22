#include "query20.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <vector>

// SQL:
/** SELECT UserID FROM hits WHERE UserID = 435090932899640449; */

std::shared_ptr<arrow::Table> run_q20(Database* db, const Q20Args& args) {
    if (!db) {
        throw std::runtime_error("run_q20: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    // The SQL template carries the literal; Q20Args has no parameters.
    constexpr int64_t kUser = 435090932899640449LL;

    const uint64_t n_rows = db->n_rows;
    if (db->UserID.size() != n_rows) {
        throw std::runtime_error("run_q20: column length does not match row count");
    }
    const int64_t* pu = db->UserID.data();

    // Every output row equals the literal, so the result is just the number of matching rows.
    constexpr uint64_t MORSEL = 1ull << 18;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + MORSEL - 1) / MORSEL);

    const uint64_t matches = parallel_reduce<uint64_t>(
        get_query_pool(), n_morsels, uint64_t{0},
        [&](uint64_t& acc, int64_t m) {
            const uint64_t lo = static_cast<uint64_t>(m) * MORSEL;
            const uint64_t hi = std::min<uint64_t>(lo + MORSEL, n_rows);
            uint64_t c = 0;
            for (uint64_t i = lo; i < hi; ++i)
                c += (pu[i] == kUser) ? 1 : 0;
            acc += c;
        },
        [](uint64_t& acc, const uint64_t& part) { acc += part; });

    std::vector<int64_t> users(static_cast<size_t>(matches), kUser);
    return make_table({
        {"UserID", integer_column(users, {}, arrow::int64())},
    });
}
