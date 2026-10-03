#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <time.h>
#include <unistd.h>

/* Silicium Native C-ABI Engine Prototypes (Zero-Include Inlining) */
void* silicium_clickbench_init(void);
bool silicium_clickbench_load(void* ptr, const char* path);
char* silicium_clickbench_run_query(void* ptr, const char* sql);
void silicium_clickbench_free_string(char* s);
void silicium_clickbench_free(void* ptr);

static double get_time_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

int main(int argc, char** argv) {
    const char* arena_path = getenv("SILICIUM_ARENA");
    if (!arena_path || arena_path[0] == '\0') {
        arena_path = "silicium_arena";
    }

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--arena") == 0 && i + 1 < argc) {
            arena_path = argv[++i];
        }
    }

    char query[65536];
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

    void* ctx = silicium_clickbench_init();
    if (!ctx) {
        fprintf(stderr, "Error: Failed to initialize Silicium context\n");
        return 1;
    }

    if (!silicium_clickbench_load(ctx, arena_path)) {
        fprintf(stderr, "Error: Failed to open Silicium arena at '%s'\n", arena_path);
        silicium_clickbench_free(ctx);
        return 1;
    }

    double t0 = get_time_sec();
    char* res = silicium_clickbench_run_query(ctx, query);
    double elapsed_sec = get_time_sec() - t0;

    if (!res) {
        fprintf(stderr, "Error: Failed executing query: %s\n", query);
        silicium_clickbench_free(ctx);
        return 1;
    }

    fputs(res, stdout);

    silicium_clickbench_free_string(res);
    silicium_clickbench_free(ctx);

    // ClickBench official driver contract: last numeric line on stderr must be fractional seconds
    fprintf(stderr, "%.6f\n", elapsed_sec);
    return 0;
}

