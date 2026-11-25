/*
 * The C ABI (include/haus.h), tested from C: every function, every status
 * and the error paths, with ownership as a C program uses it. Run by
 * `zig build test` (the arguments are the paths of ../extensions,
 * ../examples and this directory, for the schema builds).
 */
#include "haus.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
static int checks = 0;

#define CHECK(cond)                                                       \
    do {                                                                  \
        checks++;                                                         \
        if (!(cond)) {                                                    \
            failures++;                                                   \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                 \
    } while (0)

#define S(lit) lit, (sizeof(lit) - 1)

static int eq(const char *p, size_t len, const char *want) {
    return p != NULL && len == strlen(want) && memcmp(p, want, len) == 0;
}

static int code_is(const haus_error *err, const char *code) {
    return strcmp(err->code, code) == 0;
}

/* The canonical form of a value, compared and freed. */
static int canonical_is(const haus_value *v, const char *want) {
    char *out = NULL;
    size_t len = 0;
    haus_error err;
    if (haus_value_canonical(v, &out, &len, &err) != HAUS_OK) return 0;
    int ok = eq(out, len, want);
    haus_free(out, len);
    return ok;
}

static void test_text_functions(void) {
    haus_error err;
    char *out = NULL;
    size_t len = 0;
    CHECK(haus_canonical(S("{ b: 1, a: 0x10 }"), &out, &len, &err) == HAUS_OK);
    CHECK(eq(out, len, "{a:16,b:1}\n"));
    haus_free(out, len);
    CHECK(haus_canonical(S("[1 2]"), &out, &len, &err) == HAUS_ERROR);
    CHECK(code_is(&err, "missing-comma") && err.line == 1 && err.column == 4);
    CHECK(haus_canonical(NULL, 3, &out, &len, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_canonical(S("1"), NULL, &len, &err) == HAUS_INVALID_ARGUMENT);

    char hash[65];
    CHECK(haus_hash_all(NULL, 0, hash, &err) == HAUS_OK);
    CHECK(strcmp(hash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") == 0);
    CHECK(haus_hash_all(S("\"\xff\""), hash, &err) == HAUS_ERROR && code_is(&err, "invalid-utf8") && err.line == 0);
    CHECK(haus_hash_all(S("1"), NULL, &err) == HAUS_INVALID_ARGUMENT);

    CHECK(haus_format(S("{a:1}"), HAUS_COMPACT, 2, 80, &out, &len, &err) == HAUS_OK);
    CHECK(eq(out, len, "{ a: 1 }\n"));
    haus_free(out, len);
    CHECK(haus_format(S("{a:1}"), 9, 2, 80, &out, &len, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_format(S("{a:1}"), HAUS_PRETTY, 2, -1, &out, &len, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_format(S("{a:"), HAUS_PRETTY, 2, 80, &out, &len, &err) == HAUS_ERROR);
    CHECK(strcmp(haus_spec_version(), "0.1") == 0);
    /* A NULL error is allowed. */
    CHECK(haus_canonical(S("[1 2]"), &out, &len, NULL) == HAUS_ERROR);
    haus_free(NULL, 0);
}

static void test_parse_and_read(void) {
    haus_error err;
    haus_doc *doc = NULL;
    const haus_value *v = NULL;
    size_t len = 0;
    CHECK(haus_parse(S("Order { id: 0xFF, total: 19.90, note: \"a\\u{0}b\", raw: x\"0aff\", lines: [1, -0, 1e400], s: Shipped }"),
                     &doc, &v, &err) == HAUS_OK);
    CHECK(haus_kind(v) == HAUS_VARIANT);
    CHECK(eq(haus_variant_tag(v, &len), len, "Order"));
    CHECK(haus_len(v) == 1);
    const haus_value *rec = haus_variant_arg(v, 0);
    CHECK(haus_variant_arg(v, 1) == NULL);
    CHECK(haus_kind(rec) == HAUS_RECORD && haus_len(rec) == 6);
    CHECK(eq(haus_record_key(rec, 0, &len), len, "id"));
    CHECK(haus_record_key(rec, 6, &len) == NULL && haus_record_value(rec, 6) == NULL);
    const haus_value *id = haus_record_value(rec, 0);
    CHECK(eq(haus_number(id, &len), len, "255"));
    CHECK(haus_record_get(rec, S("nope")) == NULL);
    CHECK(haus_record_get(v, S("id")) == NULL);
    const haus_value *total = haus_record_get(rec, S("total"));
    CHECK(eq(haus_number(total, &len), len, "19.90"));
    CHECK(haus_string(total, &len) == NULL);
    const haus_value *note = haus_record_get(rec, S("note"));
    CHECK(haus_kind(note) == HAUS_STRING);
    const char *s = haus_string(note, &len);
    CHECK(len == 3 && s[0] == 'a' && s[1] == 0 && s[2] == 'b');
    const uint8_t *raw = haus_bytes(haus_record_get(rec, S("raw")), &len);
    CHECK(len == 2 && raw[0] == 0x0a && raw[1] == 0xff);
    CHECK(haus_bytes(note, &len) == NULL);
    const haus_value *lines = haus_record_get(rec, S("lines"));
    CHECK(haus_kind(lines) == HAUS_ARRAY && haus_len(lines) == 3);
    CHECK(haus_array_get(lines, 3) == NULL && haus_array_get(rec, 0) == NULL);
    CHECK(haus_variant_tag(lines, &len) == NULL);
    CHECK(haus_number(haus_array_get(lines, 0), NULL) != NULL); /* len may be NULL */
    CHECK(haus_kind(NULL) == 0 && haus_len(NULL) == 0 && haus_number(NULL, &len) == NULL);

    int64_t i64 = 0;
    double dbl = 0;
    CHECK(haus_number_int64(id, &i64, &err) == HAUS_OK && i64 == 255);
    CHECK(haus_number_int64(haus_array_get(lines, 1), &i64, &err) == HAUS_OK && i64 == 0);
    CHECK(haus_number_int64(total, &i64, &err) == HAUS_ERROR && code_is(&err, "not-an-integer"));
    CHECK(haus_number_int64(note, &i64, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_number_double(total, &dbl, &err) == HAUS_OK && fabs(dbl - 19.9) < 1e-12);
    CHECK(haus_number_double(haus_array_get(lines, 2), &dbl, &err) == HAUS_ERROR && code_is(&err, "out-of-range"));
    CHECK(haus_number_double(note, &dbl, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_number_double(id, NULL, &err) == HAUS_INVALID_ARGUMENT);
    haus_doc_free(doc);

    haus_doc *big = NULL;
    const haus_value *huge = NULL;
    CHECK(haus_parse(S("99999999999999999999"), &big, &huge, &err) == HAUS_OK);
    CHECK(haus_number_int64(huge, &i64, &err) == HAUS_ERROR && code_is(&err, "out-of-range"));
    haus_doc_free(big);

    /* One value: none or several is not-one-value, at the end. */
    doc = NULL;
    CHECK(haus_parse(S("1, 2"), &doc, &v, &err) == HAUS_ERROR && code_is(&err, "not-one-value"));
    CHECK(err.line == 1 && err.column == 5 && doc == NULL);
    CHECK(haus_parse(S(""), &doc, &v, &err) == HAUS_ERROR && code_is(&err, "not-one-value"));
    CHECK(haus_parse(S("1,"), &doc, &v, &err) == HAUS_OK);
    haus_doc_free(doc);
    CHECK(haus_parse(S("{"), &doc, &v, &err) == HAUS_ERROR && code_is(&err, "unclosed-bracket"));
    CHECK(haus_parse(S("1"), NULL, &v, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_parse(S("\xc3"), &doc, &v, &err) == HAUS_ERROR && code_is(&err, "invalid-utf8"));

    /* A file. */
    CHECK(haus_parse_all(S("1, \"a\", [],"), &doc, &err) == HAUS_OK);
    CHECK(haus_doc_count(doc) == 3 && haus_doc_value(doc, 3) == NULL);
    CHECK(haus_kind(haus_doc_value(doc, 1)) == HAUS_STRING);
    char *out = NULL;
    CHECK(haus_stringify_doc(doc, HAUS_MINIMISED, 0, 0, &out, &len, &err) == HAUS_OK);
    CHECK(eq(out, len, "1,\n\"a\",\n[],\n"));
    haus_free(out, len);
    CHECK(haus_stringify_doc(NULL, HAUS_MINIMISED, 0, 0, &out, &len, &err) == HAUS_INVALID_ARGUMENT);
    haus_doc_free(doc);
    CHECK(haus_parse_all(S("1 2"), &doc, &err) == HAUS_ERROR && code_is(&err, "missing-comma"));
    CHECK(haus_parse_all(S("1"), NULL, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_doc_count(NULL) == 0 && haus_doc_value(NULL, 0) == NULL);
    haus_doc_free(NULL);
}

static void test_build_and_write(void) {
    haus_error err;
    haus_doc *doc = haus_doc_new();
    CHECK(doc != NULL);
    const haus_value *n = NULL, *s = NULL, *b = NULL, *arr = NULL, *rec = NULL, *var = NULL;
    CHECK(haus_new_number(doc, S("1E+05"), &n, &err) == HAUS_OK);
    CHECK(canonical_is(n, "1e5"));
    CHECK(haus_new_number(doc, S("0xFF"), &n, &err) == HAUS_OK && canonical_is(n, "255"));
    CHECK(haus_new_number(doc, S("01"), &n, &err) == HAUS_ERROR && code_is(&err, "invalid-number"));
    CHECK(haus_new_number(doc, S(""), &n, &err) == HAUS_ERROR && code_is(&err, "invalid-number"));
    CHECK(haus_new_number(doc, S("1 "), &n, &err) == HAUS_ERROR && code_is(&err, "invalid-number"));
    CHECK(haus_new_number(doc, S("NaN"), &n, &err) == HAUS_ERROR && code_is(&err, "invalid-number"));
    /* A number longer than the writers' limit is still a number. */
    char long_number[1200];
    memset(long_number, '7', sizeof long_number);
    const haus_value *too_long = NULL;
    CHECK(haus_new_number(doc, long_number, sizeof long_number, &too_long, &err) == HAUS_OK);
    char *out = NULL;
    size_t len = 0;
    CHECK(haus_stringify(too_long, HAUS_COMPACT, 2, 80, &out, &len, &err) == HAUS_ERROR && code_is(&err, "number-too-long"));
    CHECK(haus_new_number(NULL, S("1"), &n, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_new_number(doc, S("1"), NULL, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_new_number(doc, S("42"), &n, &err) == HAUS_OK);

    CHECK(haus_new_string(doc, S("héllo"), &s, &err) == HAUS_OK);
    CHECK(haus_new_string(doc, S("\xff"), &s, &err) == HAUS_ERROR && code_is(&err, "cannot-encode"));
    CHECK(haus_new_string(doc, S("ok"), &s, &err) == HAUS_OK);
    const uint8_t raw[] = {0, 1, 0xfe};
    CHECK(haus_new_bytes(doc, raw, 3, &b, &err) == HAUS_OK);
    CHECK(haus_new_bytes(doc, NULL, 2, &b, &err) == HAUS_INVALID_ARGUMENT);

    const haus_value *xs[] = {n, s, b};
    CHECK(haus_new_array(doc, xs, 3, &arr, &err) == HAUS_OK);
    CHECK(canonical_is(arr, "[42,\"ok\",x\"0001fe\"]"));
    const haus_value *with_null[] = {n, NULL};
    CHECK(haus_new_array(doc, with_null, 2, &arr, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_new_array(doc, NULL, 1, &arr, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_new_array(doc, NULL, 0, &arr, &err) == HAUS_OK && canonical_is(arr, "[]"));
    CHECK(haus_new_array(doc, xs, 3, &arr, &err) == HAUS_OK);

    haus_field fields[] = {{S("b"), n}, {S("a-b"), arr}};
    CHECK(haus_new_record(doc, fields, 2, &rec, &err) == HAUS_OK);
    CHECK(canonical_is(rec, "{\"a-b\":[42,\"ok\",x\"0001fe\"],b:42}"));
    haus_field twice[] = {{S("a"), n}, {S("a"), s}};
    CHECK(haus_new_record(doc, twice, 2, &rec, &err) == HAUS_ERROR && code_is(&err, "duplicate-key"));
    haus_field bad_key[] = {{S("\xff"), n}};
    CHECK(haus_new_record(doc, bad_key, 1, &rec, &err) == HAUS_ERROR && code_is(&err, "cannot-encode"));
    haus_field no_value[] = {{S("a"), NULL}};
    CHECK(haus_new_record(doc, no_value, 1, &rec, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_new_record(doc, fields, 2, &rec, &err) == HAUS_OK);

    const haus_value *payload[] = {rec};
    CHECK(haus_new_variant(doc, S("Point"), payload, 1, &var, &err) == HAUS_OK);
    CHECK(canonical_is(var, "Point{\"a-b\":[42,\"ok\",x\"0001fe\"],b:42}"));
    CHECK(haus_new_variant(doc, S("lower"), NULL, 0, &var, &err) == HAUS_ERROR && code_is(&err, "invalid-tag"));
    CHECK(haus_new_variant(doc, S(""), NULL, 0, &var, &err) == HAUS_ERROR && code_is(&err, "invalid-tag"));
    CHECK(haus_new_variant(doc, S("None"), NULL, 0, &var, &err) == HAUS_OK && canonical_is(var, "None"));
    CHECK(haus_new_variant(doc, S("Point"), payload, 1, &var, &err) == HAUS_OK);

    CHECK(haus_stringify(var, HAUS_PRETTY, 2, 80, &out, &len, &err) == HAUS_OK);
    CHECK(eq(out, len, "Point {\n  b: 42,\n  \"a-b\": [\n    42,\n    \"ok\",\n    x\"0001fe\",\n  ],\n}"));
    haus_free(out, len);
    CHECK(haus_stringify(var, HAUS_COMPACT, 2, 80, &out, &len, &err) == HAUS_OK);
    CHECK(eq(out, len, "Point { b: 42, \"a-b\": [42, \"ok\", x\"0001fe\"] }"));
    haus_free(out, len);
    CHECK(haus_stringify(var, 5, 2, 80, &out, &len, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_stringify(NULL, HAUS_PRETTY, 2, 80, &out, &len, &err) == HAUS_INVALID_ARGUMENT);

    /* Nesting deeper than the writers' depth limit (spec §7); canonical takes any depth. */
    const haus_value *deep = n;
    for (int i = 0; i < 300; i++) {
        const haus_value *one[] = {deep};
        CHECK(haus_new_array(doc, one, 1, &deep, &err) == HAUS_OK);
    }
    CHECK(haus_stringify(deep, HAUS_MINIMISED, 0, 0, &out, &len, &err) == HAUS_ERROR && code_is(&err, "nesting-too-deep"));
    char hash[65];
    CHECK(haus_value_hash(deep, hash, &err) == HAUS_OK && strlen(hash) == 64);
    CHECK(haus_value_hash(NULL, hash, &err) == HAUS_INVALID_ARGUMENT);

    /* Equality and order, against a parsed value. */
    haus_doc *parsed = NULL;
    const haus_value *p = NULL;
    CHECK(haus_parse(S("Point { \"a-b\": [42, \"ok\", x\"0001FE\"], b: 0x2A }"), &parsed, &p, &err) == HAUS_OK);
    int r = -9;
    CHECK(haus_value_equals(var, p, &r, &err) == HAUS_OK && r == 1);
    CHECK(haus_value_compare(var, p, &r, &err) == HAUS_OK && r == 0);
    CHECK(haus_value_equals(n, p, &r, &err) == HAUS_OK && r == 0);
    /* By canonical bytes: "42" after "\"ok\"". */
    CHECK(haus_value_compare(n, s, &r, &err) == HAUS_OK && r == 1);
    CHECK(haus_value_compare(s, n, &r, &err) == HAUS_OK && r == -1);
    CHECK(haus_value_equals(n, NULL, &r, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_value_compare(n, p, NULL, &err) == HAUS_INVALID_ARGUMENT);
    char h1[65], h2[65];
    CHECK(haus_value_hash(var, h1, &err) == HAUS_OK && haus_value_hash(p, h2, &err) == HAUS_OK && strcmp(h1, h2) == 0);
    CHECK(haus_value_canonical(NULL, &out, &len, &err) == HAUS_INVALID_ARGUMENT);

    /* Self-describing JSON round trip, and imported JSON. */
    CHECK(haus_to_haus_json(var, &out, &len, &err) == HAUS_OK);
    haus_doc *back = NULL;
    const haus_value *bv = NULL;
    CHECK(haus_from_haus_json(out, len, &back, &bv, &err) == HAUS_OK);
    CHECK(haus_value_equals(var, bv, &r, &err) == HAUS_OK && r == 1);
    haus_free(out, len);
    haus_doc_free(back);
    CHECK(haus_from_haus_json(S("{\"haus\": 2}"), &back, &bv, &err) == HAUS_ERROR);
    CHECK(haus_to_haus_json(NULL, &out, &len, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_import_json(S("{\"a\": 1, \"a\": 2}"), &back, &bv, &err) == HAUS_ERROR && code_is(&err, "duplicate-key"));
    CHECK(haus_import_json(S("{\"a\": [1, \"x\"]}"), &back, &bv, &err) == HAUS_OK && canonical_is(bv, "{a:[1,\"x\"]}"));
    haus_doc_free(back);
    CHECK(haus_import_json(S("{"), &back, &bv, &err) == HAUS_ERROR && code_is(&err, "json-syntax"));
    CHECK(haus_import_json(S("1"), NULL, &bv, &err) == HAUS_INVALID_ARGUMENT);

    haus_doc_free(parsed);
    haus_doc_free(doc);
}

static const char order_schema[] =
    "import std/time (Date)\n"
    "type Order = closed { id: Int, placed: Date, lines: Array Line, pin?: Secret String, @deprecated note?: String }\n"
    "type Line = { sku: String, qty: UInt8 }\n"
    "type Log = Stream Line\n"
    "type Box a = { item: a }\n"
    "@futureattr type Odd = Int\n";

static void test_schema(void) {
    haus_error err;
    haus_schema *schema = NULL;
    CHECK(haus_schema_load(order_schema, sizeof order_schema - 1, &schema, &err) == HAUS_OK);
    CHECK(haus_schema_warning_count(schema) == 1);
    haus_error w;
    CHECK(haus_schema_warning(schema, 0, &w) == HAUS_OK && code_is(&w, "unknown-attribute") && w.line == 6 && w.column == 1);
    CHECK(haus_schema_warning(schema, 1, &w) == HAUS_INVALID_ARGUMENT);
    const haus_type *order = haus_schema_type(schema, "Order");
    const haus_type *log = haus_schema_type(schema, "Log");
    CHECK(order != NULL && log != NULL);
    CHECK(haus_schema_type(schema, "Box") == NULL);  /* generic */
    CHECK(haus_schema_type(schema, "Date") == NULL); /* imported */
    CHECK(haus_schema_type(schema, "Bool") == NULL); /* the prelude's */
    CHECK(haus_schema_type(schema, "Nope") == NULL);
    CHECK(haus_schema_type(NULL, "Order") == NULL);
    size_t len = 0;
    CHECK(eq(haus_type_id(order, &len), len, "local#Order"));
    CHECK(haus_type_is_stream(log) == 1 && haus_type_is_stream(order) == 0);

    /* Decoding a text. */
    haus_doc *doc = NULL;
    const haus_value *v = NULL;
    const char ok[] = "{ id: -0, placed: Date(\"2026-11-09\"), lines: [{ sku: \"a\", qty: 2, extra: 1 }], pin: \"1234\" }";
    CHECK(haus_decode_text(order, S(ok), &doc, &v, &err) == HAUS_OK);
    /* The Secret is hidden: no accessor or writer sees it, one call reveals it. */
    const haus_value *pin = haus_record_get(v, S("pin"));
    CHECK(haus_kind(pin) == HAUS_SECRET && haus_len(pin) == 0);
    CHECK(haus_variant_tag(pin, &len) == NULL && haus_variant_arg(pin, 0) == NULL);
    CHECK(eq(haus_string(haus_secret_reveal(pin), &len), len, "1234"));
    CHECK(haus_secret_reveal(v) == NULL && haus_secret_reveal(NULL) == NULL);
    char *written = NULL;
    CHECK(haus_stringify(v, HAUS_COMPACT, 2, 80, &written, &len, &err) == HAUS_ERROR && code_is(&err, "cannot-encode"));
    CHECK(strstr(err.message, "1234") == NULL);
    CHECK(haus_value_canonical(pin, &written, &len, &err) == HAUS_ERROR && code_is(&err, "cannot-encode"));
    char digest[65];
    int equal = 0;
    CHECK(haus_value_hash(v, digest, &err) == HAUS_ERROR && code_is(&err, "cannot-encode"));
    CHECK(haus_to_haus_json(v, &written, &len, &err) == HAUS_ERROR && code_is(&err, "cannot-encode"));
    CHECK(haus_value_equals(v, v, &equal, &err) == HAUS_ERROR && code_is(&err, "cannot-encode"));    CHECK(canonical_is(haus_record_get(v, S("lines")), "[{qty:2,sku:\"a\"}]"));
    CHECK(canonical_is(haus_record_get(v, S("id")), "0"));
    haus_doc_free(doc);
    /* Encoding writes the data in full. */
    haus_doc *with_pin = NULL;
    const haus_value *wp = NULL;
    CHECK(haus_parse(S(ok), &with_pin, &wp, &err) == HAUS_OK);
    CHECK(haus_encode(order, wp, &doc, &v, &err) == HAUS_OK);
    CHECK(canonical_is(v, "{id:0,lines:[{qty:2,sku:\"a\"}],pin:\"1234\",placed:Date(\"2026-11-09\")}"));
    haus_doc_free(doc);
    haus_doc_free(with_pin);
    CHECK(haus_decode_text(order, S("{ id: 1, placed: Date(\"2026-02-30\"), lines: [] }"), &doc, &v, &err) == HAUS_ERROR);
    CHECK(code_is(&err, "invalid-time") && strcmp(err.path, "$.placed[0]") == 0);
    CHECK(haus_decode_text(order, S("{ id: 1, placed: Date(\"2026-02-03\"), lines: [], pin: 7 }"), &doc, &v, &err) == HAUS_ERROR);
    CHECK(code_is(&err, "invalid-secret") && strcmp(err.path, "$.pin") == 0);
    CHECK(haus_decode_text(order, S("1, 2"), &doc, &v, &err) == HAUS_ERROR && code_is(&err, "not-one-value"));
    CHECK(haus_decode_text(order, S("{"), &doc, &v, &err) == HAUS_ERROR && code_is(&err, "unclosed-bracket") && err.line == 1);
    CHECK(haus_decode_text(NULL, S("1"), &doc, &v, &err) == HAUS_INVALID_ARGUMENT);
    /* A stream type: an array of the items. */
    CHECK(haus_decode_text(log, S("{ sku: \"a\", qty: 1 }, { sku: \"b\", qty: 2 },"), &doc, &v, &err) == HAUS_OK);
    CHECK(haus_kind(v) == HAUS_ARRAY && haus_len(v) == 2);
    haus_doc_free(doc);
    CHECK(haus_decode_text(log, S("{ sku: \"a\", qty: 1 }, { sku: 2, qty: 2 },"), &doc, &v, &err) == HAUS_ERROR);
    CHECK(code_is(&err, "type-mismatch") && strcmp(err.path, "$[1].sku") == 0);

    /* Decoding and encoding a value. */
    haus_doc *in = NULL;
    const haus_value *iv = NULL;
    CHECK(haus_parse(S("{ id: 7, placed: Date(\"2026-11-09\"), lines: [] }"), &in, &iv, &err) == HAUS_OK);
    CHECK(haus_decode(order, iv, &doc, &v, &err) == HAUS_OK);
    CHECK(haus_value_equals(iv, v, &(int){0}, &err) == HAUS_OK);
    haus_doc_free(doc);
    CHECK(haus_decode(log, iv, &doc, &v, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_decode(order, NULL, &doc, &v, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_encode(order, iv, &doc, &v, &err) == HAUS_OK);
    CHECK(canonical_is(v, "{id:7,lines:[],placed:Date(\"2026-11-09\")}"));
    haus_doc_free(doc);
    haus_doc_free(in);

    /* Encoding a value built in code that the type doesn't accept. */
    haus_doc *b = haus_doc_new();
    const haus_value *id = NULL, *sku = NULL, *qty = NULL, *line = NULL, *lines = NULL, *date_s = NULL, *date = NULL, *o = NULL;
    haus_new_number(b, S("1"), &id, &err);
    haus_new_string(b, S("a"), &sku, &err);
    haus_new_number(b, S("300"), &qty, &err);
    haus_field lf[] = {{S("sku"), sku}, {S("qty"), qty}};
    haus_new_record(b, lf, 2, &line, &err);
    haus_new_array(b, &line, 1, &lines, &err);
    haus_new_string(b, S("2026-11-09"), &date_s, &err);
    haus_new_variant(b, S("Date"), &date_s, 1, &date, &err);
    haus_field of[] = {{S("id"), id}, {S("placed"), date}, {S("lines"), lines}};
    CHECK(haus_new_record(b, of, 3, &o, &err) == HAUS_OK);
    CHECK(haus_encode(order, o, &doc, &v, &err) == HAUS_ERROR);
    CHECK(code_is(&err, "cannot-encode") && strcmp(err.path, "$.lines[0].qty") == 0);
    CHECK(haus_encode(log, o, &doc, &v, &err) == HAUS_INVALID_ARGUMENT);

    /* Schema-based JSON. */
    char *out = NULL;
    CHECK(haus_type_to_json(order, o, &out, &len, &err) == HAUS_ERROR && code_is(&err, "out-of-range"));
    haus_doc *p = NULL;
    const haus_value *pv = NULL;
    CHECK(haus_parse(S("{ id: 1, placed: Date(\"2026-11-09\"), lines: [{ sku: \"a\", qty: 3 }] }"), &p, &pv, &err) == HAUS_OK);
    CHECK(haus_type_to_json(order, pv, &out, &len, &err) == HAUS_OK);
    CHECK(eq(out, len, "{\"id\":\"1\",\"placed\":\"2026-11-09\",\"lines\":[{\"sku\":\"a\",\"qty\":3}]}"));
    CHECK(haus_type_from_json(order, out, len, &doc, &v, &err) == HAUS_OK);
    int same = 0;
    CHECK(haus_value_equals(pv, v, &same, &err) == HAUS_OK && same == 1);
    haus_free(out, len);
    haus_doc_free(doc);
    CHECK(haus_type_from_json(order, S("{\"id\": 1}"), &doc, &v, &err) == HAUS_ERROR);
    CHECK(err.path[0] == '$');
    CHECK(haus_type_from_json(log, S("[]"), &doc, &v, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_type_to_json(log, pv, &out, &len, &err) == HAUS_INVALID_ARGUMENT);
    haus_doc_free(p);
    haus_doc_free(b);

    /* Checking: the hints and the errors. */
    haus_issues *issues = NULL;
    CHECK(haus_check_text(order, S("{ id: 1, placed: Date(\"2026-11-09\"), note: \"x\", lines: [{ sku: \"a\", qty: 1, color: 1 }, { sku: 1, qty: 1 }] }"),
                          &issues, &err) == HAUS_OK);
    CHECK(haus_issues_count(issues) == 3);
    haus_issue is;
    CHECK(haus_issues_get(issues, 0, &is) == HAUS_OK && !is.is_error && strcmp(is.code, "deprecated") == 0 && eq(is.path, is.path_len, "$.note"));
    CHECK(haus_issues_get(issues, 1, &is) == HAUS_OK && strcmp(is.code, "unlisted-field") == 0 && eq(is.path, is.path_len, "$.lines[0].color"));
    CHECK(haus_issues_get(issues, 2, &is) == HAUS_OK && is.is_error && strcmp(is.code, "type-mismatch") == 0);
    CHECK(eq(is.path, is.path_len, "$.lines[1].sku") && is.message_len > 0);
    CHECK(haus_issues_get(issues, 3, &is) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_issues_stopped(issues) == 0);
    haus_issues_free(issues);
    /* Every error; nothing inside a Secret but "invalid-secret" at it. */
    static const char many[] = "{ id: \"1\", lines: [{ sku: 1, qty: 300 }, { sku: \"b\", qty: 1 }, 2], pin: 5, zz: 1 }";
    CHECK(haus_check_text(order, S(many), &issues, &err) == HAUS_OK);
    static const char *const want[][2] = {
        {"missing-field", "$"}, {"type-mismatch", "$.id"}, {"type-mismatch", "$.lines[0].sku"},
        {"out-of-range", "$.lines[0].qty"}, {"type-mismatch", "$.lines[2]"}, {"invalid-secret", "$.pin"}, {"unknown-field", "$.zz"},
    };
    CHECK(haus_issues_count(issues) == 7);
    for (size_t i = 0; i < 7; i++) {
        CHECK(haus_issues_get(issues, i, &is) == HAUS_OK && is.is_error && strcmp(is.code, want[i][0]) == 0 && eq(is.path, is.path_len, want[i][1]));
    }
    haus_issues_free(issues);
    /* Stopping at the first error. */
    CHECK(haus_check_text_first(order, S(many), &issues, &err) == HAUS_OK);
    CHECK(haus_issues_count(issues) == 1 && haus_issues_get(issues, 0, &is) == HAUS_OK && strcmp(is.code, "missing-field") == 0);
    haus_issues_free(issues);
    /* The cap: HAUS_CHECK_MAX_ERRORS errors in one value, and it says so. */
    {
        char big[4096];
        size_t n = 0;
        n += (size_t)snprintf(big + n, sizeof big - n, "{ id: 1, placed: Date(\"2026-11-09\"), lines: [");
        for (int i = 0; i < 250; i++) n += (size_t)snprintf(big + n, sizeof big - n, "1, ");
        n += (size_t)snprintf(big + n, sizeof big - n, "] }");
        CHECK(haus_check_text(order, big, n, &issues, &err) == HAUS_OK);
        CHECK(haus_issues_count(issues) == HAUS_CHECK_MAX_ERRORS && haus_issues_stopped(issues) == 1);
        haus_issues_free(issues);
    }
    CHECK(haus_check_text(order, S("{ id: 1"), &issues, &err) == HAUS_OK);
    CHECK(haus_issues_count(issues) == 1 && haus_issues_get(issues, 0, &is) == HAUS_OK && is.line == 1 && strcmp(is.code, "unclosed-bracket") == 0);
    haus_issues_free(issues);
    CHECK(haus_check_text(NULL, S("1"), &issues, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_issues_count(NULL) == 0);

    /* Typed streams. */
    haus_stream *st = NULL;
    CHECK(haus_typed_stream_new(order, &st) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_typed_stream_new(log, &st) == HAUS_OK);
    CHECK(haus_stream_push(st, S("{ sku: \"a\", qty: 1 }, { sku: \"b\""), &doc, &err) == HAUS_OK);
    CHECK(haus_doc_count(doc) == 1 && canonical_is(haus_doc_value(doc, 0), "{qty:1,sku:\"a\"}"));
    haus_doc_free(doc);
    CHECK(haus_stream_push(st, S(", qty: 2 }, { sku: \"c\", qty: 3 }"), &doc, &err) == HAUS_OK);
    CHECK(haus_doc_count(doc) == 1);
    haus_doc_free(doc);
    CHECK(haus_stream_end(st, &doc, &err) == HAUS_OK && haus_doc_count(doc) == 1);
    haus_doc_free(doc);
    CHECK(haus_stream_push(st, S("1,"), &doc, &err) == HAUS_INVALID_ARGUMENT);
    haus_stream_free(st);
    CHECK(haus_typed_stream_new(log, &st) == HAUS_OK);
    CHECK(haus_stream_push(st, S("{ sku: \"a\", qty: 1 }, { sku: \"b\", qty: 256 },"), &doc, &err) == HAUS_ERROR);
    CHECK(code_is(&err, "out-of-range") && strcmp(err.path, "$[1].qty") == 0);
    CHECK(haus_stream_push(st, S("1,"), &doc, &err) == HAUS_INVALID_ARGUMENT);
    haus_stream_free(st);

    haus_schema_free(schema);
    haus_schema_free(NULL);

    /* Mistakes in schema files. */
    CHECK(haus_schema_load(S("type A = B"), &schema, &err) == HAUS_SCHEMA_ERROR && code_is(&err, "unknown-type"));
    CHECK(err.line == 1 && err.column == 10);
    CHECK(haus_schema_load(S("import ./other (A)\ntype B = A"), &schema, &err) == HAUS_SCHEMA_ERROR && code_is(&err, "import-unavailable"));
    CHECK(haus_schema_load(S("type A = Int"), NULL, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_schema_load(NULL, 4, &schema, &err) == HAUS_INVALID_ARGUMENT);

    /* The one-call forms. */
    CHECK(haus_check(order_schema, sizeof order_schema - 1, "Order", S("{ id: 1, placed: Date(\"2026-11-09\"), lines: [] }"), &err) == HAUS_OK);
    CHECK(haus_check(order_schema, sizeof order_schema - 1, "Box", S("1"), &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_check(order_schema, sizeof order_schema - 1, NULL, S("1"), &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_to_json(order_schema, sizeof order_schema - 1, "Log", S("1"), &out, &len, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_from_json(S("type A = Int"), "A", S("\"x\""), &out, &len, &err) == HAUS_ERROR);
}

static void test_plain_stream(void) {
    haus_error err;
    haus_stream *st = NULL;
    haus_doc *doc = NULL;
    CHECK(haus_stream_new(1, &st) == HAUS_OK);
    CHECK(haus_stream_push(st, S("1, [2"), &doc, &err) == HAUS_OK && haus_doc_count(doc) == 1);
    haus_doc_free(doc);
    CHECK(haus_stream_push(st, S("], 3"), &doc, &err) == HAUS_OK && haus_doc_count(doc) == 1);
    haus_doc_free(doc);
    /* Strict: the last value needs its comma. */
    CHECK(haus_stream_end(st, &doc, &err) == HAUS_ERROR && code_is(&err, "stream-truncated"));
    CHECK(haus_stream_end(st, &doc, &err) == HAUS_INVALID_ARGUMENT);
    haus_stream_free(st);
    CHECK(haus_stream_new(0, &st) == HAUS_OK);
    CHECK(haus_stream_push(st, S("1, 2"), &doc, &err) == HAUS_OK);
    haus_doc_free(doc);
    CHECK(haus_stream_end(st, &doc, &err) == HAUS_OK && haus_doc_count(doc) == 1);
    haus_doc_free(doc);
    haus_stream_free(st);
    CHECK(haus_stream_new(0, &st) == HAUS_OK);
    CHECK(haus_stream_push(st, S("1 2,"), &doc, &err) == HAUS_ERROR && code_is(&err, "missing-comma"));
    CHECK(haus_stream_push(st, NULL, 0, NULL, &err) == HAUS_INVALID_ARGUMENT);
    haus_stream_free(st);
    CHECK(haus_stream_new(0, NULL) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_stream_push(NULL, S("1"), &doc, &err) == HAUS_INVALID_ARGUMENT);
    haus_stream_free(NULL);
}

static void test_build(const char *extensions, const char *examples, const char *tests) {
    haus_error err;
    haus_schema *schema = NULL;
    char entry[1024];
    snprintf(entry, sizeof entry, "%s/order.schema.haus", examples);
    /* Without its packages, the import isn't found. */
    CHECK(haus_schema_build(entry, NULL, &schema, &err) == HAUS_SCHEMA_ERROR && code_is(&err, "import-not-found"));
    const char *folders[] = {extensions};
    haus_build_options options = {0};
    options.folders = folders;
    options.folders_len = 1;
    CHECK(haus_schema_build(entry, &options, &schema, &err) == HAUS_OK);
    const haus_type *root = haus_schema_type(schema, "Root");
    size_t len = 0;
    CHECK(eq(haus_type_id(root, &len), len, "./order.schema.haus#Root"));
    CHECK(haus_schema_type(schema, "Money") == NULL); /* imported */
    char data[1024];
    snprintf(data, sizeof data, "%s/order.haus", examples);
    FILE *f = fopen(data, "rb");
    CHECK(f != NULL);
    if (f) {
        char text[4096];
        size_t n = fread(text, 1, sizeof text, f);
        fclose(f);
        haus_doc *doc = NULL;
        const haus_value *v = NULL;
        CHECK(haus_decode_text(root, text, n, &doc, &v, &err) == HAUS_OK);
        const haus_value *total = haus_record_get(v, S("total"));
        CHECK(eq(haus_number(haus_variant_arg(total, 0), &len), len, "44.40"));
        haus_doc_free(doc);
    }
    haus_schema_free(schema);

    /* A package given as files in memory. */
    static const char manifest[] = "{ name: \"@acme/units\", version: \"2.1.0\" }";
    static const char units[] = "type Meters = closed < Meters Float64 >";
    haus_package_file files[] = {
        {"package.haus", (const uint8_t *)manifest, sizeof manifest - 1},
        {"schema.haus", (const uint8_t *)units, sizeof units - 1},
    };
    haus_package_tree tree = {"@acme/units (embedded)", files, 2};
    haus_build_options with_tree = {0};
    with_tree.trees = &tree;
    with_tree.trees_len = 1;
    with_tree.root = examples;
    char app[1024];
    snprintf(app, sizeof app, "%s/c_api_app.schema.haus", tests);
    /* The entry is outside the root given: import-outside-root or a schema error. */
    CHECK(haus_schema_build(app, &with_tree, &schema, &err) == HAUS_SCHEMA_ERROR);
    with_tree.root = NULL;
    CHECK(haus_schema_build(app, &with_tree, &schema, &err) == HAUS_OK);
    const haus_type *t = haus_schema_type(schema, "Run");
    haus_doc *doc = NULL;
    const haus_value *v = NULL;
    CHECK(haus_decode_text(t, S("{ distance: Meters(5) }"), &doc, &v, &err) == HAUS_OK);
    haus_doc_free(doc);
    haus_schema_free(schema);
    haus_package_tree bad = {"broken", files, 1}; /* no schema.haus */
    with_tree.trees = &bad;
    CHECK(haus_schema_build(app, &with_tree, &schema, &err) == HAUS_SCHEMA_ERROR);
    haus_package_file null_name[] = {{NULL, (const uint8_t *)manifest, 1}};
    haus_package_tree bad_arg = {"x", null_name, 1};
    with_tree.trees = &bad_arg;
    CHECK(haus_schema_build(app, &with_tree, &schema, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_schema_build(NULL, NULL, &schema, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_schema_build(app, NULL, NULL, &err) == HAUS_INVALID_ARGUMENT);
    const char *null_folder[] = {NULL};
    haus_build_options bad_folders = {0};
    bad_folders.folders = null_folder;
    bad_folders.folders_len = 1;
    CHECK(haus_schema_build(app, &bad_folders, &schema, &err) == HAUS_INVALID_ARGUMENT);
    CHECK(haus_schema_build("no/such/file.schema.haus", NULL, &schema, &err) == HAUS_SCHEMA_ERROR && code_is(&err, "import-not-found"));
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: c_api_test EXTENSIONS_DIR EXAMPLES_DIR TEST_DIR\n");
        return 2;
    }
    test_text_functions();
    test_parse_and_read();
    test_build_and_write();
    test_schema();
    test_plain_stream();
    test_build(argv[1], argv[2], argv[3]);
    printf("C ABI from C: %d checks, %d failed\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
