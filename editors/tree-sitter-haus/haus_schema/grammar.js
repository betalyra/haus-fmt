/**
 * @file Tree-sitter grammar for haus schema files (`.schema.haus`)
 * @license MIT
 *
 * Source of truth: the schema part of spec/grammar.ebnf and spec/README.md
 * §13–§14. Comments, whitespace and the values in attribute arguments are
 * those of data files (../common/common.js).
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const { LOWER_IDENTIFIER, UPPER_IDENTIFIER, commaList, externals, extras, rules, sepBy1 } = require('../common/common.js');

// A type name is lexed like a tag (`[A-Z][A-Za-z0-9_]*`): one token, named by
// where it stands.
const typeName = ($) => alias($.tag, $.type_name);

module.exports = grammar({
  name: 'haus_schema',

  externals,
  extras,

  rules: {
    schema_file: ($) => repeat(choice($.import, $.type_definition)),

    // ── Imports (spec §13) ─────────────────────────────────────────────

    // import std/time (Date, Instant)
    // import @haus-fmt/money@1 (Money)
    // import ./common (Address)
    import: ($) => seq('import', field('module', $.module), '(', commaList(field('name', typeName($))), ')'),

    module: (_) =>
      token(
        choice(
          // A standard module.
          seq('std/', LOWER_IDENTIFIER),
          // A schema package is one token: everything up to the first space,
          // tab, line break or `(` (grammar.ebnf, module_char). Whether it is
          // `@org/name` with npm's rules for scoped names in lowercase, and
          // a major version without leading zeros, is checked beyond the
          // syntax (`unknown-module`, `import-version`).
          /@[^ \t\r\n(]+/,
          // A schema file next to this one, without `.schema.haus`.
          seq(choice('./', '../'), /[A-Za-z0-9_.\/-]*/),
        ),
      ),

    // ── Type definitions (spec §14) ────────────────────────────────────

    type_definition: ($) =>
      seq(
        repeat($.attribute),
        'type',
        field('name', typeName($)),
        repeat(field('parameter', $.type_parameter)),
        '=',
        field('type', $._type),
      ),

    // Metadata for tools, never for decoding: @deprecated("use email"). No
    // space between the name and its arguments.
    attribute: ($) =>
      seq(
        '@',
        field('name', alias(token.immediate(LOWER_IDENTIFIER), $.identifier)),
        optional(field('arguments', $.attribute_arguments)),
      ),

    attribute_arguments: ($) => seq(token.immediate('('), commaList($._value), ')'),

    _type: ($) => choice($.type_application, $._atom),

    // Array Point, Map (Maybe Int)
    type_application: ($) => seq(field('constructor', typeName($)), repeat1(field('argument', $._atom))),

    _atom: ($) => choice(typeName($), $.type_parameter, $.parenthesized_type, $.record_type, $.variant_type),

    parenthesized_type: ($) => seq('(', $._type, ')'),

    // Open unless closed: other fields are ignored.
    record_type: ($) => seq(optional('closed'), '{', optional(commaList(choice($.field_declaration, $.spread))), '}'),

    // key: T, or key?: T for a field that may be missing (key ?: T too).
    field_declaration: ($) =>
      seq(
        repeat($.attribute),
        field('key', choice($.identifier, $.string)),
        optional('?'),
        ':',
        field('type', $._type),
      ),

    // Open unless closed: other tags become Unknown. `< >` has any tags.
    variant_type: ($) =>
      seq(optional('closed'), '<', optional('|'), optional(sepBy1('|', choice($.case, $.spread))), '>'),

    // Tag { … }: named fields; Tag A B: positional.
    case: ($) => seq(repeat($.attribute), field('tag', $.tag), repeat(field('argument', $._atom))),

    // ...UserEvent: copy the named type's tags or fields here.
    spread: ($) => seq('...', field('name', alias(token.immediate(UPPER_IDENTIFIER), $.type_name))),

    // Not "type", "import" or "closed", which are keywords.
    type_parameter: (_) => /[a-z][A-Za-z0-9_]*/,

    ...rules,
  },
});
