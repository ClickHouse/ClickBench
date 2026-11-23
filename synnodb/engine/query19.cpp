#include "query19.hpp"
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
/** SELECT UserID, extract(minute FROM EventTime) AS m, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, m, SearchPhrase ORDER BY COUNT(*) DESC LIMIT 10; */

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
constexpr int64_t MICROS_PER_MINUTE = 60LL * 1000000LL;

// extract(minute FROM ts) for a microsecond epoch value: floor division so pre-1970 values are correct.
inline uint64_t minute_of(int64_t us)
{
    int64_t q = us / MICROS_PER_MINUTE;
    if (us % MICROS_PER_MINUTE < 0)
        --q;
    int64_t m = q % 60;
    if (m < 0)
        m += 60;
    return static_cast<uint64_t>(m);
}

// The group's (minute, phrase id) are packed in one word: minute << 32 | phrase id.
struct Pair
{
    int64_t user;
    uint64_t sub;
};

struct Ent
{
    int64_t user;
    uint64_t sub;
    uint64_t cnt;  // 0 means the slot is empty (every stored group has count >= 1)
};

inline uint64_t hash_pair(int64_t user, uint64_t sub)
{
    // The low 8 bits of mix64(user) chose the partition, so use higher bits here.
    return mix64(static_cast<uint64_t>(user) + sub * 0x9E3779B97F4A7C15ULL) >> 8;
}

struct Table
{
    std::vector<Ent> slots;
    uint64_t used = 0;

    void init(uint64_t cap)
    {
        slots.assign(cap, Ent{0, 0, 0});
        used = 0;
    }

    void add(int64_t user, uint64_t sub)
    {
        const uint64_t mask = slots.size() - 1;
        uint64_t h = hash_pair(user, sub) & mask;
        for (;;)
        {
            Ent& e = slots[h];
            if (e.cnt == 0)
            {
                e.user = user;
                e.sub = sub;
                e.cnt = 1;
                if (++used * 2 > slots.size())
                    grow();
                return;
            }
            if (e.user == user && e.sub == sub)
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
            uint64_t h = hash_pair(e.user, e.sub) & mask;
            while (slots[h].cnt != 0)
                h = (h + 1) & mask;
            slots[h] = e;
            ++used;
        }
    }
};

struct Parts
{
    std::vector<std::vector<Pair>> buf;
};

struct Top
{
    std::vector<Ent> cand;
};

// ORDER BY count DESC, ties by UserID ASC, then minute ASC, then phrase id ASC.
inline bool better(const Ent& x, const Ent& y)
{
    if (x.cnt != y.cnt)
        return x.cnt > y.cnt;
    if (x.user != y.user)
        return x.user < y.user;
    return x.sub < y.sub;
}

void trim(std::vector<Ent>& v, size_t limit)
{
    if (v.size() <= limit)
        return;
    std::partial_sort(v.begin(), v.begin() + static_cast<std::ptrdiff_t>(limit), v.end(), better);
    v.resize(limit);
}
}

std::shared_ptr<arrow::Table> run_q19(Database* db, const Q19Args& args) {
    if (!db) {
        throw std::runtime_error("run_q19: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const uint64_t n_rows = db->n_rows;
    const auto& col = db->SearchPhrase;
    if (db->UserID.size() != n_rows || db->EventTime.size() != n_rows || col.ids.size() != n_rows) {
        throw std::runtime_error("run_q19: column length does not match row count");
    }
    const int64_t* pu = db->UserID.data();
    const int64_t* pt = db->EventTime.data();
    const auto* pp = col.ids.data();
    const uint64_t dict_n = col.dict.size();

    // Phase 1: radix-partition (user, minute, phrase) by hash of UserID.
    constexpr uint64_t SLICE = 1ull << 20;
    const int64_t n_slices = static_cast<int64_t>((n_rows + SLICE - 1) / SLICE);

    Parts parts = parallel_reduce<Parts>(
        get_query_pool(), n_slices, Parts{},
        [&](Parts& acc, int64_t s) {
            if (acc.buf.empty())
                acc.buf.resize(NPART);
            const uint64_t lo = static_cast<uint64_t>(s) * SLICE;
            const uint64_t hi = std::min<uint64_t>(lo + SLICE, n_rows);
            uint64_t cnt[NPART] = {};
            for (uint64_t i = lo; i < hi; ++i)
                ++cnt[mix64(static_cast<uint64_t>(pu[i])) & (NPART - 1)];
            for (uint64_t p = 0; p < NPART; ++p)
                acc.buf[p].reserve(acc.buf[p].size() + cnt[p]);
            for (uint64_t i = lo; i < hi; ++i)
            {
                const int64_t k = pu[i];
                const uint64_t id = pp[i];
                if (id >= dict_n)
                    throw std::runtime_error("run_q19: SearchPhrase id outside the dictionary");
                acc.buf[mix64(static_cast<uint64_t>(k)) & (NPART - 1)].push_back(Pair{k, (minute_of(pt[i]) << 32) | id});
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

    // Phase 2: per partition, count each group in a private table and keep the partition's top 10.
    Top top = parallel_reduce<Top>(
        get_query_pool(), static_cast<int64_t>(NPART), Top{},
        [&](Top& acc, int64_t p) {
            if (parts.buf.empty())
                return;
            const std::vector<Pair>& keys = parts.buf[static_cast<size_t>(p)];
            if (keys.empty())
                return;
            uint64_t cap = 1024;
            while (cap < keys.size())
                cap <<= 1;
            Table t;
            t.init(cap);
            for (const Pair& k : keys)
                t.add(k.user, k.sub);
            std::vector<Ent> local;
            local.reserve(t.used);
            for (const Ent& e : t.slots)
                if (e.cnt != 0)
                    local.push_back(e);
            trim(local, 10);
            acc.cand.insert(acc.cand.end(), local.begin(), local.end());
            trim(acc.cand, 10);
        },
        [](Top& acc, const Top& part) {
            acc.cand.insert(acc.cand.end(), part.cand.begin(), part.cand.end());
            trim(acc.cand, 10);
        });

    std::vector<Ent>& groups = top.cand;
    std::sort(groups.begin(), groups.end(), better);
    if (groups.size() > 10)
        groups.resize(10);

    std::vector<int64_t> users;
    std::vector<int64_t> minutes;
    std::vector<std::string> phrases;
    std::vector<int64_t> counts;
    for (const auto& g : groups)
    {
        if (g.cnt > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
            throw std::runtime_error("run_q19: count exceeds BIGINT");
        users.push_back(g.user);
        minutes.push_back(static_cast<int64_t>(g.sub >> 32));
        phrases.emplace_back(col.dict.get(static_cast<uint32_t>(g.sub & 0xffffffffULL)));
        counts.push_back(static_cast<int64_t>(g.cnt));
    }

    return make_table({
        {"UserID", integer_column(users, {}, arrow::int64())},
        {"m", integer_column(minutes, {}, arrow::int64())},
        {"SearchPhrase", string_column(phrases)},
        {"count_star()", integer_column(counts, {}, arrow::int64())},
    });
}
