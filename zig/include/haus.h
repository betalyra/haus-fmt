/*
 * haus: the C ABI of the Zig binding (zig/src/c_api.zig).
 *
 * Text goes in as a pointer and a length in bytes (UTF-8; it may hold NUL
 * characters; a NULL pointer is allowed with length 0). Names (types, paths)
 * are NUL-terminated.
 *
 * Ownership
 *   - Text the library returns (char **out, size_t *out_len) is released
 *     with haus_free(ptr, len).
 *   - Every handle is released by its own function: haus_doc_free,
 *     haus_schema_free, haus_stream_free, haus_issues_free. Freeing NULL
 *     does nothing.
 *   - A haus_value is borrowed from the haus_doc that holds it and is valid
 *     until that doc is freed. Values are never freed one by one.
 *   - A value built from other values (haus_new_array, haus_new_record,
 *     haus_new_variant) shares them, and the result of haus_decode and
 *     haus_encode may share parts of the value given: keep the docs they
 *     came from alive as long as the new value is used.
 *   - A haus_type is borrowed from its haus_schema. Docs a schema
 *     function returns don't refer to the schema: it may be freed first.
 *
 * Threads
 *   There is no global state. Every function may be called from several
 *   threads at once. A doc that is no longer built into, a schema and its
 *   types may be read from several threads at once; a doc being built into
 *   and a stream are used by one thread at a time.
 *
 * Statuses
 *   Every function that can fail returns a status. On HAUS_ERROR and
 *   HAUS_SCHEMA_ERROR the haus_error (which may be NULL) has the code of
 *   spec §17, the position and a message; out parameters are left as they
 *   were.
 */
#ifndef HAUS_H
#define HAUS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Statuses. */
#define HAUS_OK 0
#define HAUS_ERROR 1            /* a mistake with a code of spec §17: see haus_error */
#define HAUS_OUT_OF_MEMORY 2
#define HAUS_INVALID_ARGUMENT 3 /* a NULL pointer, a negative indent or width, an unknown layout,
                                   a type that doesn't fit the call, an index past the end */
#define HAUS_SCHEMA_ERROR 4     /* a mistake in a schema file or a build (spec §13.3, §14): see haus_error */

/* Layouts (spec §11). */
#define HAUS_PRETTY 0
#define HAUS_COMPACT 1
#define HAUS_MINIMISED 2
/* Or'ed into the layout of haus_format and haus_stringify_doc: the file is a
 * stream (spec §11, "Streams"), so a single item has a comma after it too.
 * haus_stringify writes one value and refuses it (HAUS_INVALID_ARGUMENT). */
#define HAUS_STREAM 0x100

/* Kinds of values (spec §1). */
#define HAUS_NUMBER 1
#define HAUS_STRING 2
#define HAUS_BYTES 3
#define HAUS_ARRAY 4
#define HAUS_RECORD 5
#define HAUS_VARIANT 6
#define HAUS_SECRET 7   /* a decoded Secret (spec §15): see haus_secret_reveal */

typedef struct haus_error {
    char code[32];      /* the code of spec §17 ("missing-comma"), NUL-terminated */
    uint32_t line;      /* 1-based (spec §8); 0 where there is no position */
    uint32_t column;    /* in code points */
    char message[192];  /* for people, NUL-terminated */
    char path[256];     /* the place in a value (spec §15: "$.items[2].price"),
                           for an error of a decoder, encoder or JSON reader; else empty */
} haus_error;

typedef struct haus_doc haus_doc;         /* values and their memory */
typedef struct haus_value haus_value;     /* a value, borrowed from its doc */
typedef struct haus_schema haus_schema;   /* a schema, read and checked */
typedef struct haus_type haus_type;       /* a type of a schema, borrowed from it */
typedef struct haus_stream haus_stream;   /* a stream reader, plain or typed */
typedef struct haus_issues haus_issues;   /* what a check found */

/* ── text in, text out ───────────────────────────────────── */

/* The canonical form (spec §12) of each value of a file, each followed by
 * a line feed. */
int haus_canonical(const char *text, size_t len, char **out, size_t *out_len, haus_error *err);

/* hashAll (spec §12) of a file's values: 64 lowercase hex digits and a NUL. */
int haus_hash_all(const char *text, size_t len, char out[65], haus_error *err);

/* Formats a file in a layout (spec §11), keeping comments in pretty.
 * indent and width are pretty's options (2 and 80 are the defaults; 0 is
 * taken literally); a negative one is HAUS_INVALID_ARGUMENT. layout may have
 * HAUS_STREAM or'ed in. */
int haus_format(const char *text, size_t len, int layout, int indent, int width,
                char **out, size_t *out_len, haus_error *err);

/* Releases text the library returned. */
void haus_free(char *ptr, size_t len);

/* The version of the specification implemented ("0.1"). */
const char *haus_spec_version(void);

/* ── docs ────────────────────────────────────────────────── */

/* A new, empty doc to build values in; NULL when out of memory. */
haus_doc *haus_doc_new(void);
void haus_doc_free(haus_doc *doc);

/* Parses one value (spec §6: none or several is "not-one-value"). */
int haus_parse(const char *text, size_t len, haus_doc **out_doc, const haus_value **out, haus_error *err);

/* Parses a file: zero or more values, read with haus_doc_count and haus_doc_value. */
int haus_parse_all(const char *text, size_t len, haus_doc **out_doc, haus_error *err);

/* The top-level values of a doc: a parsed file's, or a stream's items. */
size_t haus_doc_count(const haus_doc *doc);
const haus_value *haus_doc_value(const haus_doc *doc, size_t i); /* NULL past the end */

/* ── reading values ──────────────────────────────────────── */

int haus_kind(const haus_value *v); /* HAUS_NUMBER … HAUS_SECRET; 0 for NULL */

/* Bytes of a number, string or byte string, with their length in *len (which
 * may be NULL); not NUL-terminated. NULL for another kind. A number is its
 * normalized literal (spec §2): "255" for 0xFF, "1e5" for 1E+05, "19.90" as written. */
const char *haus_number(const haus_value *v, size_t *len);
const char *haus_string(const haus_value *v, size_t *len);
const uint8_t *haus_bytes(const haus_value *v, size_t *len);

/* The items of an array, fields of a record, arguments of a variant; 0 for other kinds. */
size_t haus_len(const haus_value *v);
const haus_value *haus_array_get(const haus_value *v, size_t i);
/* A record's fields in the order written; haus_record_get finds one by its key. */
const char *haus_record_key(const haus_value *v, size_t i, size_t *len);
const haus_value *haus_record_value(const haus_value *v, size_t i);
const haus_value *haus_record_get(const haus_value *v, const char *key, size_t key_len);
/* A variant's tag and arguments. Tag { … } has one argument, the record. */
const char *haus_variant_tag(const haus_value *v, size_t *len);
const haus_value *haus_variant_arg(const haus_value *v, size_t i);
/* A Secret in a decoded value (spec §15) is a value of kind HAUS_SECRET: the
 * accessors above see nothing in it, and every writer, the canonical form, the
 * hash, equality and order reject it ("cannot-encode" with the secret's place
 * in path, the value not shown: "$.pin"; "$[i].pin" for haus_stringify_doc;
 * for equality and order the message says which operand), so it isn't
 * written or logged by mistake; haus_encode writes it in full.
 * This explicit call gives out the value it hides; NULL for another kind. */
const haus_value *haus_secret_reveal(const haus_value *v);

/* A number as an int64_t: "not-an-integer" for one spelled with a fraction
 * or an exponent, "out-of-range" beyond int64_t. Another kind is
 * HAUS_INVALID_ARGUMENT. */
int haus_number_int64(const haus_value *v, int64_t *out, haus_error *err);
/* A number as the nearest double: "out-of-range" beyond its range. */
int haus_number_double(const haus_value *v, double *out, haus_error *err);

/* ── building values (spec §11, "Values built in code") ──── */

/* Each puts a new value into doc and sets *out to it. Builders check that the
 * value is a haus value, never a limit (the writers check those). */

/* A number from a literal in any spelling ("0xFF", "1E+05", "1_000"),
 * normalized as the parser does; one that isn't a literal is "invalid-number". */
int haus_new_number(haus_doc *doc, const char *literal, size_t len, const haus_value **out, haus_error *err);
/* A string, copied; one that isn't UTF-8 is "cannot-encode". */
int haus_new_string(haus_doc *doc, const char *s, size_t len, const haus_value **out, haus_error *err);
int haus_new_bytes(haus_doc *doc, const uint8_t *bytes, size_t len, const haus_value **out, haus_error *err);
/* An array of n values, shared (see Ownership). */
int haus_new_array(haus_doc *doc, const haus_value *const *items, size_t n, const haus_value **out, haus_error *err);

typedef struct haus_field {
    const char *key;
    size_t key_len;
    const haus_value *value;
} haus_field;

/* A record of n fields in this order: keys copied (UTF-8, else "cannot-encode";
 * a key twice is "duplicate-key"), values shared. */
int haus_new_record(haus_doc *doc, const haus_field *fields, size_t n, const haus_value **out, haus_error *err);
/* A variant: a tag [A-Z][A-Za-z0-9_]* (else "invalid-tag") and n arguments, shared. */
int haus_new_variant(haus_doc *doc, const char *tag, size_t tag_len, const haus_value *const *args, size_t n,
                     const haus_value **out, haus_error *err);

/* ── writing and comparing values ────────────────────────── */

/* One value in a layout (spec §11), without a line break after it. The
 * writers check the limits of spec §7 ("nesting-too-deep", "number-too-long", …). */
int haus_stringify(const haus_value *v, int layout, int indent, int width, char **out, size_t *out_len, haus_error *err);
/* The top-level values of a doc as a file (spec §6, §11); with HAUS_STREAM
 * or'ed into layout, as a stream: a comma after every value, a single one too. */
int haus_stringify_doc(const haus_doc *doc, int layout, int indent, int width, char **out, size_t *out_len, haus_error *err);
/* The canonical form (spec §12) of a value, without a line break. */
int haus_value_canonical(const haus_value *v, char **out, size_t *out_len, haus_error *err);
/* The hash (spec §12): 64 lowercase hex digits and a NUL. */
int haus_value_hash(const haus_value *v, char out[65], haus_error *err);
/* Equality (spec §2): *out is 1 or 0. */
int haus_value_equals(const haus_value *a, const haus_value *b, int *out, haus_error *err);
/* The order of spec §12: *out is -1, 0 or 1. */
int haus_value_compare(const haus_value *a, const haus_value *b, int *out, haus_error *err);

/* ── JSON without a schema (spec §16.1, §16.2) ───────────── */

int haus_import_json(const char *json, size_t len, haus_doc **out_doc, const haus_value **out, haus_error *err);
int haus_from_haus_json(const char *json, size_t len, haus_doc **out_doc, const haus_value **out, haus_error *err);
int haus_to_haus_json(const haus_value *v, char **out, size_t *out_len, haus_error *err);

/* ── schemas (spec §13–§16) ──────────────────────────────── */

/* Loads a schema file from text. It imports std/time only ("import-unavailable"
 * otherwise: use haus_schema_build). Its types' ids are "local#Name". */
int haus_schema_load(const char *text, size_t len, haus_schema **out, haus_error *err);

/* A package given as files in memory (spec §13.3, a file tree): its
 * package.haus and schema.haus, and maybe a package.json. Copied by the build. */
typedef struct haus_package_file {
    const char *name;       /* "package.haus", NUL-terminated */
    const uint8_t *bytes;
    size_t len;
} haus_package_file;

typedef struct haus_package_tree {
    const char *shown;      /* how messages name it, e.g. "@acme/orders (embedded)" */
    const haus_package_file *files;
    size_t files_len;
} haus_package_tree;

typedef struct haus_build_options {
    const char *const *packages; size_t packages_len; /* package directories */
    const char *const *folders; size_t folders_len;   /* folders of package directories */
    const haus_package_tree *trees; size_t trees_len;
    const char *root;           /* the build's root; NULL: the entry file's directory */
    int skip_version_check;     /* 0: check a manifest's version against its package.json */
} haus_build_options;

/* Builds the schema of the schema file at the path entry, with what it
 * imports (spec §13.3). options may be NULL. This binding never looks in
 * node_modules: packages are the ones given. Types of a package have the
 * ids "@org/name@N#Name"; those of other files "./path/from/root.schema.haus#Name". */
int haus_schema_build(const char *entry, const haus_build_options *options, haus_schema **out, haus_error *err);
void haus_schema_free(haus_schema *schema);

/* Warnings about the schema file (spec §14): code, line and column. */
size_t haus_schema_warning_count(const haus_schema *schema);
int haus_schema_warning(const haus_schema *schema, size_t i, haus_error *out);

/* A type the schema file defines, without parameters; NULL otherwise. */
const haus_type *haus_schema_type(const haus_schema *schema, const char *name);
/* A type's id (spec §13.3, "Identity"), not NUL-terminated. */
const char *haus_type_id(const haus_type *t, size_t *len);
int haus_type_is_stream(const haus_type *t); /* 1 for a Stream type */

/* Decodes a value with a type (spec §15). The result, in a new doc, is the
 * value as decoding has it: fields an open record doesn't list left out,
 * floats in the one spelling of §15, -0 as 0 for an integer, a Secret as a
 * HAUS_SECRET value. A Stream type is HAUS_INVALID_ARGUMENT (use
 * haus_decode_text or a typed stream). */
int haus_decode(const haus_type *t, const haus_value *v, haus_doc **out_doc, const haus_value **out, haus_error *err);
/* Decodes a text: one value, or for a Stream type every value, as an array
 * of the items (errors at "$[i]"). */
int haus_decode_text(const haus_type *t, const char *text, size_t len, haus_doc **out_doc, const haus_value **out, haus_error *err);
/* Encodes a value built in code with a type: one the type doesn't accept is
 * "cannot-encode" at its place ("invalid-secret" inside a Secret); the
 * limits of spec §7 are checked. The result is the data to write, as
 * haus_decode has it but with every Secret's value in it (it is written in full). */
int haus_encode(const haus_type *t, const haus_value *v, haus_doc **out_doc, const haus_value **out, haus_error *err);

/* Checks a text as a tool does (spec §14): the hints ("unlisted-field",
 * "unlisted-tag", "deprecated") and every error (spec §14, "Every error"),
 * in the order of their places in the text. A document with a syntax or
 * limit error has that one issue; a Stream type is checked item by item, the
 * items' errors before the syntax or limit error that ends the check (an
 * error in the text has an empty path, and its line and column). Each error
 * once; nothing below a value that failed at its own level; a record reports
 * each missing field ("missing-field" at the record) and checks every other
 * field; any error inside a Secret is one "invalid-secret" at the secret,
 * and there are no hints inside one. The check stops after
 * HAUS_CHECK_MAX_ERRORS errors in all (hints don't count) and then says so
 * (haus_issues_stopped). HAUS_OK when the check ran. */
#define HAUS_CHECK_MAX_ERRORS 200
int haus_check_text(const haus_type *t, const char *text, size_t len, haus_issues **out, haus_error *err);
/* The same, stopping at the first error: the hints found before it, and
 * that error (one of those haus_check_text reports). */
int haus_check_text_first(const haus_type *t, const char *text, size_t len, haus_issues **out, haus_error *err);

typedef struct haus_issue {
    int is_error;           /* 1: an error; 0: a hint */
    const char *code;       /* NUL-terminated */
    const char *path; size_t path_len;
    const char *message; size_t message_len;  /* empty for a hint */
    uint32_t line, column;  /* for an error in the text; else 0 */
} haus_issue;

size_t haus_issues_count(const haus_issues *issues);
/* 1 when the check stopped at HAUS_CHECK_MAX_ERRORS errors (the rest of the text was not checked); 0 otherwise. */
int haus_issues_stopped(const haus_issues *issues);
int haus_issues_get(const haus_issues *issues, size_t i, haus_issue *out); /* strings borrowed from issues */
void haus_issues_free(haus_issues *issues);

/* Schema-based JSON (spec §16.3): a value decoded with the type and written
 * as JSON, and JSON read with the type into the value it encodes to. */
int haus_type_to_json(const haus_type *t, const haus_value *v, char **out, size_t *out_len, haus_error *err);
int haus_type_from_json(const haus_type *t, const char *json, size_t len, haus_doc **out_doc, const haus_value **out, haus_error *err);

/* The one-call forms: a schema file's text and a type's name. A mistake in
 * the schema is HAUS_SCHEMA_ERROR; an unknown or generic type HAUS_INVALID_ARGUMENT. */
int haus_check(const char *schema, size_t schema_len, const char *type_name,
               const char *text, size_t len, haus_error *err);
int haus_to_json(const char *schema, size_t schema_len, const char *type_name,
                 const char *text, size_t len, char **out, size_t *out_len, haus_error *err);
/* Writes the value in canonical form (spec §12). */
int haus_from_json(const char *schema, size_t schema_len, const char *type_name,
                   const char *json, size_t len, char **out, size_t *out_len, haus_error *err);

/* ── streams (spec §6, §7, §15 "Streams") ────────────────── */

/* A stream reader: bytes in, values out once their comma arrives. strict (1)
 * requires a comma after the last value ("stream-truncated" otherwise). */
int haus_stream_new(int strict, haus_stream **out);
/* A typed reader for a Stream type: each value is decoded as it arrives. */
int haus_typed_stream_new(const haus_type *t, haus_stream **out);
/* The next chunk: *out_doc is a new doc whose top-level values are the
 * values the chunk completed (maybe none). After an error or the end, the
 * stream takes nothing more (HAUS_INVALID_ARGUMENT). */
int haus_stream_push(haus_stream *s, const char *chunk, size_t len, haus_doc **out_doc, haus_error *err);
/* The end of the stream: *out_doc holds the last value, if any. */
int haus_stream_end(haus_stream *s, haus_doc **out_doc, haus_error *err);
void haus_stream_free(haus_stream *s);

#ifdef __cplusplus
}
#endif

#endif /* HAUS_H */
