// Shared storage / mmap helpers used by every generated per-query binary.
// Each query binary mmaps the columns it needs (read-only, MAP_PRIVATE)
// from <gendb_dir>/hits/<col>.bin. String columns are two files:
//   <col>_off.bin   uint64 array, length = num_rows + 1
//   <col>_data.bin  concatenated UTF-8 bytes
// String value for row i is data[off[i] .. off[i+1]).
//
// We deliberately keep this header dependency-free (no <vector>, no
// <iostream>) so per-query binaries compile and link in well under a second.

#pragma once

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace gendb {

// Total row count in the ClickBench hits table.
static constexpr int64_t HITS_ROWS = 99997497;

struct MMap {
    const void* base = nullptr;
    size_t bytes = 0;
};

inline MMap mmap_file(const std::string& path) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        std::fprintf(stderr, "open failed: %s: %s\n", path.c_str(), std::strerror(errno));
        std::exit(2);
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        std::fprintf(stderr, "fstat failed: %s\n", path.c_str());
        std::exit(2);
    }
    void* p = mmap(nullptr, st.st_size, PROT_READ, MAP_PRIVATE | MAP_POPULATE, fd, 0);
    close(fd);
    if (p == MAP_FAILED) {
        std::fprintf(stderr, "mmap failed: %s: %s\n", path.c_str(), std::strerror(errno));
        std::exit(2);
    }
    // Sequential + populate gives us cold-read throughput close to raw disk;
    // hugepage advice reduces TLB pressure on the 8 GB+ columns.
    madvise(p, st.st_size, MADV_SEQUENTIAL);
    madvise(p, st.st_size, MADV_HUGEPAGE);
    return {p, (size_t)st.st_size};
}

template <typename T>
inline const T* mmap_col(const std::string& gendb_dir, const std::string& col) {
    return reinterpret_cast<const T*>(
        mmap_file(gendb_dir + "/hits/" + col + ".bin").base);
}

struct StrCol {
    const uint64_t* off;   // length n+1
    const char*     data;  // length off[n]
    int64_t         n;
};

inline StrCol mmap_strcol(const std::string& gendb_dir, const std::string& col) {
    auto off_m = mmap_file(gendb_dir + "/hits/" + col + "_off.bin");
    auto dat_m = mmap_file(gendb_dir + "/hits/" + col + "_data.bin");
    int64_t n = (int64_t)(off_m.bytes / sizeof(uint64_t)) - 1;
    return {reinterpret_cast<const uint64_t*>(off_m.base),
            reinterpret_cast<const char*>(dat_m.base),
            n};
}

// memmem-style substring search restricted to the bytes [data[off[i]],
// data[off[i+1]]). Returns true if pattern occurs anywhere in the row.
inline bool str_contains(const StrCol& s, int64_t row, const char* pat, size_t plen) {
    const char* p = s.data + s.off[row];
    size_t len = (size_t)(s.off[row + 1] - s.off[row]);
    if (plen == 0) return true;
    if (len < plen) return false;
    return memmem(p, len, pat, plen) != nullptr;
}

inline bool str_eq_lit(const StrCol& s, int64_t row, const char* lit, size_t llen) {
    size_t len = (size_t)(s.off[row + 1] - s.off[row]);
    if (len != llen) return false;
    return memcmp(s.data + s.off[row], lit, llen) == 0;
}

inline bool str_nonempty(const StrCol& s, int64_t row) {
    return s.off[row + 1] != s.off[row];
}

inline size_t str_len(const StrCol& s, int64_t row) {
    return (size_t)(s.off[row + 1] - s.off[row]);
}

inline std::string str_get(const StrCol& s, int64_t row) {
    return std::string(s.data + s.off[row],
                       (size_t)(s.off[row + 1] - s.off[row]));
}

}  // namespace gendb
