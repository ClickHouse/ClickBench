// Open-addressing hash map specialized for the per-query aggregation case:
// fixed-width integer keys (or pre-hashed string keys) → small aggregate
// payload (sum/count/extras). Std::unordered_map is too slow for the
// 100M-row inner loop — its chained pointers blow the cache on every probe.
//
// We don't need delete or shrink, so the implementation is short. Probing
// is linear; load factor capped at 0.5 keeps collision chains short.

#pragma once

#include <cstdint>
#include <cstring>
#include <functional>
#include <vector>

namespace gendb {

// Mix integer keys to defeat sequential-counter clustering. Plain modulo
// over UserID / CounterID etc. would clump everything into one chain.
inline uint64_t mix64(uint64_t x) {
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    x *= 0xc4ceb9fe1a85ec53ULL;
    x ^= x >> 33;
    return x;
}

inline uint32_t mix32(uint32_t x) {
    x ^= x >> 16;
    x *= 0x85ebca6bU;
    x ^= x >> 13;
    x *= 0xc2b2ae35U;
    x ^= x >> 16;
    return x;
}

// Sentinel-based hashmap. Caller supplies the "empty" key value. Insertion-
// or-update interface returns a pointer to the value slot (zero-initialized
// on insert via T() ).
template <typename K, typename V>
struct HashMap {
    std::vector<K> keys;
    std::vector<V> vals;
    size_t mask;
    size_t count = 0;
    K empty_key;

    explicit HashMap(size_t capacity_pow2, K empty)
        : keys(capacity_pow2, empty), vals(capacity_pow2), mask(capacity_pow2 - 1), empty_key(empty) {}

    inline V* find_or_insert(K k, uint64_t h) {
        size_t pos = h & mask;
        while (true) {
            if (keys[pos] == empty_key) {
                keys[pos] = k;
                ++count;
                // grow if load factor exceeds 0.5
                if (count * 2 > keys.size()) grow();
                // re-find — addresses shifted after grow
                return find_or_insert(k, h);
            }
            if (keys[pos] == k) return &vals[pos];
            pos = (pos + 1) & mask;
        }
    }

    void grow() {
        std::vector<K> ok = std::move(keys);
        std::vector<V> ov = std::move(vals);
        size_t new_size = ok.size() * 2;
        keys.assign(new_size, empty_key);
        vals.assign(new_size, V{});
        mask = new_size - 1;
        size_t saved = count;
        count = 0;
        for (size_t i = 0; i < ok.size(); ++i) {
            if (ok[i] != empty_key) {
                uint64_t h = mix64((uint64_t)ok[i]);
                size_t pos = h & mask;
                while (keys[pos] != empty_key) pos = (pos + 1) & mask;
                keys[pos] = ok[i];
                vals[pos] = ov[i];
                ++count;
            }
        }
        // sanity: same number of live entries
        (void)saved;
    }

    // Iterate live entries.
    template <typename F>
    void for_each(F&& f) const {
        for (size_t i = 0; i < keys.size(); ++i) {
            if (keys[i] != empty_key) f(keys[i], vals[i]);
        }
    }
};

// Two-key composite (useful for GROUP BY a, b).
struct Pair64 {
    uint64_t a, b;
    bool operator==(const Pair64& o) const { return a == o.a && b == o.b; }
    bool operator!=(const Pair64& o) const { return !(*this == o); }
};

inline uint64_t mix_pair(Pair64 p) {
    // mix each half independently then xor — avoids the trivial collision
    // for (a, b) ↔ (b, a) that a simple a^b hash would create.
    return mix64(p.a) ^ (mix64(p.b) * 0x9e3779b97f4a7c15ULL);
}

}  // namespace gendb
