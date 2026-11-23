#include "query36.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

// SQL:
/** SELECT ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3, COUNT(*) AS c FROM hits
    GROUP BY ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3 ORDER BY c DESC LIMIT 10; */

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

inline uint64_t hash_key(int32_t k)
{
    return mix64(static_cast<uint64_t>(static_cast<int64_t>(k)));
}

struct Ent
{
    uint64_t cnt;  // 0 means the slot is empty (every stored group has count >= 1)
    int64_t key;
};

struct Parts
{
    std::vector<std::vector<int32_t>> buf;  // one buffer of raw ClientIP values per hash partition
};

using Cand = std::pair<int64_t, uint64_t>;  // (ClientIP, count)

struct Top
{
    std::vector<Cand> cand;
};

// ORDER BY count DESC, ties by ClientIP ASC.
inline bool better(const Cand& x, const Cand& y)
{
    if (x.second != y.second)
        return x.second > y.second;
    return x.first < y.first;
}

constexpr size_t kLimit = 10;

void trim(std::vector<Cand>& v)
{
    // Always leaves v sorted by `better`, so v[kLimit - 1] is the current cutoff when v is full.
    if (v.size() <= kLimit)
    {
        std::sort(v.begin(), v.end(), better);
        return;
    }
    std::partial_sort(v.begin(), v.begin() + static_cast<std::ptrdiff_t>(kLimit), v.end(), better);
    v.resize(kLimit);
}
}

std::shared_ptr<arrow::Table> run_q36(Database* db, const Q36Args& args) {
    if (!db) {
        throw std::runtime_error("run_q36: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    if (db->ClientIP.size() != n_rows) {
        throw std::runtime_error("run_q36: column length does not match row count");
    }
    const int32_t* pu = db->ClientIP.data();

    // Partition count sized from the data: about 2^15 rows per partition, 256..16384 partitions.
    uint64_t npart = 256;
    while (npart < 16384 && n_rows / npart > (1ull << 15))
        npart <<= 1;

    // Phase 1: radix-partition the keys by hash (all rows of one key land in one partition).
    constexpr uint64_t MORSEL = 1ull << 17;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + MORSEL - 1) / MORSEL);

    Parts parts = parallel_reduce<Parts>(
        get_query_pool(), n_morsels, Parts{},
        [&](Parts& acc, int64_t s) {
            if (acc.buf.empty())
                acc.buf.resize(npart);
            const uint64_t lo = static_cast<uint64_t>(s) * MORSEL;
            const uint64_t hi = std::min<uint64_t>(lo + MORSEL, n_rows);
            // Hash once, remember the partition of every row, then reserve each buffer once.
            std::vector<uint16_t> pid(hi - lo);
            std::vector<uint32_t> cnt(npart, 0);
            for (uint64_t i = lo; i < hi; ++i)
            {
                const uint16_t p = static_cast<uint16_t>(hash_key(pu[i]) & (npart - 1));
                pid[i - lo] = p;
                ++cnt[p];
            }
            for (uint64_t p = 0; p < npart; ++p)
                if (cnt[p] != 0)
                    acc.buf[p].reserve(acc.buf[p].size() + cnt[p]);
            for (uint64_t i = lo; i < hi; ++i)
                acc.buf[pid[i - lo]].push_back(pu[i]);
        },
        [&](Parts& acc, const Parts& part) {
            if (part.buf.empty())
                return;
            Parts& src = const_cast<Parts&>(part);
            if (acc.buf.empty())
            {
                acc.buf = std::move(src.buf);
                return;
            }
            for (uint64_t p = 0; p < npart; ++p)
            {
                auto& dst = acc.buf[p];
                auto& from = src.buf[p];
                if (dst.size() < from.size())
                    dst.swap(from);
                dst.insert(dst.end(), from.begin(), from.end());
            }
        });

    // Phase 2: per partition, count each key in a private table and keep the partition's best candidates.
    Top top = parallel_reduce<Top>(
        get_query_pool(), parts.buf.empty() ? 0 : static_cast<int64_t>(npart), Top{},
        [&](Top& acc, int64_t p) {
            const std::vector<int32_t>& keys = parts.buf[static_cast<size_t>(p)];
            if (keys.empty())
                return;
            uint64_t cap = 1024;
            while (cap < keys.size() * 2)
                cap <<= 1;
            std::vector<Ent> slots(cap, Ent{0, 0});
            const uint64_t mask = cap - 1;
            for (const int32_t k : keys)
            {
                uint64_t h = (hash_key(k) >> 24) & mask;  // low bits chose the partition
                for (;;)
                {
                    Ent& e = slots[h];
                    if (e.cnt == 0)
                    {
                        e.key = k;
                        e.cnt = 1;
                        break;
                    }
                    if (e.key == k)
                    {
                        ++e.cnt;
                        break;
                    }
                    h = (h + 1) & mask;
                }
            }
            // Collect only groups that can still rank among the best kLimit.
            uint64_t thr = acc.cand.size() >= kLimit ? acc.cand[kLimit - 1].second : 0;
            for (const Ent& e : slots)
            {
                if (e.cnt == 0 || e.cnt < thr)
                    continue;
                acc.cand.emplace_back(e.key, e.cnt);
                if (acc.cand.size() >= 4 * kLimit)
                {
                    trim(acc.cand);
                    thr = acc.cand[kLimit - 1].second;
                }
            }
            trim(acc.cand);
        },
        [](Top& acc, const Top& part) {
            acc.cand.insert(acc.cand.end(), part.cand.begin(), part.cand.end());
            trim(acc.cand);
        });

    std::vector<Cand>& groups = top.cand;
    std::sort(groups.begin(), groups.end(), better);
    if (groups.size() > kLimit)
        groups.resize(kLimit);

    std::vector<int64_t> ip0, ip1, ip2, ip3;
    std::vector<int64_t> counts;
    for (const auto& g : groups)
    {
        if (g.second > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
            throw std::runtime_error("run_q36: count exceeds BIGINT");
        ip0.push_back(g.first);
        ip1.push_back(g.first - 1);
        ip2.push_back(g.first - 2);
        ip3.push_back(g.first - 3);
        counts.push_back(static_cast<int64_t>(g.second));
    }

    // INTEGER - INTEGER stays INTEGER; the builder throws if a value would overflow int32.
    return make_table({
        {"ClientIP", integer_column(ip0, {}, arrow::int32())},
        {"(ClientIP - 1)", integer_column(ip1, {}, arrow::int32())},
        {"(ClientIP - 2)", integer_column(ip2, {}, arrow::int32())},
        {"(ClientIP - 3)", integer_column(ip3, {}, arrow::int32())},
        {"c", integer_column(counts, {}, arrow::int64())},
    });
}
