#pragma once

#include <memory>

#include <arrow/table.h>

#include "args_parser.hpp"
#include "db_loader.hpp"

// Returns the query result as an exact Arrow table built with cpp_helpers/column_egress.hpp:
// DECIMAL columns are built from the unscaled __int128 accumulators (no double), so the result
// is bit-identical to DuckDB. Only genuinely floating columns (AVG / DOUBLE) use double_column.
std::shared_ptr<arrow::Table> run_q9(Database* db, const Q9Args& args);
