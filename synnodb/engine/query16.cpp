#include "query16.hpp"
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
/** SELECT UserID, COUNT(*) FROM hits GROUP BY UserID ORDER BY COUNT(*) DESC LIMIT 10; */

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

constexpr uint64_t NPART = 256;

struct Ent
{
    uint64_t key;
    uint64_t cnt;  // 0 means the slot is empty (every stored group has count >= 1)
};

// Flat open-addressing key -> count table (linear probing, grows at 50% load).
struct Table
{
    std::vector<Ent> slots;
    uint64_t used = 0;

    void init(uint64_t cap)
    {
        slots.assign(cap, Ent{0, 0});
        used = 0;
    }

    void add(uint64_t key)
    {
        const uint64_t mask = slots.size() - 1;
        uint64_t h = (mix64(key) >> 8) & mask;  // low bits of the hash chose the partition
        for (;;)
        {
            Ent& e = slots[h];
            if (e.cnt == 0)
            {
                e.key = key;
                e.cnt = 1;
                if (++used * 2 > slots.size())
                    grow();
                return;
            }
            if (e.key == key)
            {
                ++e.cnt;
                return;
            }
            h = (h + 1) & mask;
        }
    }

    void grow()
    {
        std::vector<Ent> old;
        old.swap(slots);
        init(old.size() * 2);
        const uint64_t mask = slots.size() - 1;
        for (const Ent& e : old)
        {
            if (e.cnt == 0)
                continue;
            uint64_t h = (mix64(e.key) >> 8) & mask;
            while (slots[h].cnt != 0)
                h = (h + 1) & mask;
            slots[h] = e;
            ++used;
        }
    }
};

struct Parts
{
    std::vector<std::vector<int64_t>> buf;  // NPART buffers of raw UserID values
};

using Cand = std::pair<int64_t, uint64_t>;  // (UserID, count)

struct Top
{
    std::vector<Cand> cand;
};

// ORDER BY count DESC, ties by UserID ASC.
inline bool better(const Cand& x, const Cand& y)
{
    if (x.second != y.second)
        return x.second > y.second;
    return x.first < y.first;
}

void trim(std::vector<Cand>& v, size_t limit)
{
    if (v.size() <= limit)
        return;
    std::partial_sort(v.begin(), v.begin() + static_cast<std::ptrdiff_t>(limit), v.end(), better);
    v.resize(limit);
}
}

std::shared_ptr<arrow::Table> run_q16(Database* db, const Q16Args& args) {
    if (!db) {
        throw std::runtime_error("run_q16: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    if (db->UserID.size() != n_rows) {
        throw std::runtime_error("run_q16: column length does not match row count");
    }
    const int64_t* pu = db->UserID.data();

    // Phase 1: radix-partition the keys by hash into NPART buffers (all rows of one key land in one partition).
    constexpr uint64_t SLICE = 1ull << 20;
    const int64_t n_slices = static_cast<int64_t>((n_rows + SLICE - 1) / SLICE);

    Parts parts = parallel_reduce<Parts>(
        get_query_pool(), n_slices, Parts{},
        [&](Parts& acc, int64_t s) {
            if (acc.buf.empty())
                acc.buf.resize(NPART);
            const uint64_t lo = static_cast<uint64_t>(s) * SLICE;
            const uint64_t hi = std::min<uint64_t>(lo + SLICE, n_rows);
            // Count first so every buffer grows once per slice.
            uint64_t cnt[NPART] = {};
            for (uint64_t i = lo; i < hi; ++i)
                ++cnt[mix64(static_cast<uint64_t>(pu[i])) & (NPART - 1)];
            for (uint64_t p = 0; p < NPART; ++p)
                acc.buf[p].reserve(acc.buf[p].size() + cnt[p]);
            for (uint64_t i = lo; i < hi; ++i)
            {
                const int64_t k = pu[i];
                acc.buf[mix64(static_cast<uint64_t>(k)) & (NPART - 1)].push_back(k);
            }
        },
        [](Parts& acc, const Parts& part) {
            if (part.buf.empty())
                return;
            if (acc.buf.empty())
                acc.buf.resize(NPART);
            for (uint64_t p = 0; p < NPART; ++p)
                acc.buf[p].insert(acc.buf[p].end(), part.buf[p].begin(), part.buf[p].end());
        });

    // Phase 2: per partition, count each key in a private table and keep the partition's top 10.
    Top top = parallel_reduce<Top>(
        get_query_pool(), static_cast<int64_t>(NPART), Top{},
        [&](Top& acc, int64_t p) {
            if (parts.buf.empty())
                return;
            const std::vector<int64_t>& keys = parts.buf[static_cast<size_t>(p)];
            if (keys.empty())
                return;
            uint64_t cap = 1024;
            while (cap < keys.size() / 2)
                cap <<= 1;
            Table t;
            t.init(cap);
            for (const int64_t k : keys)
                t.add(static_cast<uint64_t>(k));
            std::vector<Cand> local;
            local.reserve(t.used);
            for (const Ent& e : t.slots)
                if (e.cnt != 0)
                    local.emplace_back(static_cast<int64_t>(e.key), e.cnt);
            trim(local, 10);
            acc.cand.insert(acc.cand.end(), local.begin(), local.end());
            trim(acc.cand, 10);
        },
        [](Top& acc, const Top& part) {
            acc.cand.insert(acc.cand.end(), part.cand.begin(), part.cand.end());
            trim(acc.cand, 10);
        });

    std::vector<Cand>& groups = top.cand;
    std::sort(groups.begin(), groups.end(), better);
    if (groups.size() > 10)
        groups.resize(10);

    std::vector<int64_t> users;
    std::vector<int64_t> counts;
    for (const auto& g : groups)
    {
        if (g.second > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
            throw std::runtime_error("run_q16: count exceeds BIGINT");
        users.push_back(g.first);
        counts.push_back(static_cast<int64_t>(g.second));
    }

    return make_table({
        {"UserID", integer_column(users, {}, arrow::int64())},
        {"count_star()", integer_column(counts, {}, arrow::int64())},
    });
}
