// Bounded top-N tracker. The vast majority of ClickBench queries are
// "ORDER BY x DESC LIMIT 10" / "LIMIT 25" — i.e. we only ever need the K
// largest entries. Keeping a heap of size K instead of sorting all N rows
// turns an O(N log N) sort into O(N log K). For K=10 and N=100M that's
// ~30M comparisons vs 2.7B for a full sort.
//
// The heap stores fully-formed entries (key + extra payload). On overflow,
// we compare against the current min (heap root) and replace+sift down if
// the candidate beats it.

#pragma once

#include <algorithm>
#include <cstdint>
#include <functional>
#include <vector>

namespace gendb {

// Generic min-heap top-K: keeps the K largest values according to Less.
// Insert with try_push; finalize with sort_desc.
template <typename T, typename Less = std::less<T>>
struct TopK {
    std::vector<T> heap;
    size_t K;
    Less less;

    explicit TopK(size_t k, Less l = Less()) : K(k), less(l) { heap.reserve(k); }

    void try_push(T v) {
        if (heap.size() < K) {
            heap.push_back(std::move(v));
            std::push_heap(heap.begin(), heap.end(), less);
        } else if (less(heap.front(), v)) {
            std::pop_heap(heap.begin(), heap.end(), less);
            heap.back() = std::move(v);
            std::push_heap(heap.begin(), heap.end(), less);
        }
    }

    // Returns entries in descending order.
    std::vector<T> sorted_desc() {
        std::vector<T> out(heap);
        std::sort(out.begin(), out.end(), [this](const T& a, const T& b) {
            return less(b, a);  // reverse for descending
        });
        return out;
    }
};

}  // namespace gendb
