#include "query34.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

// SQL:
/** SELECT URL, COUNT(*) AS c FROM hits GROUP BY URL ORDER BY c DESC LIMIT 10; */

namespace {

constexpr uint64_t kParts = 256;
constexpr size_t kTop = 10;

struct Pair
{
    uint64_t hash;
    uint64_t row;
};

struct P1
{
    std::vector<std::vector<Pair>> parts;
};

struct Ent
{
    uint64_t hash = 0;
    uint64_t cnt = 0;  // 0 == empty slot
    uint64_t row = 0;  // representative row of the group
};

struct Group
{
    uint64_t cnt;
    uint64_t row;
};

struct P2
{
    std::vector<Group> top;
};

inline uint64_t mix64(uint64_t x)
{
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

inline uint64_t hash_bytes(const char* p, size_t n)
{
    uint64_t h = 0x9E3779B97F4A7C15ULL ^ (static_cast<uint64_t>(n) * 0xC2B2AE3D27D4EB4FULL);
    while (n >= 8)
    {
        uint64_t v;
        std::memcpy(&v, p, 8);
        h = (h ^ v) * 0x9FB21C651E98DF25ULL;
        h ^= h >> 32;
        p += 8;
        n -= 8;
    }
    if (n)
    {
        uint64_t v = 0;
        std::memcpy(&v, p, n);
        h = (h ^ v) * 0x9FB21C651E98DF25ULL;
        h ^= h >> 32;
    }
    return mix64(h);
}

}

std::shared_ptr<arrow::Table> run_q34(Database* db, const Q34Args& args) {
    if (!db) {
        throw std::runtime_error("run_q34: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    static_assert(kSuperRows % kChunkRows == 0, "morsels must not straddle super-chunks");

    const StringArena& url = db->URL;
    const uint64_t n_rows = db->n_rows;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + kChunkRows - 1) / kChunkRows);
    if (url.rows != n_rows) {
        throw std::runtime_error("run_q34: URL column shape does not match the table");
    }

    // Phase 1: hash each URL and partition (hash, row) by hash.
    P1 p1 = parallel_reduce<P1>(
        get_query_pool(), n_morsels, P1{},
        [&](P1& acc, int64_t m) {
            if (acc.parts.empty())
            {
                acc.parts.resize(kParts);
                for (auto& v : acc.parts)
                    v.reserve(2 * kChunkRows / kParts + 16);
            }
            const uint64_t lo = static_cast<uint64_t>(m) * kChunkRows;
            const uint64_t hi = std::min<uint64_t>(lo + kChunkRows, n_rows);
            const uint64_t s = lo / kSuperRows;
            const uint64_t j0 = lo % kSuperRows;
            const uint64_t j1 = j0 + (hi - lo);
            const uint32_t* o = url.offs.data() + s * (kSuperRows + 1);
            const char* bytes = url.bytes.data() + url.base[s];
            for (uint64_t j = j0; j < j1; ++j)
            {
                const uint32_t len = o[j + 1] - o[j];
                const uint64_t h = hash_bytes(bytes + o[j], len);
                acc.parts[h & (kParts - 1)].push_back(Pair{h, s * kSuperRows + j});
            }
        },
        [&](P1& acc, const P1& part) {
            if (part.parts.empty())
                return;
            if (acc.parts.empty())
            {
                acc.parts = std::move(const_cast<P1&>(part).parts);
                return;
            }
            for (uint64_t k = 0; k < kParts; ++k)
            {
                auto& dst = acc.parts[k];
                auto& src = const_cast<P1&>(part).parts[k];
                if (dst.size() < src.size())
                    dst.swap(src);
                dst.insert(dst.end(), src.begin(), src.end());
            }
        });

    // better(a, b): a ranks before b (count DESC, then URL ascending for determinism).
    auto better = [&](const Group& a, const Group& b)
    {
        if (a.cnt != b.cnt)
            return a.cnt > b.cnt;
        return url.get(a.row) < url.get(b.row);
    };
    auto trim = [&](std::vector<Group>& v)
    {
        if (v.size() > 4 * kTop)
        {
            std::nth_element(v.begin(), v.begin() + kTop, v.end(), better);
            v.resize(kTop);
        }
    };

    // Phase 2: aggregate each hash partition privately, keep its top candidates.
    P2 res = parallel_reduce<P2>(
        get_query_pool(), static_cast<int64_t>(p1.parts.empty() ? 0 : kParts), P2{},
        [&](P2& acc, int64_t pi) {
            const std::vector<Pair>& part = p1.parts[static_cast<size_t>(pi)];
            if (part.empty())
                return;
            size_t cap = 1024;
            while (cap < part.size() * 2)
                cap <<= 1;
            std::vector<Ent> slots(cap);
            const uint64_t mask = cap - 1;
            const size_t n_part = part.size();
            for (size_t pi2 = 0; pi2 < n_part; ++pi2)
            {
                const Pair& pr = part[pi2];
                if (pi2 + 16 < n_part)
                    __builtin_prefetch(&slots[(part[pi2 + 16].hash >> 8) & mask]);
                const std::string_view key = url.get(pr.row);
                uint64_t p = (pr.hash >> 8) & mask;
                for (;;)
                {
                    Ent& e = slots[p];
                    if (e.cnt == 0)
                    {
                        e.hash = pr.hash;
                        e.cnt = 1;
                        e.row = pr.row;
                        break;
                    }
                    if (e.hash == pr.hash && url.get(e.row) == key)
                    {
                        ++e.cnt;
                        break;
                    }
                    p = (p + 1) & mask;
                }
            }
            for (const Ent& e : slots)
                if (e.cnt != 0)
                    acc.top.push_back(Group{e.cnt, e.row});
            // Keep only this partition's best kTop groups.
            if (acc.top.size() > kTop)
            {
                std::nth_element(acc.top.begin(), acc.top.begin() + kTop, acc.top.end(), better);
                acc.top.resize(kTop);
            }
        },
        [&](P2& acc, const P2& part) {
            acc.top.insert(acc.top.end(), part.top.begin(), part.top.end());
            trim(acc.top);
        });

    std::vector<Group> top = std::move(res.top);
    std::sort(top.begin(), top.end(), better);
    if (top.size() > kTop)
        top.resize(kTop);

    std::vector<std::string> urls;
    std::vector<int64_t> counts;
    for (const Group& g : top)
    {
        urls.emplace_back(url.get(g.row));
        counts.push_back(static_cast<int64_t>(g.cnt));
    }

    return make_table({
        {"URL", string_column(urls)},
        {"c", integer_column(counts, {}, arrow::int64())},
    });
}