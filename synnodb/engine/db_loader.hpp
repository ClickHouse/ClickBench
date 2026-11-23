#pragma once

#include "parquet_reader.hpp"

#include <cstdint>
#include <memory>
#include <string_view>
#include <vector>

// Rows per zone-map chunk (rows are grouped into fixed-size chunks).
constexpr uint64_t kChunkRows = 1ull << 16;
// Rows per string-arena super-chunk (multiple of kChunkRows). Offsets inside a super-chunk are
// 32-bit and relative to the super-chunk's byte base; the base itself is 64-bit.
constexpr uint64_t kSuperRows = 1ull << 20;

// Variable-length string column: contiguous bytes + 32-bit super-chunk-relative offsets.
// Empty strings occupy zero bytes. Row i is get(i).
// Uninitialized byte buffer (no zero-fill on resize; the owner fills every byte).
struct ByteBuf {
    std::unique_ptr<char[]> buf;
    uint64_t n = 0;

    char * data() { return buf.get(); }
    const char * data() const { return buf.get(); }
    uint64_t size() const { return n; }
    void resize_uninit(uint64_t m) {
        buf.reset(m ? new char[m] : nullptr);
        n = m;
    }
};

struct StringArena {
    ByteBuf bytes;
    std::vector<uint64_t> base;  // base[s] = byte start of super-chunk s; base[nsuper] = total
    std::vector<uint32_t> offs;  // super-chunk s: (rows_in_s + 1) entries starting at s*(kSuperRows+1)
    uint64_t rows = 0;

    std::string_view get(uint64_t i) const {
        const uint64_t s = i / kSuperRows;
        const uint64_t j = i % kSuperRows;
        const uint32_t* o = offs.data() + s * (kSuperRows + 1) + j;
        return std::string_view(bytes.data() + base[s] + o[0], o[1] - o[0]);
    }
    uint32_t length(uint64_t i) const {
        const uint64_t s = i / kSuperRows;
        const uint64_t j = i % kSuperRows;
        const uint32_t* o = offs.data() + s * (kSuperRows + 1) + j;
        return o[1] - o[0];
    }
};

// Dictionary of distinct strings. Id 0 is always the empty string; ids 1.. are the distinct
// non-empty values in byte-lexicographic order, so id order == string order.
struct StringDict {
    std::vector<char> bytes;
    std::vector<uint64_t> off;  // size() + 1 entries
    uint64_t size() const { return off.empty() ? 0 : off.size() - 1; }
    std::string_view get(uint64_t id) const {
        return std::string_view(bytes.data() + off[id], off[id + 1] - off[id]);
    }
};

template <class IdT>
struct DictColumn {
    StringDict dict;
    std::vector<IdT> ids;  // one per row
    std::string_view get(uint64_t row) const { return dict.get(ids[row]); }
};

// Per-chunk (kChunkRows rows) min / max of a column. Used only to skip chunks.
template <class T>
struct ZoneMap {
    std::vector<T> mn;
    std::vector<T> mx;
};

struct Database {
    // Every owning member is RAII (std::vector / value types) so a partially built Database
    // frees everything on the throw path.
    uint64_t n_rows = 0;

    // ---- 64-bit / 32-bit integer columns ----
    std::vector<int64_t> WatchID;
    std::vector<int32_t> CounterID;
    std::vector<int32_t> ClientIP;
    std::vector<int32_t> RegionID;
    std::vector<int64_t> UserID;
    std::vector<int32_t> RefererRegionID;
    std::vector<int32_t> URLRegionID;
    std::vector<int32_t> IPNetworkID;
    std::vector<int32_t> SilverlightVersion3;
    std::vector<int32_t> CodeVersion;
    std::vector<int64_t> FUniqID;
    std::vector<int32_t> HID;
    std::vector<int32_t> RemoteIP;
    std::vector<int32_t> WindowName;
    std::vector<int32_t> OpenerName;
    std::vector<int32_t> SendTiming;
    std::vector<int32_t> DNSTiming;
    std::vector<int32_t> ConnectTiming;
    std::vector<int32_t> ResponseStartTiming;
    std::vector<int32_t> ResponseEndTiming;
    std::vector<int32_t> FetchTiming;
    std::vector<int64_t> ParamPrice;
    std::vector<int64_t> RefererHash;
    std::vector<int64_t> URLHash;
    std::vector<int32_t> CLID;

    // ---- 0/1 flag columns (uint8_t; the loader range-checks and throws otherwise) ----
    std::vector<uint8_t> JavaEnable;
    std::vector<uint8_t> GoodEvent;
    std::vector<uint8_t> CounterClass;
    std::vector<uint8_t> IsRefresh;
    std::vector<uint8_t> CookieEnable;
    std::vector<uint8_t> JavascriptEnable;
    std::vector<uint8_t> IsMobile;
    std::vector<uint8_t> IsArtifical;
    std::vector<uint8_t> IsLink;
    std::vector<uint8_t> IsDownload;
    std::vector<uint8_t> IsNotBounce;
    std::vector<uint8_t> IsOldCounter;
    std::vector<uint8_t> IsEvent;
    std::vector<uint8_t> IsParameter;
    std::vector<uint8_t> DontCountHits;
    std::vector<uint8_t> WithHash;
    std::vector<uint8_t> HasGCLID;

    // ---- other SMALLINT columns (int16_t) ----
    std::vector<int16_t> OS;
    std::vector<int16_t> UserAgent;
    std::vector<int16_t> RefererCategoryID;
    std::vector<int16_t> URLCategoryID;
    std::vector<int16_t> ResolutionWidth;
    std::vector<int16_t> ResolutionHeight;
    std::vector<int16_t> ResolutionDepth;
    std::vector<int16_t> FlashMajor;
    std::vector<int16_t> FlashMinor;
    std::vector<int16_t> NetMajor;
    std::vector<int16_t> NetMinor;
    std::vector<int16_t> UserAgentMajor;
    std::vector<int16_t> MobilePhone;
    std::vector<int16_t> TraficSourceID;
    std::vector<int16_t> SearchEngineID;
    std::vector<int16_t> AdvEngineID;
    std::vector<int16_t> WindowClientWidth;
    std::vector<int16_t> WindowClientHeight;
    std::vector<int16_t> ClientTimeZone;
    std::vector<int16_t> SilverlightVersion1;
    std::vector<int16_t> SilverlightVersion2;
    std::vector<int16_t> SilverlightVersion4;
    std::vector<int16_t> Age;
    std::vector<int16_t> Sex;
    std::vector<int16_t> Income;
    std::vector<int16_t> Interests;
    std::vector<int16_t> Robotness;
    std::vector<int16_t> HistoryLength;
    std::vector<int16_t> HTTPError;
    std::vector<int16_t> SocialSourceNetworkID;
    std::vector<int16_t> ParamCurrencyID;

    // ---- date / timestamps ----
    std::vector<uint16_t> EventDate;      // days since 1970-01-01
    std::vector<int64_t> EventTime;       // microseconds since epoch
    std::vector<int64_t> ClientEventTime; // microseconds since epoch
    std::vector<int64_t> LocalEventTime;  // microseconds since epoch

    // ---- strings: arenas (high cardinality / long) ----
    StringArena URL;
    StringArena Title;
    StringArena Referer;
    StringArena OriginalURL;
    StringArena SocialSourcePage;
    // Per-kChunkRows-chunk flag: 1 when every byte of the chunk's strings is ASCII (< 0x80).
    std::vector<uint8_t> URL_ascii;
    std::vector<uint8_t> Title_ascii;
    std::vector<uint8_t> Referer_ascii;

    // ---- strings: dictionaries (id 0 = empty string, ids in byte order) ----
    DictColumn<uint32_t> SearchPhrase;
    DictColumn<uint16_t> MobilePhoneModel;
    DictColumn<uint16_t> FlashMinor2;
    DictColumn<uint16_t> UserAgentMinor;
    DictColumn<uint16_t> PageCharset;
    DictColumn<uint16_t> HitColor;
    DictColumn<uint16_t> BrowserLanguage;
    DictColumn<uint16_t> BrowserCountry;
    DictColumn<uint16_t> SocialNetwork;
    DictColumn<uint16_t> SocialAction;
    DictColumn<uint16_t> ParamCurrency;
    DictColumn<uint32_t> Params;
    DictColumn<uint32_t> ParamOrderID;
    DictColumn<uint32_t> OpenstatServiceName;
    DictColumn<uint32_t> OpenstatCampaignID;
    DictColumn<uint32_t> OpenstatAdID;
    DictColumn<uint32_t> OpenstatSourceID;
    DictColumn<uint32_t> UTMSource;
    DictColumn<uint32_t> UTMMedium;
    DictColumn<uint32_t> UTMCampaign;
    DictColumn<uint32_t> UTMContent;
    DictColumn<uint32_t> UTMTerm;
    DictColumn<uint32_t> FromTag;

    // ---- zone maps (chunk skipping only) ----
    ZoneMap<int32_t> zone_CounterID;
    ZoneMap<uint16_t> zone_EventDate;
    ZoneMap<int16_t> zone_AdvEngineID;
    ZoneMap<int16_t> zone_SearchEngineID;
    ZoneMap<int16_t> zone_TraficSourceID;
    ZoneMap<uint8_t> zone_IsRefresh;
    ZoneMap<uint8_t> zone_DontCountHits;
    ZoneMap<uint8_t> zone_IsLink;
    ZoneMap<uint8_t> zone_IsDownload;

    // ---- column statistics (whole-column min / max; metadata only) ----
    int32_t CounterID_min = 0, CounterID_max = 0;
    int32_t RegionID_min = 0, RegionID_max = 0;
};


Database* build(ParquetTables*);
void destroy_database(Database*);
