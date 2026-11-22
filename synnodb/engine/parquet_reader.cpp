#include "parquet_reader.hpp"

// Increment file version to invalidate cache when this file is changed. This is needed because this file is included in the generated code and changes to it should trigger regeneration of all code that includes it.
// FILE_VERSION: 2


#include "loader_utils.hpp"
#include "shm_arrow_loader.hpp"
#include "shm_paths.hpp"

#include <stdio.h>
#include <unistd.h>


void destroy_parquet_tables(ParquetTables* tables) {
    delete tables;
}

ParquetTables* load(std::string path) {
    auto tables = new ParquetTables{};

    if (synnodb::shm_ingest_enabled()) {
        tables->hits = synnodb::ReadArrowTableFromShm(synnodb::shm_ingest_path_for("hits"));
    } else {
        tables->hits = ReadParquetTable(path + "hits.parquet");
    }

    return tables;
}
