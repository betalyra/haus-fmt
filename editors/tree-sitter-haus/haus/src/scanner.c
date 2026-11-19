// The external scanner of the haus grammar: see common/scanner.h.

#include "tree_sitter/parser.h"

#include <stdlib.h>

#include "../../common/scanner.h"

void *tree_sitter_haus_external_scanner_create(void) { return calloc(1, sizeof(Scanner)); }

void tree_sitter_haus_external_scanner_destroy(void *payload) { free(payload); }

unsigned tree_sitter_haus_external_scanner_serialize(void *payload, char *buffer) {
  return haus_serialize((Scanner *)payload, buffer);
}

void tree_sitter_haus_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
  haus_deserialize((Scanner *)payload, buffer, length);
}

bool tree_sitter_haus_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
  return haus_scan((Scanner *)payload, lexer, valid_symbols);
}
