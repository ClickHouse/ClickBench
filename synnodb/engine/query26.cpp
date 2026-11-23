#include "query26.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

// SQL:
/** SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY SearchPhrase LIMIT 10; */

namespace {

constexpr size_t kLimit = 10;

// Per-worker state: the (up to) 10 smallest non-empty phrase ids seen so far, with duplicates, sorted ascending.
// Dictionary ids are assigned in byte order of the phrase, so id order is ORDER BY SearchPhrase order.
struct Top
{
    std::array<uint64_t, kLimit> ids{};
    size_t n = 0;

    // Returns true when `id` could still enter the top list.
    inline bool wants(uint64_t id) const
    {
        return n < kLimit || id < ids[n - 1];
    }

    inline void add(uint64_t id)
    {
        size_t p = n < kLimit ? n : kLimit - 1;
        while (p > 0 && ids[p - 1] > id)
        {
            ids[p] = ids[p - 1];
            --p;
        }
        ids[p] = id;
        if (n < kLimit)
            ++n;
    }
};

}

std::shared_ptr<arrow::Table> run_q26(Database* db, const Q26Args& args) {
    if (!db) {
        throw std::runtime_error("run_q26: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    const auto& ids = db->SearchPhrase.ids;
    const StringDict& dict = db->SearchPhrase.dict;
    const uint64_t n_rows = db->n_rows;
    if (ids.size() != n_rows) {
        throw std::runtime_error("run_q26: SearchPhrase row count does not match the table");
    }
    const uint64_t dict_size = dict.size();

    constexpr uint64_t kMorsel = 1ULL << 18;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + kMorsel - 1) / kMorsel);

    Top total = parallel_reduce<Top>(
        get_query_pool(), n_morsels, Top{},
        [&](Top& acc, int64_t m) {
            const uint64_t lo = static_cast<uint64_t>(m) * kMorsel;
            const uint64_t hi = std::min<uint64_t>(lo + kMorsel, n_rows);
            for (uint64_t i = lo; i < hi; ++i)
            {
                const uint64_t id = ids[i];
                if (id == 0)
                    continue;
                if (!acc.wants(id))
                    continue;
                if (id >= dict_size)
                    throw std::runtime_error("run_q26: SearchPhrase id out of range");
                acc.add(id);
            }
        },
        [&](Top& acc, const Top& part) {
            for (size_t k = 0; k < part.n; ++k)
                if (acc.wants(part.ids[k]))
                    acc.add(part.ids[k]);
        });

    std::vector<std::string> phrases;
    phrases.reserve(total.n);
    for (size_t k = 0; k < total.n; ++k)
        phrases.emplace_back(dict.get(total.ids[k]));

    return make_table({
        {"SearchPhrase", string_column(phrases)},
    });
}
