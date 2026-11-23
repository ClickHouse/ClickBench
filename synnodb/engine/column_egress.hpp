#pragma once
// column_egress.hpp - build exact Arrow result columns from typed C++ values.
//
// The symmetric counterpart to column_ingest.hpp, and total in the same way. Where ingest
// CASTS any source Arrow column to one canonical C++ type, egress BUILDS one canonical Arrow
// array per value family from the engine's exact accumulators and then CASTS that to the
// column's exact DuckDB/Arrow type - with no float and no string round-trip. A DECIMAL column
// is built as arrow::decimal(p, s) directly from the exact unscaled __int128 (the int128 IS
// the unscaled decimal value), so a routed result is bit-identical to DuckDB's DECIMAL; only
// genuinely floating columns (AVG, DOUBLE) use double_column.
//
// Completeness by delegation, not enumeration (docs/CAUGHT_ERRORS_IN_GENERATION.md): the cast
// to the exact output type goes through arrow::compute::Cast, which already covers 100% of the
// Arrow type matrix (signed integers, unsigned integers through uint64, float32,
// decimal128/decimal256, date32/64, timestamp units, ...). There is no per-type switch to keep in sync with the next workload:
// build the one canonical array for the family, then cast. A cast Arrow cannot do - or a value
// that does not fit the target - THROWS, exactly the guarantee ingest gives on the way in; it
// never silently emits a wrong column.
//
// NULLs are first class. Every builder accepts a Validity mask (Arrow's valid_bytes
// convention: valid[i]==0 marks row i NULL). A genuine NULL result - a LEFT JOIN miss,
// MIN/MAX/AVG over an empty or all-null group, NULLIF, a NULL literal - is emitted as a real
// Arrow null, never substituted with 0 / "" / the epoch.
//
//   using namespace synnodb::egress;
//   auto table = make_table({
//       {"l_returnflag", string_column(flags)},                  // VARCHAR
//       {"o_custkey",    integer_column(keys, {}, arrow::int32())}, // INTEGER from narrow/signed values
//       {"ubig",         uint64_column(ubig_vals)},               // UBIGINT
//       {"sum_qty",      decimal_column(sum_qty, 38, 2)},         // DECIMAL(38,2), exact int128
//       {"huge_count",   hugeint_column(huge_vals)},              // HUGEINT as decimal128(38,0)
//       {"wide_sum",     decimal_column(wide_sum, 50, 2)},        // DECIMAL(50,2) -> decimal256
//       {"avg_price",    double_column(avg_price)},               // DOUBLE
//       {"is_open",      bool_column(open_flags)},                // BOOLEAN
//       {"o_orderts",    timestamp_column(micros)},               // TIMESTAMP
//       {"count_order",  int64_column(counts)},                   // BIGINT
//       {"o_comment",    string_column(comments, valid)},         // VARCHAR with NULLs (valid[i]==0)
//   });
//
// The resulting table is written with cpp_helpers/shm_arrow_writer.hpp::WriteArrowTableToShm
// and read back zero-copy by the runtime.
//
// Tests: tests/test_column_egress.py / tests/cpp/column_egress_test.cpp
// (nulls, decimal256, narrowed int, float32, timestamp, boolean, loud failure on a bad cast).

#include <cstddef>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#include <arrow/api.h>
#include <arrow/compute/api.h>

namespace synnodb {
namespace egress {

using Column = std::pair<std::string, std::shared_ptr<arrow::Array>>;

// Per-row validity, Arrow's valid_bytes convention: valid[i]==0 marks row i NULL, any nonzero
// marks it present. An empty mask means every row is present (the common, non-nullable case).
using Validity = std::vector<uint8_t>;

inline void check(const arrow::Status& st, const char* what) {
    if (!st.ok()) throw std::runtime_error(std::string("column_egress: ") + what + ": " + st.ToString());
}

// A validity mask, if given, must line up with the values; a length mismatch is a caller bug
// and fails loudly rather than emitting a misaligned (silently wrong) null bitmap.
inline void check_validity(std::size_t n, const Validity& valid, const char* what) {
    if (!valid.empty() && valid.size() != n) {
        throw std::runtime_error(std::string("column_egress: ") + what + ": validity size " +
                                 std::to_string(valid.size()) + " != values size " + std::to_string(n));
    }
}

// The one cast primitive (mirror of ingest::canonicalize). Identity when already the target
// type; otherwise a safe Cast that THROWS on an impossible cast or an overflowing value.
inline std::shared_ptr<arrow::Array> cast_to(const std::shared_ptr<arrow::Array>& arr,
                                             const std::shared_ptr<arrow::DataType>& target) {
    if (arr->type()->Equals(*target)) return arr;
    auto result = arrow::compute::Cast(arrow::Datum(arr), target, arrow::compute::CastOptions::Safe());
    if (!result.ok()) {
        throw std::runtime_error("column_egress: cannot cast column of type " + arr->type()->ToString() +
                                 " -> " + target->ToString() + ": " + result.status().ToString());
    }
    return result->make_array();
}

namespace detail {

template <typename Builder>
inline std::shared_ptr<arrow::Array> finish(Builder& b, const char* what) {
    std::shared_ptr<arrow::Array> out;
    check(b.Finish(&out), what);
    return out;
}

// Bulk-append a contiguous primitive column with an optional null mask. Covers the numeric and
// temporal builders (Int64/Double/Date32/Timestamp), which share the value-pointer overload.
template <typename Builder, typename T>
inline void append_primitive(Builder& b, const std::vector<T>& values, const Validity& valid,
                             const char* what) {
    check(b.AppendValues(values.data(), static_cast<int64_t>(values.size()),
                         valid.empty() ? nullptr : valid.data()),
          what);
}

inline bool is_null(const Validity& valid, std::size_t i) {
    return !valid.empty() && valid[i] == 0;
}

// 10^p as __int128. Defined for 0 <= p <= 38 (10^38 < INT128_MAX); callers only need it there.
inline __int128 pow10_i128(int p) {
    __int128 r = 1;
    for (int i = 0; i < p; ++i) r *= 10;
    return r;
}

// |v| as an unsigned __int128, correct even for INT128_MIN (whose negation would overflow).
inline unsigned __int128 abs_u128(__int128 v) {
    return v < 0 ? (~static_cast<unsigned __int128>(v) + 1) : static_cast<unsigned __int128>(v);
}

inline std::string i128_to_string(__int128 v) {
    if (v == 0) return "0";
    const bool neg = v < 0;
    unsigned __int128 u = abs_u128(v);
    std::string s;
    while (u > 0) { s.insert(s.begin(), static_cast<char>('0' + static_cast<int>(u % 10))); u /= 10; }
    if (neg) s.insert(s.begin(), '-');
    return s;
}

}  // namespace detail

// ---- int64: BIGINT canonical, cast to any narrower/other integer target (INTEGER, SMALLINT,
//      TINYINT, unsigned, ...). A value that does not fit `target` throws. -------------------
inline std::shared_ptr<arrow::Array> int64_column(const std::vector<int64_t>& values,
                                                  const Validity& valid = {},
                                                  std::shared_ptr<arrow::DataType> target = nullptr) {
    check_validity(values.size(), valid, "int64");
    arrow::Int64Builder b;
    detail::append_primitive(b, values, valid, "int64 append");
    auto arr = detail::finish(b, "int64 finish");
    return target ? cast_to(arr, target) : arr;
}

// ---- uint64: UBIGINT canonical, cast to any narrower unsigned/signed integer target when safe.
//      Required for values above INT64_MAX; do not route UBIGINT through int64_column. ----------
inline std::shared_ptr<arrow::Array> uint64_column(const std::vector<uint64_t>& values,
                                                   const Validity& valid = {},
                                                   std::shared_ptr<arrow::DataType> target = nullptr) {
    check_validity(values.size(), valid, "uint64");
    arrow::UInt64Builder b;
    detail::append_primitive(b, values, valid, "uint64 append");
    auto arr = detail::finish(b, "uint64 finish");
    return target ? cast_to(arr, target) : arr;
}

// ---- integer<T>: accept the narrow C++ integer vector produced by the query/storage plan,
//      then build the canonical signed/unsigned Arrow family and safe-cast to the exact output
//      type. This keeps generated code from widening every result vector by hand. -------------
template <typename T>
inline std::shared_ptr<arrow::Array> integer_column(const std::vector<T>& values,
                                                    const Validity& valid = {},
                                                    std::shared_ptr<arrow::DataType> target = nullptr) {
    static_assert(std::is_integral_v<T> && !std::is_same_v<T, bool>,
                  "column_egress::integer_column<T> requires a non-bool integer T");
    if constexpr (std::is_signed_v<T>) {
        std::vector<int64_t> widened;
        widened.reserve(values.size());
        for (T v : values) widened.push_back(static_cast<int64_t>(v));
        return int64_column(widened, valid, target);
    } else {
        std::vector<uint64_t> widened;
        widened.reserve(values.size());
        for (T v : values) widened.push_back(static_cast<uint64_t>(v));
        return uint64_column(widened, valid, target);
    }
}

// ---- double: DOUBLE canonical, cast to float32 (REAL) or any other float target. -----------
inline std::shared_ptr<arrow::Array> double_column(const std::vector<double>& values,
                                                   const Validity& valid = {},
                                                   std::shared_ptr<arrow::DataType> target = nullptr) {
    check_validity(values.size(), valid, "double");
    arrow::DoubleBuilder b;
    detail::append_primitive(b, values, valid, "double append");
    auto arr = detail::finish(b, "double finish");
    return target ? cast_to(arr, target) : arr;
}

// ---- bool: BOOLEAN, built exactly (no int round-trip). ------------------------------------
inline std::shared_ptr<arrow::Array> bool_column(const std::vector<bool>& values,
                                                 const Validity& valid = {},
                                                 std::shared_ptr<arrow::DataType> target = nullptr) {
    check_validity(values.size(), valid, "bool");
    arrow::BooleanBuilder b;
    check(b.Reserve(static_cast<int64_t>(values.size())), "bool reserve");
    for (std::size_t i = 0; i < values.size(); ++i) {
        if (detail::is_null(valid, i)) { check(b.AppendNull(), "bool append null"); continue; }
        check(b.Append(static_cast<bool>(values[i])), "bool append");
    }
    auto arr = detail::finish(b, "bool finish");
    return target ? cast_to(arr, target) : arr;
}

// ---- string: VARCHAR (utf8) canonical, cast to large_utf8 or any other string target. -----
inline std::shared_ptr<arrow::Array> string_column(const std::vector<std::string>& values,
                                                   const Validity& valid = {},
                                                   std::shared_ptr<arrow::DataType> target = nullptr) {
    check_validity(values.size(), valid, "string");
    arrow::StringBuilder b;
    check(b.AppendValues(values, valid.empty() ? nullptr : valid.data()), "string append");
    auto arr = detail::finish(b, "string finish");
    return target ? cast_to(arr, target) : arr;
}

// ---- DECIMAL(precision, scale) built EXACTLY from the unscaled __int128 accumulator. No
//      double: the int128 is split into the (high, low) words the decimal stores, so the value
//      is reproduced bit for bit. precision <= 38 yields decimal128; precision > 38 yields
//      decimal256, still straight from the int128 (sign-extended into the high words). --------
inline std::shared_ptr<arrow::Array> decimal_column(const std::vector<__int128>& values,
                                                    int precision, int scale,
                                                    const Validity& valid = {}) {
    check_validity(values.size(), valid, "decimal");
    if (precision <= 38) {
        // The Decimal128 builder does not enforce the declared precision, so an accumulator that
        // overflowed DECIMAL(precision) would be emitted as an out-of-range value (the one egress
        // builder that bypasses Cast's range check). Guard it: |value| must be < 10^precision.
        const unsigned __int128 bound = static_cast<unsigned __int128>(detail::pow10_i128(precision));
        arrow::Decimal128Builder b(arrow::decimal128(precision, scale));
        check(b.Reserve(static_cast<int64_t>(values.size())), "decimal reserve");
        for (std::size_t i = 0; i < values.size(); ++i) {
            if (detail::is_null(valid, i)) { check(b.AppendNull(), "decimal append null"); continue; }
            const __int128 v = values[i];
            if (detail::abs_u128(v) >= bound) {
                throw std::runtime_error(
                    "column_egress: decimal value " + detail::i128_to_string(v) +
                    " does not fit DECIMAL(" + std::to_string(precision) + "," +
                    std::to_string(scale) + ") - the accumulator overflowed the column's precision");
            }
            check(b.Append(arrow::Decimal128(static_cast<int64_t>(v >> 64), static_cast<uint64_t>(v))),
                  "decimal append");
        }
        return detail::finish(b, "decimal finish");
    }
    arrow::Decimal256Builder b(arrow::decimal256(precision, scale));
    check(b.Reserve(static_cast<int64_t>(values.size())), "decimal256 reserve");
    for (std::size_t i = 0; i < values.size(); ++i) {
        if (detail::is_null(valid, i)) { check(b.AppendNull(), "decimal256 append null"); continue; }
        const __int128 v = values[i];
        const arrow::Decimal128 lo(static_cast<int64_t>(v >> 64), static_cast<uint64_t>(v));
        check(b.Append(arrow::Decimal256(arrow::BasicDecimal256(lo))), "decimal256 append");
    }
    return detail::finish(b, "decimal256 finish");
}

// DuckDB exports HUGEINT through Arrow as decimal128(38,0). Treat it as an exact integer
// family, not as floating point or string formatting.
inline std::shared_ptr<arrow::Array> hugeint_column(const std::vector<__int128>& values,
                                                    const Validity& valid = {}) {
    return decimal_column(values, 38, 0, valid);
}

// ---- DATE built from int32 days since 1970-01-01 (matches DuckDB's DATE / Arrow date32).
//      Cast to date64 or a timestamp target when the output column is wider. ----------------
inline std::shared_ptr<arrow::Array> date_column(const std::vector<int32_t>& days,
                                                 const Validity& valid = {},
                                                 std::shared_ptr<arrow::DataType> target = nullptr) {
    check_validity(days.size(), valid, "date");
    arrow::Date32Builder b;
    detail::append_primitive(b, days, valid, "date append");
    auto arr = detail::finish(b, "date finish");
    return target ? cast_to(arr, target) : arr;
}

// ---- TIMESTAMP built from int64 since 1970-01-01 in `unit` (matches DuckDB's TIMESTAMP /
//      Arrow timestamp). DuckDB's default TIMESTAMP is microseconds. Cast to a different unit
//      or to DATE via `target`. ------------------------------------------------------------
inline std::shared_ptr<arrow::Array> timestamp_column(const std::vector<int64_t>& values,
                                                      arrow::TimeUnit::type unit = arrow::TimeUnit::MICRO,
                                                      const Validity& valid = {},
                                                      std::shared_ptr<arrow::DataType> target = nullptr) {
    check_validity(values.size(), valid, "timestamp");
    arrow::TimestampBuilder b(arrow::timestamp(unit), arrow::default_memory_pool());
    detail::append_primitive(b, values, valid, "timestamp append");
    auto arr = detail::finish(b, "timestamp finish");
    return target ? cast_to(arr, target) : arr;
}

inline std::shared_ptr<arrow::Table> make_table(const std::vector<Column>& columns) {
    std::vector<std::shared_ptr<arrow::Field>> fields;
    std::vector<std::shared_ptr<arrow::Array>> arrays;
    fields.reserve(columns.size());
    arrays.reserve(columns.size());
    // Every output column must have the same number of rows. arrow::Table::Make does not check
    // this, so a generation bug (filling one column's vector but not another's) would otherwise
    // build a structurally invalid table that fails confusingly downstream; fail here, at the
    // source, naming the offending column.
    int64_t nrows = -1;
    for (const auto& col : columns) {
        const int64_t len = col.second->length();
        if (nrows < 0) {
            nrows = len;
        } else if (len != nrows) {
            throw std::runtime_error(
                "column_egress: make_table column '" + col.first + "' has " + std::to_string(len) +
                " rows but the result has " + std::to_string(nrows) +
                "; every output column must have the same number of rows");
        }
        fields.push_back(arrow::field(col.first, col.second->type()));
        arrays.push_back(col.second);
    }
    return arrow::Table::Make(arrow::schema(fields), arrays);
}

}  // namespace egress
}  // namespace synnodb
