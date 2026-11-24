#pragma once

// Increment file version to invalidate cache when this file is changed. This is needed because this file is included in the generated code and changes to it should trigger regeneration of all code that includes it.
// FILE_VERSION: 2


#include "db_loader.hpp"
#include "query_api.hpp"


std::vector<QueryResult> query(Database*, const std::vector<std::string>& query_lines);
