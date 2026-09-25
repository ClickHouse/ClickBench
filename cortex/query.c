#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <time.h>
#include <unistd.h>
#include "include/floria_clickbench.h"

static double get_time_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

int main(int argc, char** argv) {
    const char* arena_path = getenv("CORTEX_ARENA");
    if (!arena_path || arena_path[0] == '\0') {
        arena_path = "cortex_arena";
    }

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--arena") == 0 && i + 1 < argc) {
            arena_path = argv[++i];
        }
    }

    char query[8192];
    size_t total_len = 0;
    while (fgets(query + total_len, sizeof(query) - total_len, stdin)) {
        total_len = strlen(query);
    }

    while (total_len > 0 && (query[total_len - 1] == '\n' || query[total_len - 1] == '\r')) {
        query[--total_len] = '\0';
    }

    if (total_len == 0) {
        fprintf(stderr, "Error: Empty SQL query received on stdin\n");
        return 1;
    }

    void* ctx = cortex_clickbench_arena_init();
    if (!ctx) {
        fprintf(stderr, "Error: Failed to initialize CORTEX context\n");
        return 1;
    }

    if (!cortex_clickbench_arena_load(ctx, arena_path)) {
        fprintf(stderr, "Error: Failed to open CORTEX arena at '%s'\n", arena_path);
        cortex_clickbench_arena_free(ctx);
        return 1;
    }

    double t0 = get_time_sec();
    char* res = cortex_clickbench_arena_run_query(ctx, query);
    double elapsed_sec = get_time_sec() - t0;

    if (!res) {
        fprintf(stderr, "Error: Failed executing query: %s\n", query);
        cortex_clickbench_arena_free(ctx);
        return 1;
    }

    fputs(res, stdout);

    cortex_clickbench_arena_free_string(res);
    cortex_clickbench_arena_free(ctx);

    // ClickBench official driver contract: last numeric line on stderr must be fractional seconds
    fprintf(stderr, "%.6f\n", elapsed_sec);
    return 0;
}
