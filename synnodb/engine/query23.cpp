#include "query23.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

// SQL:
/** SELECT SearchPhrase, MIN(URL), MIN(Title), COUNT(*) AS c, COUNT(DISTINCT UserID) FROM hits WHERE Title LIKE '%Google%' AND URL NOT LIKE '%.google.%' AND SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10; */

namespace {

struct Ent
{
    uint64_t id = 0;
    uint64_t cnt = 0;  // 0 == empty slot
    uint64_t row = 0;  // row holding the minimum URL of the group
    uint64_t pre = 0;  // first 8 bytes of that URL, zero padded, big-endian (fast compare)
    uint64_t trow = 0;  // row holding the minimum Title of the group
    uint64_t tpre = 0;
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

// Flat open-addressing table keyed by phrase id; grows at 50% load.
struct Table
{
    std::vector<Ent> slots;
    uint64_t used = 0;

    Ent& find_or_insert(uint64_t id, bool& inserted)
    {
        if (slots.empty())
            slots.resize(1024);
        if ((used + 1) * 2 > slots.size())
            grow();
        const uint64_t mask = slots.size() - 1;
        uint64_t p = mix64(id) & mask;
        for (;;)
        {
            Ent& e = slots[p];
            if (e.cnt == 0)
            {
                e.id = id;
                ++used;
                inserted = true;
                return e;
            }
            if (e.id == id)
            {
                inserted = false;
                return e;
            }
            p = (p + 1) & mask;
        }
    }

    void grow()
    {
        std::vector<Ent> old;
        old.swap(slots);
        slots.resize(old.size() * 2);
        const uint64_t mask = slots.size() - 1;
        for (const Ent& e : old)
        {
            if (e.cnt == 0)
                continue;
            uint64_t p = mix64(e.id) & mask;
            while (slots[p].cnt != 0)
                p = (p + 1) & mask;
            slots[p] = e;
        }
    }
};


inline uint64_t prefix8(std::string_view v)
{
    uint64_t p = 0;
    const size_t n = std::min<size_t>(v.size(), 8);
    for (size_t i = 0; i < n; ++i)
        p |= static_cast<uint64_t>(static_cast<unsigned char>(v[i])) << (56 - 8 * i);
    return p;
}

// Per-worker accumulator: group table plus the (phrase id, user) pairs of every qualifying row.
struct Acc
{
    Table t;
    std::vector<std::pair<uint64_t, int64_t>> pairs;
};

}

std::shared_ptr<arrow::Table> run_q23(Database* db, const Q23Args& args) {
    if (!db) {
        throw std::runtime_error("run_q23: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    static_assert(kSuperRows % kChunkRows == 0, "morsels must not straddle super-chunks");

    const StringArena& url = db->URL;
    const StringArena& title = db->Title;
    const auto& phrase_ids = db->SearchPhrase.ids;
    const StringDict& dict = db->SearchPhrase.dict;
    const auto& users = db->UserID;
    const uint64_t n_rows = db->n_rows;
    if (url.rows != n_rows || title.rows != n_rows || phrase_ids.size() != n_rows || users.size() != n_rows) {
        throw std::runtime_error("run_q23: column row counts do not match the table");
    }
    constexpr std::string_view kTitleNeedle = "Google";
    constexpr std::string_view kUrlNeedle = ".google.";
    const uint64_t dict_size = dict.size();

    const int64_t n_morsels = static_cast<int64_t>((n_rows + kChunkRows - 1) / kChunkRows);

    // Candidate-minimum test with prefix fast path; equal prefixes fall back to a full compare.
    auto better = [](const StringArena& a, uint64_t row, uint64_t pre, uint64_t cur_row, uint64_t cur_pre) {
        if (pre > cur_pre)
            return false;
        return pre < cur_pre || a.get(row) < a.get(cur_row);
    };

    Acc total = parallel_reduce<Acc>(
        get_query_pool(), n_morsels, Acc{},
        [&](Acc& acc, int64_t m) {
            const uint64_t lo = static_cast<uint64_t>(m) * kChunkRows;
            const uint64_t hi = std::min<uint64_t>(lo + kChunkRows, n_rows);
            const uint64_t s = lo / kSuperRows;
            const uint64_t j0 = lo % kSuperRows;
            const uint64_t j1 = j0 + (hi - lo);
            const uint64_t row_base = s * kSuperRows;
            const uint32_t* o = title.offs.data() + s * (kSuperRows + 1);
            const char* base = title.bytes.data() + title.base[s];
            const uint32_t b0 = o[j0];
            const uint32_t b1 = o[j1];
            const std::string_view region(base + b0, b1 - b0);

            uint64_t j = j0;
            size_t pos = 0;
            for (;;)
            {
                const size_t hit = region.find(kTitleNeedle, pos);
                if (hit == std::string_view::npos)
                    break;
                const uint64_t abs_hit = b0 + hit;
                while (o[j + 1] <= abs_hit)
                    ++j;
                if (abs_hit + kTitleNeedle.size() <= o[j + 1])
                {
                    // Row j's Title matches; continue the search at the next row.
                    pos = o[j + 1] - b0;
                    const uint64_t row = row_base + j;
                    const uint64_t id = phrase_ids[row];
                    if (id == 0)
                        continue;
                    if (id >= dict_size)
                        throw std::runtime_error("run_q23: SearchPhrase id out of range");
                    const std::string_view u = url.get(row);
                    if (u.find(kUrlNeedle) != std::string_view::npos)
                        continue;
                    const std::string_view t(base + o[j], o[j + 1] - o[j]);
                    const uint64_t upre = prefix8(u);
                    const uint64_t tpre = prefix8(t);
                    bool inserted = false;
                    Ent& e = acc.t.find_or_insert(id, inserted);
                    if (inserted)
                    {
                        e.cnt = 1;
                        e.row = row;
                        e.pre = upre;
                        e.trow = row;
                        e.tpre = tpre;
                    }
                    else
                    {
                        ++e.cnt;
                        if (better(url, row, upre, e.row, e.pre))
                        {
                            e.row = row;
                            e.pre = upre;
                        }
                        if (better(title, row, tpre, e.trow, e.tpre))
                        {
                            e.trow = row;
                            e.tpre = tpre;
                        }
                    }
                    acc.pairs.emplace_back(id, users[row]);
                }
                else
                {
                    pos = hit + 1;
                }
            }
        },
        [&](Acc& acc, const Acc& part) {
            for (const Ent& pe : part.t.slots)
            {
                if (pe.cnt == 0)
                    continue;
                bool inserted = false;
                Ent& e = acc.t.find_or_insert(pe.id, inserted);
                if (inserted)
                {
                    e = pe;
                }
                else
                {
                    e.cnt += pe.cnt;
                    if (better(url, pe.row, pe.pre, e.row, e.pre))
                    {
                        e.row = pe.row;
                        e.pre = pe.pre;
                    }
                    if (better(title, pe.trow, pe.tpre, e.trow, e.tpre))
                    {
                        e.trow = pe.trow;
                        e.tpre = pe.tpre;
                    }
                }
            }
            acc.pairs.insert(acc.pairs.end(), part.pairs.begin(), part.pairs.end());
        });

    // COUNT(DISTINCT UserID) per phrase: sort the qualifying (phrase, user) pairs and count runs.
    std::sort(total.pairs.begin(), total.pairs.end());
    std::vector<std::pair<uint64_t, uint64_t>> distinct;  // (phrase id, distinct users)
    for (size_t i = 0; i < total.pairs.size();)
    {
        const uint64_t id = total.pairs[i].first;
        uint64_t d = 0;
        size_t k = i;
        while (k < total.pairs.size() && total.pairs[k].first == id)
        {
            if (k == i || total.pairs[k].second != total.pairs[k - 1].second)
                ++d;
            ++k;
        }
        distinct.emplace_back(id, d);
        i = k;
    }

    std::vector<Ent> groups;
    groups.reserve(total.t.used);
    for (const Ent& e : total.t.slots)
        if (e.cnt != 0)
            groups.push_back(e);

    const size_t topk = std::min<size_t>(10, groups.size());
    std::partial_sort(groups.begin(), groups.begin() + topk, groups.end(), [](const Ent& a, const Ent& b) {
        if (a.cnt != b.cnt)
            return a.cnt > b.cnt;
        return a.id < b.id;
    });

    std::vector<std::string> phrases;
    std::vector<std::string> urls;
    std::vector<std::string> titles;
    std::vector<int64_t> counts;
    std::vector<int64_t> dcounts;
    for (size_t i = 0; i < topk; ++i)
    {
        const Ent& g = groups[i];
        const auto it = std::lower_bound(distinct.begin(), distinct.end(), std::make_pair(g.id, uint64_t{0}));
        if (it == distinct.end() || it->first != g.id)
            throw std::runtime_error("run_q23: missing distinct count for group");
        phrases.emplace_back(dict.get(g.id));
        urls.emplace_back(url.get(g.row));
        titles.emplace_back(title.get(g.trow));
        counts.push_back(static_cast<int64_t>(g.cnt));
        dcounts.push_back(static_cast<int64_t>(it->second));
    }

    return make_table({
        {"SearchPhrase", string_column(phrases)},
        {"min(URL)", string_column(urls)},
        {"min(Title)", string_column(titles)},
        {"c", integer_column(counts, {}, arrow::int64())},
        {"count(DISTINCT UserID)", integer_column(dcounts, {}, arrow::int64())},
    });
}
