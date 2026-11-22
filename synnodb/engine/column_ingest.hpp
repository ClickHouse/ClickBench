#pragma once
// column_ingest.hpp - read Arrow columns into typed C++ vectors.
//
// Background (docs/CAUGHT_ERRORS_IN_GENERATION.md, G2): decoding Arrow buffers by hand is
// easy to get wrong. A hand-written DECIMAL128 FromBigEndian decode read every value
// column as zero (count was right, the sums were all zero), and a switch over Arrow types
// keeps missing the case the next workload happens to use (TIMESTAMP, DICTIONARY, BOOLEAN,
// DECIMAL256, ...).
//
// Each helper here casts the column to a single canonical Arrow type with
// arrow::compute::Cast and then reads only that type. Cast already covers the full set of
// Arrow types, so there is no per-type switch to maintain; a cast it cannot do (or a value
// that overflows the target) throws instead of returning a wrong number.
//
// This does NOT mean every in-memory column should be int64_t. The storage plan should still
// choose the narrowest correct C++ representation for the hot query path, then call the matching
// helper here. For example, use as_integer<uint8_t>(...) for a tiny status/code domain and
// scaled_integer<int32_t>(..., scale) for a fixed-point decimal whose scaled values fit int32_t.
//
// NULLs. By default a null reads as the type's zero (0 / 0.0 / "" / epoch) - correct for a
// NOT NULL column and for SUM over a nullable one (adding zero == skipping). For a query whose
// result depends on SQL null semantics (COUNT(col), AVG, NULL-propagating arithmetic, a
// predicate on a nullable column, IS NULL), pass an optional ``Validity* valid_out``: it is
// filled with Arrow's valid_bytes (valid[i]==0 marks row i NULL), the symmetric counterpart to
// column_egress.hpp's Validity, so the engine can carry nulls through and re-emit them exactly.
//
// db_loader.cpp build() calls these and does not touch Arrow itself:
//   using namespace synnodb::ingest;
//   db->l_quantity      = scaled_integer<int16_t>(*tables->lineitem, "l_quantity", 2);
//   db->l_orderkey      = as_integer<int32_t>    (*tables->lineitem, "l_orderkey");
//   db->l_returnflag    = as_string   (*tables->lineitem, "l_returnflag");
//   db->l_shipdate_days = as_date_days(*tables->lineitem, "l_shipdate");
//   // nullable column: capture validity to honour SQL null semantics
//   Validity disc_valid;
//   db->o_discount      = as_double   (*tables->orders, "o_discount", &disc_valid);
//
// Tests: tests/test_column_ingest.py (TPC-H parquet vs DuckDB),
// tests/cpp/column_ingest_test.cpp (decimal/bool/dictionary/timestamp/nullable).

#include <cstdint>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

#include <arrow/api.h>
#include <arrow/compute/api.h>

namespace synnodb {
namespace ingest {

// Per-row validity, Arrow's valid_bytes convention: valid[i]==0 marks row i NULL. The same type
// and convention as synnodb::egress::Validity, so a mask read on the way in can be carried
// straight back out. An optional ``Validity*`` out-parameter on each reader fills it; passing
// nullptr (the default) keeps the historical null-reads-as-zero behaviour.
using Validity = std::vector<uint8_t>;

namespace detail {
inline void init_validity(Validity* valid_out, int64_t n) {
    if (valid_out) { valid_out->clear(); valid_out->reserve(static_cast<size_t>(n)); }
}
inline void push_validity(Validity* valid_out, bool is_null) {
    if (valid_out) valid_out->push_back(is_null ? 0 : 1);
}

template <typename T>
inline std::shared_ptr<arrow::DataType> arrow_integer_type() {
    static_assert(std::is_integral_v<T> && !std::is_same_v<T, bool>,
                  "column_ingest::as_integer<T> requires a non-bool integer T");
    if constexpr (std::is_same_v<T, int8_t>) return arrow::int8();
    else if constexpr (std::is_same_v<T, int16_t>) return arrow::int16();
    else if constexpr (std::is_same_v<T, int32_t>) return arrow::int32();
    else if constexpr (std::is_same_v<T, int64_t>) return arrow::int64();
    else if constexpr (std::is_same_v<T, uint8_t>) return arrow::uint8();
    else if constexpr (std::is_same_v<T, uint16_t>) return arrow::uint16();
    else if constexpr (std::is_same_v<T, uint32_t>) return arrow::uint32();
    else if constexpr (std::is_same_v<T, uint64_t>) return arrow::uint64();
    else static_assert(sizeof(T) == 0, "unsupported integer width");
}

template <typename T>
inline T decimal_to_checked_integer(const arrow::Decimal128& d, int scale) {
    static_assert(std::is_integral_v<T> && !std::is_same_v<T, bool>,
                  "column_ingest::scaled_integer<T> requires a non-bool integer T");
    const __int128 value =
        static_cast<__int128>(d.high_bits()) * (static_cast<__int128>(1) << 64) +
        static_cast<__int128>(d.low_bits());

    bool fits = false;
    if constexpr (std::is_signed_v<T>) {
        fits = value >= static_cast<__int128>(std::numeric_limits<T>::min()) &&
               value <= static_cast<__int128>(std::numeric_limits<T>::max());
    } else {
        fits = value >= 0 &&
               static_cast<unsigned __int128>(value) <=
                   static_cast<unsigned __int128>(std::numeric_limits<T>::max());
    }
    if (!fits) {
        throw std::runtime_error(
            "column_ingest::scaled_integer: value does not fit requested C++ integer type at scale=" +
            std::to_string(scale));
    }
    return static_cast<T>(value);
}
}  // namespace detail

inline std::shared_ptr<arrow::ChunkedArray> column(const arrow::Table& t, const std::string& name) {
    const int idx = t.schema()->GetFieldIndex(name);
    if (idx < 0) throw std::runtime_error("column_ingest: column not found: " + name);
    return t.column(idx);
}

// Cast a column to `target`. Throws if Arrow cannot perform the cast.
inline std::shared_ptr<arrow::ChunkedArray> canonicalize(
    const std::shared_ptr<arrow::ChunkedArray>& col, std::shared_ptr<arrow::DataType> target) {
    if (col->type()->Equals(*target)) return col;
    auto result = arrow::compute::Cast(arrow::Datum(col), std::move(target), arrow::compute::CastOptions::Safe());
    if (!result.ok()) {
        throw std::runtime_error("column_ingest: cannot canonicalize column of type " +
                                 col->type()->ToString() + ": " + result.status().ToString());
    }
    return result->chunked_array();
}

// ---- as_integer<T>: any integer/bool/date source -> the storage-plan C++ integer T ----------
// Use this for persisted in-memory columns. It keeps Arrow's safe cast/range-checking while
// allowing the Database layout to be as narrow as the workload permits (uint8_t codes, int32_t
// keys, uint64_t ids, ...). A cast that cannot be done, or a value outside T's range, throws.
template <typename T>
inline std::vector<T> as_integer(const std::shared_ptr<arrow::ChunkedArray>& col,
                                 Validity* valid_out = nullptr) {
    static_assert(std::is_integral_v<T> && !std::is_same_v<T, bool>,
                  "column_ingest::as_integer<T> requires a non-bool integer T");
    auto c = canonicalize(col, detail::arrow_integer_type<T>());
    std::vector<T> out;
    out.reserve(static_cast<size_t>(c->length()));
    detail::init_validity(valid_out, c->length());
    for (const auto& chunk : c->chunks()) {
        const auto read_chunk = [&](const auto& a) {
            for (int64_t i = 0; i < a.length(); ++i) {
                const bool null = a.IsNull(i);
                detail::push_validity(valid_out, null);
                out.push_back(null ? T{} : static_cast<T>(a.Value(i)));
            }
        };
        if constexpr (std::is_same_v<T, int8_t>) read_chunk(static_cast<const arrow::Int8Array&>(*chunk));
        else if constexpr (std::is_same_v<T, int16_t>) read_chunk(static_cast<const arrow::Int16Array&>(*chunk));
        else if constexpr (std::is_same_v<T, int32_t>) read_chunk(static_cast<const arrow::Int32Array&>(*chunk));
        else if constexpr (std::is_same_v<T, int64_t>) read_chunk(static_cast<const arrow::Int64Array&>(*chunk));
        else if constexpr (std::is_same_v<T, uint8_t>) read_chunk(static_cast<const arrow::UInt8Array&>(*chunk));
        else if constexpr (std::is_same_v<T, uint16_t>) read_chunk(static_cast<const arrow::UInt16Array&>(*chunk));
        else if constexpr (std::is_same_v<T, uint32_t>) read_chunk(static_cast<const arrow::UInt32Array&>(*chunk));
        else if constexpr (std::is_same_v<T, uint64_t>) read_chunk(static_cast<const arrow::UInt64Array&>(*chunk));
    }
    return out;
}
template <typename T>
inline std::vector<T> as_integer(const arrow::Table& t, const std::string& name,
                                 Validity* valid_out = nullptr) {
    return as_integer<T>(column(t, name), valid_out);
}

// Backward-compatible name for existing generated code. New code should prefer as_integer<T>
// with the storage plan's narrowest correct T.
inline std::vector<int64_t> as_int64(const std::shared_ptr<arrow::ChunkedArray>& col,
                                     Validity* valid_out = nullptr) {
    return as_integer<int64_t>(col, valid_out);
}
inline std::vector<int64_t> as_int64(const arrow::Table& t, const std::string& name,
                                     Validity* valid_out = nullptr) {
    return as_integer<int64_t>(column(t, name), valid_out);
}

// ---- as_double: any numeric/decimal source -> double -------------------------
inline std::vector<double> as_double(const std::shared_ptr<arrow::ChunkedArray>& col,
                                     Validity* valid_out = nullptr) {
    auto c = canonicalize(col, arrow::float64());
    std::vector<double> out;
    out.reserve(static_cast<size_t>(c->length()));
    detail::init_validity(valid_out, c->length());
    for (const auto& chunk : c->chunks()) {
        const auto& a = static_cast<const arrow::DoubleArray&>(*chunk);
        for (int64_t i = 0; i < a.length(); ++i) {
            const bool null = a.IsNull(i);
            detail::push_validity(valid_out, null);
            out.push_back(null ? 0.0 : a.Value(i));
        }
    }
    return out;
}
inline std::vector<double> as_double(const arrow::Table& t, const std::string& name,
                                     Validity* valid_out = nullptr) {
    return as_double(column(t, name), valid_out);
}

// ---- scaled_integer<T>: numeric/decimal source -> fixed-point integer T (value*10^scale) ----
// Read each value's unscaled integer at the requested scale. A value that does not fit T at
// this scale throws rather than truncating. This lets the storage plan keep decimal/money/
// quantity columns narrow when their scaled value domain allows it.
//
// Fast path: a decimal128 source ALREADY at `scale` is read in place - its unscaled integer is
// already value*10^scale, so casting it to decimal128(38,scale) would only copy 16 bytes/row
// (~1.9 GB per TPC-H lineitem column at SF20) without changing a single value. Skipping that cast
// makes the helper as cheap as a hand-rolled raw read, so there is no performance reason to decode
// Arrow by hand (and lose the overflow check, null handling, and type-universality below). Any
// other source (different scale, integer, float, decimal256) still goes through Cast so the helper
// stays universal and exact.
template <typename T>
inline std::vector<T> scaled_integer(const std::shared_ptr<arrow::ChunkedArray>& col, int scale,
                                     Validity* valid_out = nullptr) {
    static_assert(std::is_integral_v<T> && !std::is_same_v<T, bool>,
                  "column_ingest::scaled_integer<T> requires a non-bool integer T");
    std::shared_ptr<arrow::ChunkedArray> c;
    if (col->type()->id() == arrow::Type::DECIMAL128 &&
        static_cast<const arrow::Decimal128Type&>(*col->type()).scale() == scale) {
        c = col;  // native scale: no widening Cast, read the unscaled integer directly
    } else {
        c = canonicalize(col, arrow::decimal128(38, scale));
    }
    std::vector<T> out;
    out.reserve(static_cast<size_t>(c->length()));
    detail::init_validity(valid_out, c->length());
    for (const auto& chunk : c->chunks()) {
        const auto& a = static_cast<const arrow::Decimal128Array&>(*chunk);
        for (int64_t i = 0; i < a.length(); ++i) {
            if (a.IsNull(i)) { detail::push_validity(valid_out, true); out.push_back(T{}); continue; }
            detail::push_validity(valid_out, false);
            const arrow::Decimal128 d(a.GetValue(i));   // native little-endian; the unscaled value
            out.push_back(detail::decimal_to_checked_integer<T>(d, scale));
        }
    }
    return out;
}
template <typename T>
inline std::vector<T> scaled_integer(const arrow::Table& t, const std::string& name, int scale,
                                     Validity* valid_out = nullptr) {
    return scaled_integer<T>(column(t, name), scale, valid_out);
}

// Backward-compatible name for existing generated code. New code should prefer
// scaled_integer<T> with the storage plan's narrowest correct T.
inline std::vector<int64_t> scaled_int64(const std::shared_ptr<arrow::ChunkedArray>& col, int scale,
                                         Validity* valid_out = nullptr) {
    return scaled_integer<int64_t>(col, scale, valid_out);
}
inline std::vector<int64_t> scaled_int64(const arrow::Table& t, const std::string& name, int scale,
                                         Validity* valid_out = nullptr) {
    return scaled_integer<int64_t>(column(t, name), scale, valid_out);
}

// ---- as_string: any string/dictionary/etc. source -> std::string -------------
inline std::vector<std::string> as_string(const std::shared_ptr<arrow::ChunkedArray>& col,
                                          Validity* valid_out = nullptr) {
    auto c = canonicalize(col, arrow::utf8());
    std::vector<std::string> out;
    out.reserve(static_cast<size_t>(c->length()));
    detail::init_validity(valid_out, c->length());
    for (const auto& chunk : c->chunks()) {
        const auto& a = static_cast<const arrow::StringArray&>(*chunk);
        for (int64_t i = 0; i < a.length(); ++i) {
            const bool null = a.IsNull(i);
            detail::push_validity(valid_out, null);
            out.emplace_back(null ? std::string() : a.GetString(i));
        }
    }
    return out;
}
inline std::vector<std::string> as_string(const arrow::Table& t, const std::string& name,
                                          Validity* valid_out = nullptr) {
    return as_string(column(t, name), valid_out);
}

// ---- as_date_days: any date/timestamp source -> int32 days since 1970-01-01 ---
inline std::vector<int32_t> as_date_days(const std::shared_ptr<arrow::ChunkedArray>& col,
                                         Validity* valid_out = nullptr) {
    auto c = canonicalize(col, arrow::date32());
    std::vector<int32_t> out;
    out.reserve(static_cast<size_t>(c->length()));
    detail::init_validity(valid_out, c->length());
    for (const auto& chunk : c->chunks()) {
        const auto& a = static_cast<const arrow::Date32Array&>(*chunk);
        for (int64_t i = 0; i < a.length(); ++i) {
            const bool null = a.IsNull(i);
            detail::push_validity(valid_out, null);
            out.push_back(null ? 0 : a.Value(i));
        }
    }
    return out;
}
inline std::vector<int32_t> as_date_days(const arrow::Table& t, const std::string& name,
                                         Validity* valid_out = nullptr) {
    return as_date_days(column(t, name), valid_out);
}

// ---- as_timestamp_micros: any timestamp/date source -> int64 microseconds since epoch -----
// Casts the column to timestamp[us] (Arrow safe cast: a unit conversion that would lose
// precision, or an overflow, throws) and reads the int64 values.
inline std::vector<int64_t> as_timestamp_micros(const std::shared_ptr<arrow::ChunkedArray>& col,
                                                Validity* valid_out = nullptr) {
    auto c = canonicalize(col, arrow::timestamp(arrow::TimeUnit::MICRO));
    std::vector<int64_t> out;
    out.reserve(static_cast<size_t>(c->length()));
    detail::init_validity(valid_out, c->length());
    for (const auto& chunk : c->chunks()) {
        const auto& a = static_cast<const arrow::TimestampArray&>(*chunk);
        for (int64_t i = 0; i < a.length(); ++i) {
            const bool null = a.IsNull(i);
            detail::push_validity(valid_out, null);
            out.push_back(null ? 0 : a.Value(i));
        }
    }
    return out;
}
inline std::vector<int64_t> as_timestamp_micros(const arrow::Table& t, const std::string& name,
                                                Validity* valid_out = nullptr) {
    return as_timestamp_micros(column(t, name), valid_out);
}

}  // namespace ingest
}  // namespace synnodb
