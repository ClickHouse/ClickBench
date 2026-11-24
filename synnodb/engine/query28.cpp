#include "query28.hpp"
#include "column_egress.hpp"
#include "query_pool.hpp"

#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <vector>

// SQL:
/** SELECT CounterID, AVG(STRLEN(URL)) AS l, COUNT(*) AS c FROM hits WHERE URL <> '' GROUP BY CounterID HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25; */

namespace {

struct Ent
{
    int32_t key = 0;
    uint64_t cnt = 0;  // 0 == empty slot
    uint64_t sum = 0;  // sum of STRLEN(URL) in bytes
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

// Flat open-addressing table keyed by CounterID; grows at 50% load.
struct Table
{
    std::vector<Ent> slots;
    uint64_t used = 0;

    inline Ent& find_or_insert(int32_t key)
    {
        if (slots.empty())
            slots.resize(1024);
        if ((used + 1) * 2 > slots.size())
            grow();
        const uint64_t mask = slots.size() - 1;
        uint64_t p = mix64(static_cast<uint32_t>(key)) & mask;
        for (;;)
        {
            Ent& e = slots[p];
            if (e.cnt == 0)
            {
                e.key = key;
                ++used;
                return e;
            }
            if (e.key == key)
                return e;
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
            uint64_t p = mix64(static_cast<uint32_t>(e.key)) & mask;
            while (slots[p].cnt != 0)
                p = (p + 1) & mask;
            slots[p] = e;
        }
    }
};

}

std::shared_ptr<arrow::Table> run_q28(Database* db, const Q28Args& args) {
    if (!db) {
        throw std::runtime_error("run_q28: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    static_assert(kSuperRows % kChunkRows == 0, "morsels must not straddle super-chunks");

    const StringArena& url = db->URL;
    const auto& counter = db->CounterID;
    const uint64_t n_rows = db->n_rows;
    if (url.rows != n_rows || counter.size() != n_rows) {
        throw std::runtime_error("run_q28: column row counts do not match the table");
    }
    const int64_t n_morsels = static_cast<int64_t>((n_rows + kChunkRows - 1) / kChunkRows);

    Table total = parallel_reduce<Table>(
        get_query_pool(), n_morsels, Table{},
        [&](Table& acc, int64_t m) {
            const uint64_t lo = static_cast<uint64_t>(m) * kChunkRows;
            const uint64_t hi = std::min<uint64_t>(lo + kChunkRows, n_rows);
            const uint64_t s = lo / kSuperRows;
            const uint64_t j0 = lo % kSuperRows;
            const uint64_t j1 = j0 + (hi - lo);
            const uint32_t* o = url.offs.data() + s * (kSuperRows + 1);
            const int32_t* c = counter.data() + s * kSuperRows;

            // Rows of a chunk mostly share few CounterIDs: aggregate runs of equal keys locally.
            int32_t run_key = 0;
            uint64_t run_cnt = 0;
            uint64_t run_sum = 0;
            for (uint64_t j = j0; j < j1; ++j)
            {
                const uint32_t len = o[j + 1] - o[j];
                if (len == 0)
                    continue;
                const int32_t k = c[j];
                if (run_cnt != 0 && k == run_key)
                {
                    ++run_cnt;
                    run_sum += len;
                    continue;
                }
                if (run_cnt != 0)
                {
                    Ent& e = acc.find_or_insert(run_key);
                    e.cnt += run_cnt;
                    e.sum += run_sum;
                }
                run_key = k;
                run_cnt = 1;
                run_sum = len;
            }
            if (run_cnt != 0)
            {
                Ent& e = acc.find_or_insert(run_key);
                e.cnt += run_cnt;
                e.sum += run_sum;
            }
        },
        [&](Table& acc, const Table& part) {
            for (const Ent& pe : part.slots)
            {
                if (pe.cnt == 0)
                    continue;
                Ent& e = acc.find_or_insert(pe.key);
                e.cnt += pe.cnt;
                e.sum += pe.sum;
            }
        });

    struct Out
    {
        int32_t key;
        double avg;
        uint64_t cnt;
    };
    std::vector<Out> groups;
    for (const Ent& e : total.slots)
    {
        if (e.cnt > 100000)
            groups.push_back({e.key, static_cast<double>(e.sum) / static_cast<double>(e.cnt), e.cnt});
    }
    const size_t topk = std::min<size_t>(25, groups.size());
    std::partial_sort(groups.begin(), groups.begin() + topk, groups.end(), [](const Out& a, const Out& b) {
        if (a.avg != b.avg)
            return a.avg > b.avg;
        return a.key < b.key;
    });

    std::vector<int32_t> keys;
    std::vector<double> avgs;
    std::vector<int64_t> counts;
    for (size_t i = 0; i < topk; ++i)
    {
        keys.push_back(groups[i].key);
        avgs.push_back(groups[i].avg);
        counts.push_back(static_cast<int64_t>(groups[i].cnt));
    }

    return make_table({
        {"CounterID", integer_column(keys, {}, arrow::int32())},
        {"l", double_column(avgs)},
        {"c", integer_column(counts, {}, arrow::int64())},
    });
}
