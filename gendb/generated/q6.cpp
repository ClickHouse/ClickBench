// Q6: SELECT COUNT(DISTINCT SearchPhrase) FROM hits;
//
// SearchPhrase is a variable-length string column. Strategy mirrors q5 (the
// int64 COUNT(DISTINCT) pattern) but the key is a byte range instead of a
// scalar, so the hashset stores (hash, offset, len) entries and falls back
// to memcmp on collision against the underlying _data buffer (same pattern
// as q13's StrMap, minus the per-key count payload).
//
// Empty strings count as one distinct value (Q6 counts ALL distinct values,
// including the empty string), so the inner loop does NOT skip empty rows.
//
// Per-thread sets are built in parallel and merged serially at the end. The
// answer is the merged set's live count — we never need to materialize the
// strings, just the count of distinct insertions.

#include "../utils/storage.h"
#include "../utils/timing.h"
#include "../utils/hashmap.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <omp.h>
#include <string>
#include <vector>

// FNV-1a for short byte strings — matches q13's choice. The cost of the
// inner loop is dominated by L3 misses on the hashset probe, not the hash
// arithmetic, so a stronger hash isn't worth it.
static inline uint64_t hash_bytes(const char* p, size_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; ++i) {
        h ^= (uint8_t)p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

// Open-addressing hashset keyed on a byte range. Entry stores the precomputed
// hash, the offset into the _data buffer, and the length. Equality on probe
// is memcmp against the data base. We never delete, so a simple linear probe
// at load factor <= 0.5 keeps chains short.
struct StrEntry {
    uint64_t hash;
    uint64_t off;   // offset into the SearchPhrase _data buffer
    uint32_t len;
};

struct StrSet {
    static constexpr size_t INIT_CAP = 1 << 14;
    std::vector<int32_t> slots;   // -1 = empty, else index into entries
    std::vector<StrEntry> entries;
    size_t mask;
    size_t live = 0;

    StrSet() : slots(INIT_CAP, -1), entries(), mask(INIT_CAP - 1) {
        entries.reserve(1024);
    }

    void maybe_grow() {
        if (live * 2 <= slots.size()) return;
        size_t newcap = slots.size() * 2;
        std::vector<int32_t> ns(newcap, -1);
        size_t nm = newcap - 1;
        for (size_t i = 0; i < entries.size(); ++i) {
            uint64_t h = entries[i].hash;
            size_t pos = h & nm;
            while (ns[pos] != -1) pos = (pos + 1) & nm;
            ns[pos] = (int32_t)i;
        }
        slots = std::move(ns);
        mask = nm;
    }

    // Insert (h, [p..p+n)) if absent. data_base is the SearchPhrase _data
    // pointer used to resolve previously stored entries during memcmp.
    inline void insert(uint64_t h, const char* p, size_t n,
                       const char* data_base, uint64_t row_off) {
        size_t pos = h & mask;
        while (true) {
            int32_t idx = slots[pos];
            if (idx == -1) {
                StrEntry e;
                e.hash = h;
                e.off  = row_off;
                e.len  = (uint32_t)n;
                entries.push_back(e);
                slots[pos] = (int32_t)(entries.size() - 1);
                ++live;
                maybe_grow();
                return;
            }
            const StrEntry& e = entries[idx];
            if (e.hash == h && e.len == n &&
                memcmp(data_base + e.off, p, n) == 0) {
                return;  // already present
            }
            pos = (pos + 1) & mask;
        }
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: q6 <gendb_dir>\n"); return 1; }
    gendb::WallClock _wc;
    std::string dir = argv[1];

    auto sp = gendb::mmap_strcol(dir, "SearchPhrase");

    int T = omp_get_max_threads();
    std::vector<StrSet> sets(T);

    #pragma omp parallel
    {
        int tid = omp_get_thread_num();
        StrSet& s = sets[tid];
        #pragma omp for schedule(static)
        for (int64_t i = 0; i < sp.n; ++i) {
            uint64_t a = sp.off[i], b = sp.off[i + 1];
            const char* p = sp.data + a;
            size_t n = (size_t)(b - a);
            // Note: empty string (n == 0) is *not* skipped — it counts as
            // one distinct value per Q6 semantics.
            uint64_t h = hash_bytes(p, n);
            s.insert(h, p, n, sp.data, a);
        }
    }

    // Merge per-thread sets into one. We re-insert each entry using its
    // recorded (hash, off, len) — the byte content lives in the immutable
    // mmap, so any offset that was distinct in any thread still resolves to
    // the same bytes for the merge memcmp.
    StrSet merged;
    for (auto& s : sets) {
        for (auto& e : s.entries) {
            merged.insert(e.hash, sp.data + e.off, e.len, sp.data, e.off);
        }
    }

    std::printf("ndv\n%zu\n", merged.live);
    return 0;
}
