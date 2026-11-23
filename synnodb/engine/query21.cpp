#include "query21.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string_view>
#include <vector>

// SQL:
/** SELECT COUNT(*) FROM hits WHERE URL LIKE '%google%'; */

std::shared_ptr<arrow::Table> run_q21(Database* db, const Q21Args& args) {
    if (!db) {
        throw std::runtime_error("run_q21: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    static_assert(kSuperRows % kChunkRows == 0, "morsels must not straddle super-chunks");

    const StringArena& url = db->URL;
    const uint64_t n_rows = db->n_rows;
    if (url.rows != n_rows) {
        throw std::runtime_error("run_q21: URL row count does not match the table");
    }
    constexpr std::string_view kNeedle = "google";

    // Morsel = one 2^16-row chunk. The bytes of a chunk are contiguous inside its super-chunk, so
    // the substring search runs over the raw byte range once and each hit is mapped back to its
    // row by walking the row offsets forward (hits are found in increasing position order).
    const int64_t n_morsels = static_cast<int64_t>((n_rows + kChunkRows - 1) / kChunkRows);

    const uint64_t total = parallel_reduce<uint64_t>(
        get_query_pool(), n_morsels, uint64_t{0},
        [&](uint64_t& acc, int64_t m) {
            const uint64_t lo = static_cast<uint64_t>(m) * kChunkRows;
            const uint64_t hi = std::min<uint64_t>(lo + kChunkRows, n_rows);
            const uint64_t s = lo / kSuperRows;
            const uint64_t j0 = lo % kSuperRows;
            const uint64_t j1 = j0 + (hi - lo);
            const uint32_t* o = url.offs.data() + s * (kSuperRows + 1);
            const char* base = url.bytes.data() + url.base[s];
            const uint32_t b0 = o[j0];
            const uint32_t b1 = o[j1];
            const std::string_view region(base + b0, b1 - b0);

            uint64_t c = 0;
            uint64_t j = j0;  // current row; its end offset is o[j + 1]
            size_t pos = 0;
            for (;;)
            {
                const size_t hit = region.find(kNeedle, pos);
                if (hit == std::string_view::npos)
                    break;
                const uint64_t abs_hit = b0 + hit;
                while (o[j + 1] <= abs_hit)
                    ++j;
                // The hit counts only if it lies entirely inside row j.
                if (abs_hit + kNeedle.size() <= o[j + 1])
                {
                    ++c;
                    pos = o[j + 1] - b0;  // continue at the next row
                }
                else
                {
                    pos = hit + 1;
                }
            }
            acc += c;
        },
        [](uint64_t& acc, const uint64_t& part) { acc += part; });

    if (total > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
        throw std::runtime_error("run_q21: count exceeds BIGINT");
    std::vector<int64_t> counts{static_cast<int64_t>(total)};
    return make_table({
        {"count_star()", integer_column(counts, {}, arrow::int64())},
    });
}
