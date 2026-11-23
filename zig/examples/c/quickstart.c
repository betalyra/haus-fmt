/*
 * The quickstart in C, through haus.h: the same steps and the same output
 * as quickstart.zig (and go/examples/quickstart), on the same files.
 * Run: `zig build quickstart-c` (from zig/), or build it against the
 * installed library:
 *
 *   zig build -Doptimize=ReleaseSafe
 *   cc examples/c/quickstart.c -Izig-out/include -Lzig-out/lib -lhaus -o quickstart
 *   ./quickstart ../examples
 */
#include "haus.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define S(lit) lit, (sizeof(lit) - 1)

static const char reply[] =
    "Comment { author: \"me\", at: Instant(\"2026-11-16T09:00:00Z\"), text: \"+1\", likes: 0, replies: [] }";

/* The record of a Comment { … }, which the schema checked. */
static const haus_value *comment(const haus_value *v) { return haus_variant_arg(v, 0); }

static const haus_value *field(const haus_value *v, const char *key) {
    return haus_record_get(comment(v), key, strlen(key));
}

static int64_t likes(const haus_value *v) {
    int64_t n = 0;
    haus_number_int64(field(v, "likes"), &n, NULL);
    const haus_value *replies = field(v, "replies");
    for (size_t i = 0; i < haus_len(replies); i++) n += likes(haus_array_get(replies, i));
    return n;
}

static size_t depth(const haus_value *v) {
    size_t deepest = 0;
    const haus_value *replies = field(v, "replies");
    for (size_t i = 0; i < haus_len(replies); i++) {
        size_t d = depth(haus_array_get(replies, i));
        if (d > deepest) deepest = d;
    }
    return 1 + deepest;
}

static int fail(const char *what, const haus_error *err) {
    fprintf(stderr, "%s: %s %s (%u:%u) %s\n", what, err->code, err->message, err->line, err->column, err->path);
    return 1;
}

static char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *text = malloc((size_t)size);
    *len = fread(text, 1, (size_t)size, f);
    fclose(f);
    return text;
}

int main(int argc, char **argv) {
    const char *examples = argc > 1 ? argv[1] : "../examples";
    char path[1024];
    haus_error err;

    /* The schema file, with what it imports (std/time here). */
    haus_schema *schema = NULL;
    snprintf(path, sizeof path, "%s/thread.schema.haus", examples);
    if (haus_schema_build(path, NULL, &schema, &err) != HAUS_OK) return fail("schema", &err);
    const haus_type *root = haus_schema_type(schema, "Root");
    const haus_type *comment_type = haus_schema_type(schema, "Comment");

    /* 1. The thread, checked with its schema. */
    snprintf(path, sizeof path, "%s/thread.haus", examples);
    size_t len = 0;
    char *text = read_file(path, &len);
    if (!text) return 1;
    haus_doc *thread_doc = NULL;
    const haus_value *thread = NULL;
    if (haus_decode_text(root, text, len, &thread_doc, &thread, &err) != HAUS_OK) return fail("thread", &err);
    free(text);
    size_t author_len = 0;
    const char *author = haus_string(field(thread, "author"), &author_len);
    printf("thread by %.*s: %zu levels, %" PRId64 " likes\n", (int)author_len, author, depth(thread), likes(thread));
    haus_doc_free(thread_doc);

    /* 2. Decode haus text with the schema, change it, encode it back. */
    haus_doc *decoded_doc = NULL;
    const haus_value *decoded = NULL;
    if (haus_decode_text(comment_type, S(reply), &decoded_doc, &decoded, &err) != HAUS_OK) return fail("reply", &err);
    const haus_value *rec = comment(decoded);
    haus_doc *built = haus_doc_new();
    haus_field fields[8];
    size_t n = haus_len(rec);
    for (size_t i = 0; i < n && i < 8; i++) {
        fields[i].key = haus_record_key(rec, i, &fields[i].key_len);
        fields[i].value = haus_record_value(rec, i);
        if (fields[i].key_len == 5 && memcmp(fields[i].key, "likes", 5) == 0) {
            int64_t count = 0;
            haus_number_int64(fields[i].value, &count, NULL);
            char digits[32];
            int d = snprintf(digits, sizeof digits, "%" PRId64, count + 1);
            haus_new_number(built, digits, (size_t)d, &fields[i].value, &err);
        }
    }
    const haus_value *liked_rec = NULL, *liked = NULL;
    haus_new_record(built, fields, n, &liked_rec, &err);
    haus_new_variant(built, S("Comment"), &liked_rec, 1, &liked, &err);
    haus_doc *encoded_doc = NULL;
    const haus_value *encoded = NULL;
    if (haus_encode(comment_type, liked, &encoded_doc, &encoded, &err) != HAUS_OK) return fail("encode", &err);
    char *out = NULL;
    size_t out_len = 0;
    if (haus_stringify(encoded, HAUS_COMPACT, 2, 80, &out, &out_len, &err) != HAUS_OK) return fail("stringify", &err);
    printf("%.*s\n", (int)out_len, out);
    haus_free(out, out_len);
    /* encoded shares parts of liked, which shares parts of decoded: free in that order. */
    haus_doc_free(encoded_doc);
    haus_doc_free(built);
    haus_doc_free(decoded_doc);

    /* 3. A value that doesn't match the schema is an error that says where. */
    static const char lots[] =
        "Comment { author: \"me\", at: Instant(\"2026-11-16T09:00:00Z\"), text: \"+1\", likes: \"lots\", replies: [] }";
    haus_doc *bad = NULL;
    const haus_value *ignored = NULL;
    if (haus_decode_text(comment_type, S(lots), &bad, &ignored, &err) == HAUS_ERROR) {
        printf("error: %s: %s [%s]\n", err.path, err.message, err.code);
    } else {
        haus_doc_free(bad);
    }

    haus_schema_free(schema);
    return 0;
}
