#include "query5.hpp"
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
/** SELECT COUNT(DISTINCT UserID) FROM hits; */

namespace
{
inline uint64_t mix64(uint64_t x)
{
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

constexpr unsigned kPartBits = 8;
constexpr uint64_t kParts = 1ull << kPartBits;

struct Count
{
    uint64_t n = 0;
};
}

std::shared_ptr<arrow::Table> run_q5(Database* db, const Q5Args& args) {
    if (!db) {
        throw std::runtime_error("run_q5: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    const std::vector<int64_t>& user = db->UserID;
    if (user.size() != n_rows) {
        throw std::runtime_error("run_q5: column length does not match row count");
    }
    const int64_t* pu = user.data();

    ThreadPool& pool = get_query_pool();

    // Phase 1: contiguous row slices; each slice radix-partitions its (hashed) values into
    // kParts private buffers. A slice is owned by exactly one fold call, so no sharing.
    constexpr uint64_t SLICE = 1ull << 20;
    const int64_t n_slices = static_cast<int64_t>((n_rows + SLICE - 1) / SLICE);
    std::vector<std::vector<std::vector<uint64_t>>> bufs(static_cast<size_t>(n_slices));
    parallel_reduce<Count>(
        pool, n_slices, Count{},
        [&](Count&, int64_t s) {
            const uint64_t lo = static_cast<uint64_t>(s) * SLICE;
            const uint64_t hi = std::min<uint64_t>(lo + SLICE, n_rows);
            auto& parts = bufs[static_cast<size_t>(s)];
            parts.resize(kParts);
            const uint64_t expect = (hi - lo) / kParts;
            for (auto& v : parts)
                v.reserve(expect + expect / 4 + 16);
            for (uint64_t i = lo; i < hi; ++i)
            {
                const uint64_t k = static_cast<uint64_t>(pu[i]);
                parts[mix64(k) >> (64 - kPartBits)].push_back(k);
            }
        },
        [](Count&, const Count&) {});

    // Phase 2: each partition holds every row whose key hashes into it, so partitions are
    // disjoint key sets. Count distinct keys per partition with a private open-addressing set
    // and add the exact counts. Key 0 is the empty-slot marker and is tracked separately.
    const Count total = parallel_reduce<Count>(
        pool, static_cast<int64_t>(kParts), Count{},
        [&](Count& local, int64_t p) {
            uint64_t rows = 0;
            for (const auto& slice : bufs)
                rows += slice[static_cast<size_t>(p)].size();
            if (rows == 0)
                return;
            uint64_t cap = 16;
            while (cap < rows * 2)
                cap <<= 1;
            const uint64_t mask = cap - 1;
            std::vector<uint64_t> table(cap, 0);
            bool has_zero = false;
            uint64_t distinct = 0;
            for (const auto& slice : bufs)
            {
                for (const uint64_t k : slice[static_cast<size_t>(p)])
                {
                    if (k == 0)
                    {
                        has_zero = true;
                        continue;
                    }
                    uint64_t pos = mix64(k) & mask;
                    while (true)
                    {
                        const uint64_t cur = table[pos];
                        if (cur == k)
                            break;
                        if (cur == 0)
                        {
                            table[pos] = k;
                            ++distinct;
                            break;
                        }
                        pos = (pos + 1) & mask;
                    }
                }
            }
            local.n += distinct + (has_zero ? 1 : 0);
        },
        [](Count& acc, const Count& part) { acc.n += part.n; });

    if (total.n > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
        throw std::runtime_error("run_q5: count exceeds BIGINT");
    }
    std::vector<int64_t> count_distinct{static_cast<int64_t>(total.n)};

    return make_table({
        {"count(DISTINCT UserID)", integer_column(count_distinct, {}, arrow::int64())},
    });
}
