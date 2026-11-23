#include "query22.hpp"
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
/** SELECT SearchPhrase, MIN(URL), COUNT(*) AS c FROM hits WHERE URL LIKE '%google%' AND SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10; */

namespace {

struct Ent
{
    uint64_t id = 0;
    uint64_t cnt = 0;  // 0 == empty slot
    uint64_t row = 0;  // row holding the minimum URL of the group
    uint64_t pre = 0;  // first 8 bytes of that URL, zero padded, big-endian (fast compare)
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

}

std::shared_ptr<arrow::Table> run_q22(Database* db, const Q22Args& args) {
    if (!db) {
        throw std::runtime_error("run_q22: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    static_assert(kSuperRows % kChunkRows == 0, "morsels must not straddle super-chunks");

    const StringArena& url = db->URL;
    const auto& phrase_ids = db->SearchPhrase.ids;
    const StringDict& dict = db->SearchPhrase.dict;
    const uint64_t n_rows = db->n_rows;
    if (url.rows != n_rows || phrase_ids.size() != n_rows) {
        throw std::runtime_error("run_q22: column row counts do not match the table");
    }
    constexpr std::string_view kNeedle = "google";
    const uint64_t dict_size = dict.size();

    const int64_t n_morsels = static_cast<int64_t>((n_rows + kChunkRows - 1) / kChunkRows);

    // Per-row URL comparison for MIN(URL): byte-lexicographic, shorter prefix first.
    auto prefix8 = [](std::string_view v) {
        uint64_t p = 0;
        const size_t n = std::min<size_t>(v.size(), 8);
        for (size_t i = 0; i < n; ++i)
            p |= static_cast<uint64_t>(static_cast<unsigned char>(v[i])) << (56 - 8 * i);
        return p;
    };
    // Updates the group's minimum with candidate (row, pre); equal prefixes fall back to a full compare.
    auto update_min = [&](Ent& e, uint64_t row, uint64_t pre) {
        if (pre > e.pre)
            return;
        if (pre < e.pre || url.get(row) < url.get(e.row))
        {
            e.row = row;
            e.pre = pre;
        }
    };

    Table total = parallel_reduce<Table>(
        get_query_pool(), n_morsels, Table{},
        [&](Table& acc, int64_t m) {
            const uint64_t lo = static_cast<uint64_t>(m) * kChunkRows;
            const uint64_t hi = std::min<uint64_t>(lo + kChunkRows, n_rows);
            const uint64_t s = lo / kSuperRows;
            const uint64_t j0 = lo % kSuperRows;
            const uint64_t j1 = j0 + (hi - lo);
            const uint64_t row_base = s * kSuperRows;
            const uint32_t* o = url.offs.data() + s * (kSuperRows + 1);
            const char* base = url.bytes.data() + url.base[s];
            const uint32_t b0 = o[j0];
            const uint32_t b1 = o[j1];
            const std::string_view region(base + b0, b1 - b0);

            uint64_t j = j0;
            size_t pos = 0;
            for (;;)
            {
                const size_t hit = region.find(kNeedle, pos);
                if (hit == std::string_view::npos)
                    break;
                const uint64_t abs_hit = b0 + hit;
                while (o[j + 1] <= abs_hit)
                    ++j;
                if (abs_hit + kNeedle.size() <= o[j + 1])
                {
                    // Row j matches the LIKE; one count per row, then continue at the next row.
                    const uint64_t row = row_base + j;
                    const uint64_t id = phrase_ids[row];
                    if (id != 0)
                    {
                        if (id >= dict_size)
                            throw std::runtime_error("run_q22: SearchPhrase id out of range");
                        const uint64_t pre = prefix8(std::string_view(base + o[j], o[j + 1] - o[j]));
                        bool inserted = false;
                        Ent& e = acc.find_or_insert(id, inserted);
                        if (inserted)
                        {
                            e.cnt = 1;
                            e.row = row;
                            e.pre = pre;
                        }
                        else
                        {
                            ++e.cnt;
                            update_min(e, row, pre);
                        }
                    }
                    pos = o[j + 1] - b0;
                }
                else
                {
                    pos = hit + 1;
                }
            }
        },
        [&](Table& acc, const Table& part) {
            for (const Ent& pe : part.slots)
            {
                if (pe.cnt == 0)
                    continue;
                bool inserted = false;
                Ent& e = acc.find_or_insert(pe.id, inserted);
                if (inserted)
                {
                    e.cnt = pe.cnt;
                    e.row = pe.row;
                    e.pre = pe.pre;
                }
                else
                {
                    e.cnt += pe.cnt;
                    update_min(e, pe.row, pe.pre);
                }
            }
        });

    std::vector<Ent> groups;
    groups.reserve(total.used);
    for (const Ent& e : total.slots)
        if (e.cnt != 0)
            groups.push_back(e);

    const size_t k = std::min<size_t>(10, groups.size());
    std::partial_sort(groups.begin(), groups.begin() + k, groups.end(), [](const Ent& a, const Ent& b) {
        if (a.cnt != b.cnt)
            return a.cnt > b.cnt;
        return a.id < b.id;
    });

    std::vector<std::string> phrases;
    std::vector<std::string> urls;
    std::vector<int64_t> counts;
    for (size_t i = 0; i < k; ++i)
    {
        phrases.emplace_back(dict.get(groups[i].id));
        urls.emplace_back(url.get(groups[i].row));
        if (groups[i].cnt > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()))
            throw std::runtime_error("run_q22: count exceeds BIGINT");
        counts.push_back(static_cast<int64_t>(groups[i].cnt));
    }

    return make_table({
        {"SearchPhrase", string_column(phrases)},
        {"min(URL)", string_column(urls)},
        {"c", integer_column(counts, {}, arrow::int64())},
    });
}
