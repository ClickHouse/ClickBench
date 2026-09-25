#ifndef FLORIA_CLICKBENCH_H
#define FLORIA_CLICKBENCH_H

/*
 * CORTEX C-ABI Native High-Performance Analytics Engine
 * Patent Basis: CIPO CA 3,322,620 | License: FCSL-1.0 / MIT
 * Invariant: Zero-Copy Memory-Mapped IO & Flat Forward Star
 */

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>

void* cortex_clickbench_arena_init(void);
double cortex_clickbench_arena_step(void* ptr, double val);
bool cortex_clickbench_arena_load(void* ptr, const char* path);
char* cortex_clickbench_arena_run_query(void* ptr, const char* sql);
void cortex_clickbench_arena_free_string(char* s);
void cortex_clickbench_arena_free(void* ptr);

#ifdef __cplusplus
}
#endif

#endif /* FLORIA_CLICKBENCH_H */
