/**
 * @file Tree-sitter grammar for haus data files (`.haus`)
 * @license MIT
 *
 * Source of truth: spec/grammar.ebnf and spec/README.md §1–§6. Schema files
 * (`.schema.haus`) have their own grammar, ../haus_schema.
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const { commaList, externals, extras, rules } = require('../common/common.js');

module.exports = grammar({
  name: 'haus',

  externals,
  extras,

  rules: {
    // A file is a sequence of zero or more values separated by commas, with
    // an optional trailing comma (spec §6). A leading byte order mark is
    // skipped by the tree-sitter runtime (see common/scanner.h). A file starting with `#` is reserved for the version directive
    // of a future, incompatible version (spec §10): an error here, as in every
    // parser of this version.
    source_file: ($) => optional(commaList($._value)),

    ...rules,
  },
});
