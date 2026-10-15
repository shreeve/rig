// prog FILE N: N full parses of FILE with yyjson (input not modified, one
// pool allocator reused between runs, as std.json reuses its tape), timed;
// prints "<ns> <check>", check = the top-level element count summed over runs.
#define _POSIX_C_SOURCE 200809L  /* clock_gettime under -std=c11 on Linux */
#include "yyjson.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s FILE N\n", argv[0]); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "read %s\n", argv[1]); return 2; }
    fseek(f, 0, SEEK_END); long len = ftell(f); fseek(f, 0, SEEK_SET);
    char *buf = malloc(len);
    if (fread(buf, 1, len, f) != (size_t)len) { fprintf(stderr, "read %s\n", argv[1]); return 2; }
    fclose(f);
    long n = atol(argv[2]);
    size_t max = yyjson_read_max_memory_usage(len, 0);
    void *pool = malloc(max);
    yyjson_alc alc;
    yyjson_alc_pool_init(&alc, pool, max);
    unsigned long check = 0;
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    for (long i = 0; i < n; i++) {
        yyjson_read_err err;
        yyjson_doc *doc = yyjson_read_opts(buf, len, 0, &alc, &err);
        if (!doc) { fprintf(stderr, "parse error: %s at %zu\n", err.msg, err.pos); return 1; }
        yyjson_val *root = yyjson_doc_get_root(doc);
        check += (yyjson_is_arr(root) || yyjson_is_obj(root)) ? yyjson_get_len(root) : 1;
        yyjson_doc_free(doc);
    }
    clock_gettime(CLOCK_MONOTONIC, &b);
    long long ns = (b.tv_sec - a.tv_sec) * 1000000000LL + (b.tv_nsec - a.tv_nsec);
    printf("%lld %lu\n", ns, check);
    return 0;
}
