/*
 * haus: the C ABI of the Zig binding (zig/src/c_api.zig).
 *
 * Text goes in as a pointer and a length in bytes (UTF-8; it may hold NUL
 * characters). Text comes out in a buffer the library allocates: release
 * it with haus_free(ptr, len). Every function is independent of the others
 * and may be called from several threads at once.
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
#define HAUS_INVALID_ARGUMENT 3 /* a null pointer, a negative indent or width, an unknown layout or type */
#define HAUS_SCHEMA_ERROR 4     /* a mistake in a schema file (spec §14): see haus_error */

/* Layouts (spec §11). */
#define HAUS_PRETTY 0
#define HAUS_COMPACT 1
#define HAUS_MINIMISED 2

typedef struct haus_error {
    char code[32];      /* the code of spec §17 ("missing-comma"), NUL-terminated */
    uint32_t line;      /* 1-based (spec §8); 0 where there is no position */
    uint32_t column;    /* in code points */
    char message[192];  /* for people, NUL-terminated */
    char path[256];     /* the place in a value (spec §15: "$.items[2].price"),
                           for an error of a decoder or JSON reader; else empty */
} haus_error;

/* The canonical form (spec §12) of each value of a file, each followed by
 * a line feed. */
int haus_canonical(const char *text, size_t len, char **out, size_t *out_len, haus_error *err);

/* hashAll (spec §12) of a file's values: 64 lowercase hex digits and a NUL. */
int haus_hash_all(const char *text, size_t len, char out[65], haus_error *err);

/* Formats a file in a layout (spec §11), keeping comments in pretty.
 * indent and width are pretty's options (2 and 80 are the defaults; 0 is
 * taken literally); a negative one is HAUS_INVALID_ARGUMENT. */
int haus_format(const char *text, size_t len, int layout, int indent, int width,
                char **out, size_t *out_len, haus_error *err);

/* Checks a haus text against the type type_name (NUL-terminated) of a
 * schema file (spec §14, §15): every value for a Stream type, exactly one
 * otherwise. A mistake in the schema file is HAUS_SCHEMA_ERROR; one in the
 * text or the value is HAUS_ERROR, with the value's place in err->path. An
 * unknown or generic type is HAUS_INVALID_ARGUMENT. */
int haus_check(const char *schema, size_t schema_len, const char *type_name,
               const char *text, size_t len, haus_error *err);

/* Decodes a haus text (one value) with a type and writes its schema-based
 * JSON (spec §16.3). */
int haus_to_json(const char *schema, size_t schema_len, const char *type_name,
                 const char *text, size_t len, char **out, size_t *out_len, haus_error *err);

/* Reads schema-based JSON with a type and writes the value it encodes to,
 * in canonical form (spec §12). */
int haus_from_json(const char *schema, size_t schema_len, const char *type_name,
                   const char *json, size_t len, char **out, size_t *out_len, haus_error *err);

/* Releases a buffer the library returned. */
void haus_free(char *ptr, size_t len);

/* The version of the specification implemented ("0.1"). */
const char *haus_spec_version(void);

#ifdef __cplusplus
}
#endif

#endif /* HAUS_H */
