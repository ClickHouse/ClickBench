#include "query2.hpp"
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
/** SELECT COUNT(*) FROM hits WHERE AdvEngineID <> 0; */

std::shared_ptr<arrow::Table> run_q2(Database* db, const Q2Args& args) {
    if (!db) {
        throw std::runtime_error("run_q2: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    const std::vector<int16_t>& col = db->AdvEngineID;
    if (col.size() != n_rows) {
        throw std::runtime_error("run_q2: column length does not match row count");
    }

    // Morsels are contiguous row ranges; each fold counts into a private 64-bit counter and the
    // partial counts are merged by addition (exact and order independent).
    ThreadPool& pool = get_query_pool();
    constexpr uint64_t MORSEL = 1ull << 16;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + MORSEL - 1) / MORSEL);
    const int16_t* p = col.data();
    static_assert(MORSEL == kChunkRows, "morsels must align with zone-map chunks");
    const auto& zone = db->zone_AdvEngineID;
    if (zone.mn.size() != static_cast<uint64_t>(n_morsels) || zone.mx.size() != zone.mn.size())
        throw std::runtime_error("run_q2: zone map size mismatch");
    const int16_t* zmn = zone.mn.data();
    const int16_t* zmx = zone.mx.data();

    const uint64_t total = parallel_reduce<uint64_t>(
        pool, n_morsels, uint64_t{0},
        [&](uint64_t& local, int64_t m) {
            const uint64_t lo = static_cast<uint64_t>(m) * MORSEL;
            const uint64_t hi = std::min<uint64_t>(lo + MORSEL, n_rows);
            // Zone map (one entry per kChunkRows rows, MORSEL == kChunkRows): a chunk whose range is
            // exactly [0, 0] has no matches, and a chunk whose range excludes 0 matches every row.
            const int16_t mn = zmn[m];
            const int16_t mx = zmx[m];
            if (mn == 0 && mx == 0)
                return;
            if (mn > 0 || mx < 0)
            {
                local += hi - lo;
                return;
            }
            // Branch-free count; the compiler vectorizes this loop with whatever the target offers.
            uint64_t c = 0;
            for (uint64_t i = lo; i < hi; ++i)
                c += (p[i] != 0);
            local += c;
        },
        [](uint64_t& acc, const uint64_t& part) { acc += part; });

    if (total > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
        throw std::runtime_error("run_q2: count exceeds BIGINT");
    }
    std::vector<int64_t> count_star;
    count_star.push_back(static_cast<int64_t>(total));

    return make_table({
        {"count_star()", integer_column(count_star, {}, arrow::int64())},
    });
}
