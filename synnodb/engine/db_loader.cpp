#include "db_loader.hpp"

#include "column_ingest.hpp"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <exception>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <utility>

using namespace synnodb::ingest;

namespace {

// Rows per decode task. Strings are decoded through std::string, so their slices are small to
// bound the transient memory per worker thread.
constexpr uint64_t kScalarSlice = 1ull << 18;
constexpr uint64_t kArenaSlice = 1ull << 14;
constexpr uint64_t kDictSlice = 1ull << 16;
static_assert(kSuperRows % kArenaSlice == 0, "arena slice must divide the super-chunk");
static_assert(kArenaSlice <= kChunkRows && kChunkRows % kArenaSlice == 0, "arena slice must divide the chunk");

unsigned worker_count()
{
    unsigned h = std::thread::hardware_concurrency();
    if (h == 0)
        h = 16;
    return std::min(h, 96u);
}

// Runs fn(0..n-1) on up to worker_count() threads; rethrows the first exception.
void parallel_for_n(size_t n, const std::function<void(size_t)> & fn)
{
    const size_t nt = std::min<size_t>(worker_count(), n);
    if (nt <= 1)
    {
        for (size_t i = 0; i < n; ++i)
            fn(i);
        return;
    }
    std::atomic<size_t> next{0};
    std::atomic<bool> failed{false};
    std::exception_ptr err;
    std::mutex mu;
    auto work = [&]
    {
        while (!failed.load(std::memory_order_relaxed))
        {
            const size_t i = next.fetch_add(1);
            if (i >= n)
                return;
            try
            {
                fn(i);
            }
            catch (...)
            {
                std::lock_guard<std::mutex> l(mu);
                if (!err)
                    err = std::current_exception();
                failed.store(true);
                return;
            }
        }
    };
    std::vector<std::thread> threads;
    threads.reserve(nt - 1);
    for (size_t k = 1; k < nt; ++k)
        threads.emplace_back(work);
    work();
    for (auto & t : threads)
        t.join();
    if (err)
        std::rethrow_exception(err);
}

uint64_t num_supers(uint64_t n)
{
    return (n + kSuperRows - 1) / kSuperRows;
}

std::shared_ptr<arrow::ChunkedArray> slice_of(const std::shared_ptr<arrow::ChunkedArray> & c, uint64_t off, uint64_t len)
{
    return c->Slice(static_cast<int64_t>(off), static_cast<int64_t>(len));
}

// One column's load pipeline. Phases (each over all columns at once):
//   prep (per column) -> p1 (per slice) -> fin (per column) -> p2 (per slice) -> done (per column)
struct ColTask
{
    uint64_t n1 = 0;
    uint64_t n2 = 0;
    std::function<void()> prep;
    std::function<void(uint64_t)> p1;
    std::function<void()> fin;
    std::function<void(uint64_t)> p2;
    std::function<void()> done;
};

void run_per_column(std::vector<ColTask> & cols, std::function<void()> ColTask::*member)
{
    parallel_for_n(cols.size(), [&](size_t i)
    {
        if (cols[i].*member)
            (cols[i].*member)();
    });
}

void run_slices(std::vector<ColTask> & cols, bool second)
{
    std::vector<std::pair<uint32_t, uint64_t>> v;
    for (uint32_t ci = 0; ci < cols.size(); ++ci)
    {
        const uint64_t cnt = second ? cols[ci].n2 : cols[ci].n1;
        for (uint64_t k = 0; k < cnt; ++k)
            v.emplace_back(ci, k);
    }
    parallel_for_n(v.size(), [&](size_t i)
    {
        auto & c = cols[v[i].first];
        if (second)
            c.p2(v[i].second);
        else
            c.p1(v[i].second);
    });
}

// ---- scalar columns -------------------------------------------------------------------------
template <class T>
void add_int(std::vector<ColTask> & cols, const arrow::Table & t, const std::string & name, std::vector<T> & dst)
{
    auto col = column(t, name);
    const uint64_t n = static_cast<uint64_t>(col->length());
    ColTask c;
    c.n1 = (n + kScalarSlice - 1) / kScalarSlice;
    c.prep = [&dst, n] { dst.resize(n); };
    c.p1 = [col, &dst, n, name](uint64_t k)
    {
        const uint64_t off = k * kScalarSlice;
        const uint64_t len = std::min(kScalarSlice, n - off);
        auto v = as_integer<T>(slice_of(col, off, len));
        if (v.size() != len)
            throw std::runtime_error("integer slice length mismatch: " + name);
        std::memcpy(dst.data() + off, v.data(), len * sizeof(T));
    };
    cols.push_back(std::move(c));
}

void add_date_u16(std::vector<ColTask> & cols, const arrow::Table & t, const std::string & name, std::vector<uint16_t> & dst)
{
    auto col = column(t, name);
    const uint64_t n = static_cast<uint64_t>(col->length());
    ColTask c;
    c.n1 = (n + kScalarSlice - 1) / kScalarSlice;
    c.prep = [&dst, n] { dst.resize(n); };
    c.p1 = [col, &dst, n, name](uint64_t k)
    {
        const uint64_t off = k * kScalarSlice;
        const uint64_t len = std::min(kScalarSlice, n - off);
        auto days = as_date_days(slice_of(col, off, len));
        if (days.size() != len)
            throw std::runtime_error("date slice length mismatch: " + name);
        uint16_t * out = dst.data() + off;
        for (uint64_t i = 0; i < len; ++i)
        {
            if (days[i] < 0 || days[i] > std::numeric_limits<uint16_t>::max())
                throw std::runtime_error("date out of uint16 day range: " + name);
            out[i] = static_cast<uint16_t>(days[i]);
        }
    };
    cols.push_back(std::move(c));
}

void add_timestamp(std::vector<ColTask> & cols, const arrow::Table & t, const std::string & name, std::vector<int64_t> & dst)
{
    auto col = column(t, name);
    const uint64_t n = static_cast<uint64_t>(col->length());
    ColTask c;
    c.n1 = (n + kScalarSlice - 1) / kScalarSlice;
    c.prep = [&dst, n] { dst.resize(n); };
    c.p1 = [col, &dst, n, name](uint64_t k)
    {
        const uint64_t off = k * kScalarSlice;
        const uint64_t len = std::min(kScalarSlice, n - off);
        auto v = as_timestamp_micros(slice_of(col, off, len));
        if (v.size() != len)
            throw std::runtime_error("timestamp slice length mismatch: " + name);
        std::memcpy(dst.data() + off, v.data(), len * sizeof(int64_t));
    };
    cols.push_back(std::move(c));
}

// ---- string arena ---------------------------------------------------------------------------
// p1: decode a slice, store each row's length in its offs slot, and the slice's byte total.
// fin: per-super-chunk totals -> 64-bit bases, allocate the byte buffer (uninitialised).
// p2: decode again, turn lengths into super-chunk-relative cumulative offsets, copy the bytes,
//     and record whether the slice is pure ASCII.
void add_arena(std::vector<ColTask> & cols, const arrow::Table & t, const std::string & name, StringArena & a,
               std::vector<uint8_t> * ascii_flags)
{
    struct State
    {
        std::vector<uint64_t> sub_bytes;
        std::vector<uint8_t> sub_ascii;
    };
    auto col = column(t, name);
    const uint64_t n = static_cast<uint64_t>(col->length());
    const uint64_t ns = num_supers(n);
    const uint64_t nsub = (n + kArenaSlice - 1) / kArenaSlice;
    const uint64_t subs_per_super = kSuperRows / kArenaSlice;
    auto st = std::make_shared<State>();

    ColTask c;
    c.n1 = nsub;
    c.n2 = nsub;
    c.prep = [&a, ascii_flags, st, n, ns, nsub]
    {
        a.rows = n;
        a.offs.assign(n + ns, 0);
        a.base.assign(ns + 1, 0);
        st->sub_bytes.assign(nsub, 0);
        st->sub_ascii.assign(nsub, 1);
        if (ascii_flags)
            ascii_flags->assign((n + kChunkRows - 1) / kChunkRows, 1);
    };
    c.p1 = [col, &a, st, n, name](uint64_t k)
    {
        const uint64_t row0 = k * kArenaSlice;
        const uint64_t len = std::min(kArenaSlice, n - row0);
        auto strs = as_string(slice_of(col, row0, len));
        if (strs.size() != len)
            throw std::runtime_error("string slice length mismatch: " + name);
        const uint64_t s = row0 / kSuperRows;
        const uint64_t j0 = row0 % kSuperRows;
        uint32_t * o = a.offs.data() + s * (kSuperRows + 1) + j0 + 1;
        uint64_t sum = 0;
        for (uint64_t i = 0; i < len; ++i)
        {
            o[i] = static_cast<uint32_t>(strs[i].size());
            sum += strs[i].size();
        }
        st->sub_bytes[k] = sum;
    };
    c.fin = [&a, st, ns, nsub, subs_per_super, name]
    {
        for (uint64_t s = 0; s < ns; ++s)
        {
            uint64_t tot = 0;
            const uint64_t k0 = s * subs_per_super;
            const uint64_t k1 = std::min(nsub, k0 + subs_per_super);
            for (uint64_t k = k0; k < k1; ++k)
                tot += st->sub_bytes[k];
            if (tot > std::numeric_limits<uint32_t>::max())
                throw std::runtime_error("string arena super-chunk exceeds 4 GiB: " + name);
            a.base[s + 1] = a.base[s] + tot;
        }
        a.bytes.resize_uninit(a.base[ns]);
    };
    c.p2 = [col, &a, st, n, name, subs_per_super](uint64_t k)
    {
        const uint64_t row0 = k * kArenaSlice;
        const uint64_t len = std::min(kArenaSlice, n - row0);
        auto strs = as_string(slice_of(col, row0, len));
        if (strs.size() != len)
            throw std::runtime_error("string slice length mismatch: " + name);
        const uint64_t s = row0 / kSuperRows;
        const uint64_t j0 = row0 % kSuperRows;
        uint32_t * o = a.offs.data() + s * (kSuperRows + 1) + j0 + 1;
        uint64_t cum = 0;
        for (uint64_t kk = (k / subs_per_super) * subs_per_super; kk < k; ++kk)
            cum += st->sub_bytes[kk];
        char * dst = a.bytes.data() + a.base[s];
        unsigned acc = 0;
        for (uint64_t i = 0; i < len; ++i)
        {
            const std::string & x = strs[i];
            if (o[i] != x.size())
                throw std::runtime_error("string arena changed between passes: " + name);
            if (!x.empty())
            {
                std::memcpy(dst + cum, x.data(), x.size());
                for (unsigned char ch : x)
                    acc |= ch;
            }
            cum += x.size();
            o[i] = static_cast<uint32_t>(cum);
        }
        st->sub_ascii[k] = (acc & 0x80u) ? 0 : 1;
    };
    c.done = [ascii_flags, st, nsub]
    {
        if (!ascii_flags)
            return;
        const uint64_t per_chunk = kChunkRows / kArenaSlice;
        for (uint64_t k = 0; k < nsub; ++k)
            if (!st->sub_ascii[k])
                (*ascii_flags)[k / per_chunk] = 0;
        st->sub_bytes.clear();
        st->sub_bytes.shrink_to_fit();
    };
    cols.push_back(std::move(c));
}

// ---- dictionary -----------------------------------------------------------------------------
// Merges the sorted runs v[bounds[i]..bounds[i+1]) into one sorted range.
void merge_runs(std::vector<std::string_view> & v, std::vector<size_t> bounds)
{
    while (bounds.size() > 2)
    {
        const size_t pairs = (bounds.size() - 1) / 2;
        auto do_merge = [&](size_t p)
        {
            std::inplace_merge(v.begin() + bounds[2 * p], v.begin() + bounds[2 * p + 1], v.begin() + bounds[2 * p + 2]);
        };
        if (v.size() >= (1u << 16) && pairs > 1)
            parallel_for_n(pairs, do_merge);
        else
            for (size_t p = 0; p < pairs; ++p)
                do_merge(p);
        std::vector<size_t> nb;
        nb.push_back(0);
        for (size_t p = 0; p < pairs; ++p)
            nb.push_back(bounds[2 * p + 2]);
        if ((bounds.size() - 1) % 2 == 1)
            nb.push_back(bounds.back());
        bounds = std::move(nb);
    }
}

// p1: decode a slice once, build a slice-local first-seen dictionary, write local ids into the
//     final id array.
// fin: merge the per-slice sorted distinct lists into the global sorted dictionary.
// p2: map local ids to global ids (lookups only for the slice's distinct strings).
template <class IdT>
void add_dict(std::vector<ColTask> & cols, const arrow::Table & t, const std::string & name, DictColumn<IdT> & dc)
{
    struct State
    {
        std::vector<std::vector<std::string>> local;
        std::vector<std::vector<std::string_view>> sorted;
        std::vector<std::string_view> g;
    };
    auto col = column(t, name);
    const uint64_t n = static_cast<uint64_t>(col->length());
    const uint64_t nsl = (n + kDictSlice - 1) / kDictSlice;
    auto st = std::make_shared<State>();

    ColTask c;
    c.n1 = nsl;
    c.n2 = nsl;
    c.prep = [&dc, st, n, nsl]
    {
        dc.ids.assign(n, 0);
        st->local.assign(nsl, {});
        st->sorted.assign(nsl, {});
    };
    c.p1 = [col, &dc, st, n, name](uint64_t k)
    {
        const uint64_t row0 = k * kDictSlice;
        const uint64_t len = std::min(kDictSlice, n - row0);
        auto strs = as_string(slice_of(col, row0, len));
        if (strs.size() != len)
            throw std::runtime_error("string slice length mismatch: " + name);
        std::unordered_map<std::string_view, uint32_t> m;
        auto & loc = st->local[k];
        IdT * out = dc.ids.data() + row0;
        for (uint64_t i = 0; i < len; ++i)
        {
            const std::string & x = strs[i];
            if (x.empty())
                continue;
            const std::string_view sv(x);
            auto it = m.find(sv);
            uint32_t id;
            if (it == m.end())
            {
                loc.emplace_back(sv);
                id = static_cast<uint32_t>(loc.size());
                if (id > std::numeric_limits<IdT>::max())
                    throw std::runtime_error("dictionary too large for id type: " + name);
                m.emplace(sv, id);
            }
            else
                id = it->second;
            out[i] = static_cast<IdT>(id);
        }
        auto & srt = st->sorted[k];
        srt.reserve(loc.size());
        for (const auto & s : loc)
            srt.emplace_back(s);
        std::sort(srt.begin(), srt.end());
    };
    c.fin = [&dc, st, nsl, name]
    {
        std::vector<std::string_view> g;
        std::vector<size_t> bounds;
        size_t total = 0;
        for (const auto & s : st->sorted)
            total += s.size();
        g.reserve(total);
        bounds.push_back(0);
        for (const auto & s : st->sorted)
        {
            g.insert(g.end(), s.begin(), s.end());
            bounds.push_back(g.size());
        }
        merge_runs(g, std::move(bounds));
        g.erase(std::unique(g.begin(), g.end()), g.end());
        if (g.size() > std::numeric_limits<IdT>::max())
            throw std::runtime_error("dictionary too large for id type: " + name);

        size_t bytes = 0;
        for (auto x : g)
            bytes += x.size();
        dc.dict.bytes.resize(bytes);
        dc.dict.off.assign(g.size() + 2, 0);
        uint64_t cur = 0;
        for (size_t i = 0; i < g.size(); ++i)
        {
            if (!g[i].empty())
                std::memcpy(dc.dict.bytes.data() + cur, g[i].data(), g[i].size());
            cur += g[i].size();
            dc.dict.off[i + 2] = cur;
        }
        st->g = std::move(g);
        (void)nsl;
    };
    c.p2 = [&dc, st, n, name](uint64_t k)
    {
        const uint64_t row0 = k * kDictSlice;
        const uint64_t len = std::min(kDictSlice, n - row0);
        const auto & loc = st->local[k];
        if (loc.empty())
            return;
        const auto & g = st->g;
        std::vector<IdT> map(loc.size() + 1, 0);
        for (size_t i = 0; i < loc.size(); ++i)
        {
            const std::string_view sv(loc[i]);
            auto it = std::lower_bound(g.begin(), g.end(), sv);
            if (it == g.end() || *it != sv)
                throw std::runtime_error("dictionary lookup failed: " + name);
            map[i + 1] = static_cast<IdT>(it - g.begin() + 1);
        }
        IdT * out = dc.ids.data() + row0;
        for (uint64_t i = 0; i < len; ++i)
            out[i] = map[out[i]];
    };
    c.done = [st]
    {
        st->local.clear();
        st->local.shrink_to_fit();
        st->sorted.clear();
        st->sorted.shrink_to_fit();
        st->g.clear();
        st->g.shrink_to_fit();
    };
    cols.push_back(std::move(c));
}

// ---- zone maps (per-chunk min/max) ------------------------------------------------------------------------------
template <class T>
void build_zone(const std::vector<T> & v, ZoneMap<T> & z)
{
    const uint64_t n = v.size();
    const uint64_t nc = (n + kChunkRows - 1) / kChunkRows;
    z.mn.assign(nc, 0);
    z.mx.assign(nc, 0);
    for (uint64_t c = 0; c < nc; ++c)
    {
        const uint64_t r0 = c * kChunkRows;
        const uint64_t r1 = std::min(n, r0 + kChunkRows);
        auto mm = std::minmax_element(v.begin() + r0, v.begin() + r1);
        z.mn[c] = *mm.first;
        z.mx[c] = *mm.second;
    }
}

template <class T>
void build_range(const std::vector<T> & v, T & mn, T & mx)
{
    if (v.empty())
        return;
    auto mm = std::minmax_element(v.begin(), v.end());
    mn = *mm.first;
    mx = *mm.second;
}

}  // namespace


Database * build(ParquetTables * tables)
{
    // Own the partial dataset while it is being built: if any step below throws (a large build
    // running out of memory is the expected case), unwinding destroys db and frees everything it
    // owns. Ownership is handed to the caller only once build() succeeds.
    auto db = std::make_unique<Database>();
    Database * d = db.get();
    const arrow::Table & t = *tables->hits;
    d->n_rows = static_cast<uint64_t>(t.num_rows());

    // All columns are described as slice tasks and run on one shared worker pool. String
    // columns are listed first so the longest tasks start first.
    std::vector<ColTask> cols;
    add_arena(cols, t, "URL", d->URL, &d->URL_ascii);
    add_arena(cols, t, "Title", d->Title, &d->Title_ascii);
    add_arena(cols, t, "Referer", d->Referer, &d->Referer_ascii);
    add_arena(cols, t, "OriginalURL", d->OriginalURL, nullptr);
    add_arena(cols, t, "SocialSourcePage", d->SocialSourcePage, nullptr);

#define LOAD_DICT(NAME) add_dict(cols, t, #NAME, d->NAME)
    LOAD_DICT(SearchPhrase);
    LOAD_DICT(MobilePhoneModel);
    LOAD_DICT(FlashMinor2);
    LOAD_DICT(UserAgentMinor);
    LOAD_DICT(PageCharset);
    LOAD_DICT(HitColor);
    LOAD_DICT(BrowserLanguage);
    LOAD_DICT(BrowserCountry);
    LOAD_DICT(SocialNetwork);
    LOAD_DICT(SocialAction);
    LOAD_DICT(ParamCurrency);
    LOAD_DICT(Params);
    LOAD_DICT(ParamOrderID);
    LOAD_DICT(OpenstatServiceName);
    LOAD_DICT(OpenstatCampaignID);
    LOAD_DICT(OpenstatAdID);
    LOAD_DICT(OpenstatSourceID);
    LOAD_DICT(UTMSource);
    LOAD_DICT(UTMMedium);
    LOAD_DICT(UTMCampaign);
    LOAD_DICT(UTMContent);
    LOAD_DICT(UTMTerm);
    LOAD_DICT(FromTag);
#undef LOAD_DICT

#define LOAD_INT(T, NAME) add_int<T>(cols, t, #NAME, d->NAME)
    LOAD_INT(int64_t, WatchID);
    LOAD_INT(int32_t, CounterID);
    LOAD_INT(int32_t, ClientIP);
    LOAD_INT(int32_t, RegionID);
    LOAD_INT(int64_t, UserID);
    LOAD_INT(int32_t, RefererRegionID);
    LOAD_INT(int32_t, URLRegionID);
    LOAD_INT(int32_t, IPNetworkID);
    LOAD_INT(int32_t, SilverlightVersion3);
    LOAD_INT(int32_t, CodeVersion);
    LOAD_INT(int64_t, FUniqID);
    LOAD_INT(int32_t, HID);
    LOAD_INT(int32_t, RemoteIP);
    LOAD_INT(int32_t, WindowName);
    LOAD_INT(int32_t, OpenerName);
    LOAD_INT(int32_t, SendTiming);
    LOAD_INT(int32_t, DNSTiming);
    LOAD_INT(int32_t, ConnectTiming);
    LOAD_INT(int32_t, ResponseStartTiming);
    LOAD_INT(int32_t, ResponseEndTiming);
    LOAD_INT(int32_t, FetchTiming);
    LOAD_INT(int64_t, ParamPrice);
    LOAD_INT(int64_t, RefererHash);
    LOAD_INT(int64_t, URLHash);
    LOAD_INT(int32_t, CLID);

    LOAD_INT(uint8_t, JavaEnable);
    LOAD_INT(uint8_t, GoodEvent);
    LOAD_INT(uint8_t, CounterClass);
    LOAD_INT(uint8_t, IsRefresh);
    LOAD_INT(uint8_t, CookieEnable);
    LOAD_INT(uint8_t, JavascriptEnable);
    LOAD_INT(uint8_t, IsMobile);
    LOAD_INT(uint8_t, IsArtifical);
    LOAD_INT(uint8_t, IsLink);
    LOAD_INT(uint8_t, IsDownload);
    LOAD_INT(uint8_t, IsNotBounce);
    LOAD_INT(uint8_t, IsOldCounter);
    LOAD_INT(uint8_t, IsEvent);
    LOAD_INT(uint8_t, IsParameter);
    LOAD_INT(uint8_t, DontCountHits);
    LOAD_INT(uint8_t, WithHash);
    LOAD_INT(uint8_t, HasGCLID);

    LOAD_INT(int16_t, OS);
    LOAD_INT(int16_t, UserAgent);
    LOAD_INT(int16_t, RefererCategoryID);
    LOAD_INT(int16_t, URLCategoryID);
    LOAD_INT(int16_t, ResolutionWidth);
    LOAD_INT(int16_t, ResolutionHeight);
    LOAD_INT(int16_t, ResolutionDepth);
    LOAD_INT(int16_t, FlashMajor);
    LOAD_INT(int16_t, FlashMinor);
    LOAD_INT(int16_t, NetMajor);
    LOAD_INT(int16_t, NetMinor);
    LOAD_INT(int16_t, UserAgentMajor);
    LOAD_INT(int16_t, MobilePhone);
    LOAD_INT(int16_t, TraficSourceID);
    LOAD_INT(int16_t, SearchEngineID);
    LOAD_INT(int16_t, AdvEngineID);
    LOAD_INT(int16_t, WindowClientWidth);
    LOAD_INT(int16_t, WindowClientHeight);
    LOAD_INT(int16_t, ClientTimeZone);
    LOAD_INT(int16_t, SilverlightVersion1);
    LOAD_INT(int16_t, SilverlightVersion2);
    LOAD_INT(int16_t, SilverlightVersion4);
    LOAD_INT(int16_t, Age);
    LOAD_INT(int16_t, Sex);
    LOAD_INT(int16_t, Income);
    LOAD_INT(int16_t, Interests);
    LOAD_INT(int16_t, Robotness);
    LOAD_INT(int16_t, HistoryLength);
    LOAD_INT(int16_t, HTTPError);
    LOAD_INT(int16_t, SocialSourceNetworkID);
    LOAD_INT(int16_t, ParamCurrencyID);
#undef LOAD_INT

    add_date_u16(cols, t, "EventDate", d->EventDate);
    add_timestamp(cols, t, "EventTime", d->EventTime);
    add_timestamp(cols, t, "ClientEventTime", d->ClientEventTime);
    add_timestamp(cols, t, "LocalEventTime", d->LocalEventTime);

    run_per_column(cols, &ColTask::prep);
    run_slices(cols, false);
    run_per_column(cols, &ColTask::fin);
    run_slices(cols, true);
    run_per_column(cols, &ColTask::done);

    // Zone maps and statistics (metadata for chunk skipping only).
    std::vector<std::function<void()>> jobs;
    jobs.push_back([d] { build_zone(d->CounterID, d->zone_CounterID); });
    jobs.push_back([d] { build_zone(d->EventDate, d->zone_EventDate); });
    jobs.push_back([d] { build_zone(d->AdvEngineID, d->zone_AdvEngineID); });
    jobs.push_back([d] { build_zone(d->SearchEngineID, d->zone_SearchEngineID); });
    jobs.push_back([d] { build_zone(d->TraficSourceID, d->zone_TraficSourceID); });
    jobs.push_back([d] { build_zone(d->IsRefresh, d->zone_IsRefresh); });
    jobs.push_back([d] { build_zone(d->DontCountHits, d->zone_DontCountHits); });
    jobs.push_back([d] { build_zone(d->IsLink, d->zone_IsLink); });
    jobs.push_back([d] { build_zone(d->IsDownload, d->zone_IsDownload); });
    jobs.push_back([d] { build_range(d->CounterID, d->CounterID_min, d->CounterID_max); });
    jobs.push_back([d] { build_range(d->RegionID, d->RegionID_min, d->RegionID_max); });
    parallel_for_n(jobs.size(), [&](size_t i) { jobs[i](); });

    return db.release();
}

void destroy_database(Database * db)
{
    delete db;
}
