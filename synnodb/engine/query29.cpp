#include "query29.hpp"
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
/** SELECT REGEXP_REPLACE(Referer, '^https?://(?:www\.)?([^/]+)/.*$', '\1') AS k, AVG(STRLEN(Referer)) AS l, COUNT(*) AS c, MIN(Referer) FROM hits WHERE Referer <> '' GROUP BY k HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25; */

namespace {

constexpr uint64_t kParts = 256;

struct Pair
{
    uint64_t hash;
    uint64_t row;
    uint32_t koff;
    uint32_t klen;
};

struct P1
{
    std::vector<std::vector<Pair>> parts;
};

struct Ent
{
    uint64_t hash = 0;
    uint64_t cnt = 0;  // 0 == empty slot
    uint64_t sum = 0;  // sum of STRLEN(Referer) in bytes
    uint64_t rep_row = 0;
    uint32_t rep_koff = 0;
    uint32_t rep_klen = 0;
    uint64_t min_row = 0;
    uint64_t min_pre = 0;
};

struct Group
{
    std::string key;
    std::string min_ref;
    double avg;
    uint64_t cnt;
};

struct P2
{
    std::vector<Group> groups;
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

// First 8 bytes big-endian, zero padded: orders like byte-lexicographic comparison on ties-by-prefix.
inline uint64_t pre8(std::string_view s)
{
    uint64_t v = 0;
    const size_t n = std::min<size_t>(8, s.size());
    for (size_t i = 0; i < n; ++i)
        v |= static_cast<uint64_t>(static_cast<unsigned char>(s[i])) << (56 - 8 * i);
    return v;
}

// Strict UTF-8 validation (RE2 only matches valid UTF-8 text).
inline bool valid_utf8(const unsigned char* p, size_t n)
{
    size_t i = 0;
    while (i < n)
    {
        const unsigned char b = p[i];
        if (b < 0x80)
        {
            ++i;
            continue;
        }
        size_t need;
        unsigned char lo = 0x80, hi = 0xBF;
        if (b >= 0xC2 && b <= 0xDF)
            need = 1;
        else if (b >= 0xE0 && b <= 0xEF)
        {
            need = 2;
            if (b == 0xE0)
                lo = 0xA0;
            else if (b == 0xED)
                hi = 0x9F;
        }
        else if (b >= 0xF0 && b <= 0xF4)
        {
            need = 3;
            if (b == 0xF0)
                lo = 0x90;
            else if (b == 0xF4)
                hi = 0x8F;
        }
        else
            return false;
        if (i + need >= n)
            return false;
        if (p[i + 1] < lo || p[i + 1] > hi)
            return false;
        for (size_t k = 2; k <= need; ++k)
            if ((p[i + k] & 0xC0) != 0x80)
                return false;
        i += need + 1;
    }
    return true;
}

// Applies '^https?://(?:www\.)?([^/]+)/.*$' -> '\1'. Returns the key slice [koff, koff+klen) of the
// row; when the pattern does not match the key is the whole string.
inline void extract_key(const char* p, size_t n, bool ascii, uint32_t& koff, uint32_t& klen)
{
    koff = 0;
    klen = static_cast<uint32_t>(n);
    if (n < 9 || std::memcmp(p, "http", 4) != 0)
        return;
    size_t i = 4;
    if (p[i] == 's')
        ++i;
    if (i + 3 > n || p[i] != ':' || p[i + 1] != '/' || p[i + 2] != '/')
        return;
    i += 3;
    size_t hs = i;
    size_t q = n;  // position of the '/' that ends the host
    auto find_slash = [&](size_t from) -> size_t
    {
        if (from >= n)
            return n;
        const void* f = std::memchr(p + from, '/', n - from);
        return f ? static_cast<size_t>(static_cast<const char*>(f) - p) : n;
    };
    bool ok = false;
    if (i + 4 <= n && std::memcmp(p + i, "www.", 4) == 0)
    {
        const size_t s2 = i + 4;
        const size_t q2 = find_slash(s2);
        if (q2 < n && q2 > s2)
        {
            hs = s2;
            q = q2;
            ok = true;
        }
    }
    if (!ok)
    {
        const size_t q1 = find_slash(i);
        if (q1 < n && q1 > i)
        {
            hs = i;
            q = q1;
            ok = true;
        }
    }
    if (!ok)
        return;
    // '.*$' cannot cross a newline.
    if (q + 1 < n && std::memchr(p + q + 1, '\n', n - q - 1) != nullptr)
        return;
    if (!ascii)
    {
        bool high = false;
        for (size_t k = 0; k < n; ++k)
            if (static_cast<unsigned char>(p[k]) >= 0x80)
            {
                high = true;
                break;
            }
        if (high && !valid_utf8(reinterpret_cast<const unsigned char*>(p), n))
            return;
    }
    koff = static_cast<uint32_t>(hs);
    klen = static_cast<uint32_t>(q - hs);
}

}

std::shared_ptr<arrow::Table> run_q29(Database* db, const Q29Args& args) {
    if (!db) {
        throw std::runtime_error("run_q29: db is null");
    }
    (void)args;
    using namespace synnodb::egress;

    static_assert(kSuperRows % kChunkRows == 0, "morsels must not straddle super-chunks");

    const StringArena& ref = db->Referer;
    const uint64_t n_rows = db->n_rows;
    const int64_t n_morsels = static_cast<int64_t>((n_rows + kChunkRows - 1) / kChunkRows);
    if (ref.rows != n_rows || db->Referer_ascii.size() != static_cast<size_t>(n_morsels)) {
        throw std::runtime_error("run_q29: Referer column shape does not match the table");
    }

    // Phase 1: derive the group key per row and partition (hash, row) by hash.
    P1 p1 = parallel_reduce<P1>(
        get_query_pool(), n_morsels, P1{},
        [&](P1& acc, int64_t m) {
            if (acc.parts.empty())
                acc.parts.resize(kParts);
            const uint64_t lo = static_cast<uint64_t>(m) * kChunkRows;
            const uint64_t hi = std::min<uint64_t>(lo + kChunkRows, n_rows);
            const uint64_t s = lo / kSuperRows;
            const uint64_t j0 = lo % kSuperRows;
            const uint64_t j1 = j0 + (hi - lo);
            const uint32_t* o = ref.offs.data() + s * (kSuperRows + 1);
            const char* bytes = ref.bytes.data() + ref.base[s];
            const bool ascii = db->Referer_ascii[static_cast<size_t>(m)] != 0;
            for (uint64_t j = j0; j < j1; ++j)
            {
                const uint32_t len = o[j + 1] - o[j];
                if (len == 0)
                    continue;
                const char* p = bytes + o[j];
                uint32_t koff, klen;
                extract_key(p, len, ascii, koff, klen);
                const uint64_t h = hash_bytes(p + koff, klen);
                acc.parts[h & (kParts - 1)].push_back(Pair{h, s * kSuperRows + j, koff, klen});
            }
        },
        [&](P1& acc, const P1& part) {
            if (part.parts.empty())
                return;
            if (acc.parts.empty())
                acc.parts.resize(kParts);
            for (uint64_t k = 0; k < kParts; ++k)
            {
                auto& dst = acc.parts[k];
                const auto& src = part.parts[k];
                if (dst.empty())
                    dst = src;
                else
                    dst.insert(dst.end(), src.begin(), src.end());
            }
        });

    // Phase 2: aggregate each hash partition privately; keep only groups passing HAVING.
    P2 res = parallel_reduce<P2>(
        get_query_pool(), static_cast<int64_t>(p1.parts.empty() ? 0 : kParts), P2{},
        [&](P2& acc, int64_t pi) {
            const std::vector<Pair>& part = p1.parts[static_cast<size_t>(pi)];
            if (part.empty())
                return;
            std::vector<Ent> slots(1024);
            uint64_t used = 0;
            auto grow = [&]()
            {
                std::vector<Ent> old;
                old.swap(slots);
                slots.resize(old.size() * 2);
                const uint64_t mask = slots.size() - 1;
                for (const Ent& e : old)
                {
                    if (e.cnt == 0)
                        continue;
                    uint64_t p = (e.hash >> 8) & mask;
                    while (slots[p].cnt != 0)
                        p = (p + 1) & mask;
                    slots[p] = e;
                }
            };
            for (const Pair& pr : part)
            {
                const std::string_view sv = ref.get(pr.row);
                const std::string_view key = sv.substr(pr.koff, pr.klen);
                const uint64_t pre = pre8(sv);
                uint64_t mask = slots.size() - 1;
                uint64_t p = (pr.hash >> 8) & mask;
                Ent* hit = nullptr;
                for (;;)
                {
                    Ent& e = slots[p];
                    if (e.cnt == 0)
                        break;
                    if (e.hash == pr.hash && e.rep_klen == pr.klen
                        && ref.get(e.rep_row).substr(e.rep_koff, e.rep_klen) == key)
                    {
                        hit = &e;
                        break;
                    }
                    p = (p + 1) & mask;
                }
                if (hit)
                {
                    hit->cnt += 1;
                    hit->sum += sv.size();
                    if (pre < hit->min_pre
                        || (pre == hit->min_pre && sv < ref.get(hit->min_row)))
                    {
                        hit->min_row = pr.row;
                        hit->min_pre = pre;
                    }
                    continue;
                }
                if ((used + 1) * 2 > slots.size())
                {
                    grow();
                    mask = slots.size() - 1;
                    p = (pr.hash >> 8) & mask;
                    while (slots[p].cnt != 0)
                        p = (p + 1) & mask;
                }
                Ent& e = slots[p];
                e.hash = pr.hash;
                e.cnt = 1;
                e.sum = sv.size();
                e.rep_row = pr.row;
                e.rep_koff = pr.koff;
                e.rep_klen = pr.klen;
                e.min_row = pr.row;
                e.min_pre = pre;
                ++used;
            }
            for (const Ent& e : slots)
            {
                if (e.cnt > 100000)
                {
                    const std::string_view k = ref.get(e.rep_row).substr(e.rep_koff, e.rep_klen);
                    const std::string_view mn = ref.get(e.min_row);
                    acc.groups.push_back(Group{std::string(k), std::string(mn),
                        static_cast<double>(e.sum) / static_cast<double>(e.cnt), e.cnt});
                }
            }
        },
        [&](P2& acc, const P2& part) {
            acc.groups.insert(acc.groups.end(), part.groups.begin(), part.groups.end());
        });

    std::vector<Group>& groups = res.groups;
    const size_t topk = std::min<size_t>(25, groups.size());
    std::partial_sort(groups.begin(), groups.begin() + topk, groups.end(), [](const Group& a, const Group& b) {
        if (a.avg != b.avg)
            return a.avg > b.avg;
        return a.key < b.key;
    });

    std::vector<std::string> keys, mins;
    std::vector<double> avgs;
    std::vector<int64_t> counts;
    for (size_t i = 0; i < topk; ++i)
    {
        keys.push_back(groups[i].key);
        avgs.push_back(groups[i].avg);
        counts.push_back(static_cast<int64_t>(groups[i].cnt));
        mins.push_back(groups[i].min_ref);
    }

    return make_table({
        {"k", string_column(keys)},
        {"l", double_column(avgs)},
        {"c", integer_column(counts, {}, arrow::int64())},
        {"min(Referer)", string_column(mins)},
    });
}
