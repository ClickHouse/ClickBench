#include "query1.hpp"
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
/** SELECT COUNT(*) FROM hits; */

std::shared_ptr<arrow::Table> run_q1(Database* db, const Q1Args& args) {
    if (!db) {
        throw std::runtime_error("run_q1: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    // COUNT(*) without a filter is the logical row count of the base table. The loader stores every
    // row of `hits` exactly once; the count is read from the base-table row counter (one 64-bit
    // value), never from a stored query result. Each column has exactly n_rows entries, which is
    // verified against one fixed-width base column so a loader inconsistency throws instead of
    // returning a wrong count.
    const uint64_t n_rows = db->n_rows;
    if (db->CounterID.size() != n_rows) {
        throw std::runtime_error("run_q1: column length does not match row count");
    }
    if (n_rows > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
        throw std::runtime_error("run_q1: row count exceeds BIGINT");
    }

    std::vector<int64_t> count_star;
    count_star.push_back(static_cast<int64_t>(n_rows));

    return make_table({
        {"count_star()", integer_column(count_star, {}, arrow::int64())},
    });
}
