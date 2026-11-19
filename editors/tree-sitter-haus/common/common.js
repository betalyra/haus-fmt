/**
 * Rules shared by the haus grammar (data files, `.haus`) and the haus_schema
 * grammar (schema files, `.schema.haus`): comments, whitespace and the data
 * values, which schema files use for attribute arguments.
 *
 * Source of truth: spec/grammar.ebnf and spec/README.md §1–§6.
 */

const HEX = '[0-9A-Fa-f]';

// A Unicode scalar value written with 1–6 hex digits: at most 10FFFF and not
// a surrogate (D800–DFFF), so `\u{D800}` and `\u{110000}` are errors.
const FOUR = `(?:[0-9A-Ca-cE-Fe-f]${HEX}{3}|[Dd][0-7]${HEX}{2})`;
const FIVE = `(?:[1-9A-Fa-f]${HEX}{4}|0${FOUR})`;
const SIX = `(?:10${HEX}{4}|0${FIVE})`;
const SCALAR = `(?:${HEX}{1,3}|${FOUR}|${FIVE}|${SIX})`;

/** Bare keys (and, in schema files, attribute names). */
const LOWER_IDENTIFIER = /[a-z_][A-Za-z0-9_]*/;
/** Variant tags (and, in schema files, type names). */
const UPPER_IDENTIFIER = /[A-Z][A-Za-z0-9_]*/;

/** `rule`, then more separated by `separator`. */
const sepBy1 = (separator, rule) => seq(rule, repeat(seq(separator, rule)));

/** One or more `rule`s separated by commas, with an optional trailing comma. */
const commaList = (rule) => seq(sepBy1(',', rule), optional(','));

/** The order matches `enum TokenType` in common/scanner.h. */
const externals = ($) => [
  $.block_comment,
  $.line_comment,
  $.string_content,
  $._block_string_start,
  $._block_string_content,
  $._block_string_end,
  $._payload_start,
  $._no_payload,
  $._lone_carriage_return,
  $._error_sentinel,
];

/**
 * Spaces, tabs, line breaks (LF or CR LF; a lone CR is an error) and
 * comments. Both kinds of comment come from the external scanner: block
 * comments nest, and neither may contain control characters, bidirectional
 * controls or invalid UTF-8.
 */
const extras = ($) => [/[ \t]/, /\r?\n/, $.line_comment, $.block_comment];

const rules = {
  _value: ($) => choice($.record, $.array, $.variant, $.string, $.block_string, $.bytes, $.number),

  // ── Records and arrays ─────────────────────────────────────────────

  record: ($) => seq('{', optional(commaList($.field)), '}'),

  field: ($) => seq(field('key', choice($.identifier, $.string)), ':', field('value', $._value)),

  array: ($) => seq('[', optional(commaList($._value)), ']'),

  // ── Variants ───────────────────────────────────────────────────────

  // The payload starts on the tag's line: only spaces and tabs may come
  // between them, no line break and no comment (spec §5). The external
  // scanner decides right after the tag, before a comment can be lexed.
  // `Tag()` is not allowed: `arguments` has at least one value.
  variant: ($) =>
    seq(
      field('tag', $.tag),
      choice(seq($._payload_start, field('payload', choice($.arguments, $.record))), $._no_payload),
    ),

  arguments: ($) => seq('(', commaList($._value), ')'),

  // ── Strings ────────────────────────────────────────────────────────

  string: ($) => seq('"', repeat(choice($.string_content, $.escape_sequence)), token.immediate('"')),

  // The opening `"""` ends its line; the closing one stands on its own line,
  // and its indent is checked by the external scanner (spec §4).
  block_string: ($) =>
    seq(
      $._block_string_start,
      repeat(choice(alias($._block_string_content, $.string_content), $.escape_sequence)),
      // Visible, so that a missing closing delimiter shows as a MISSING node.
      alias($._block_string_end, '"""'),
    ),

  escape_sequence: (_) => token.immediate(seq('\\', choice(/["\\nrt]/, new RegExp(`u\\{${SCALAR}\\}`)))),

  // Two hex digits per byte, blanks between bytes, on one line.
  bytes: (_) => token(/x"[ \t]*(?:[0-9A-Fa-f]{2}(?:[ \t]*[0-9A-Fa-f]{2})*[ \t]*)?"/),

  // ── Numbers ────────────────────────────────────────────────────────

  // Kept as written: the value is the exact literal (spec §3). A number may
  // not be followed directly by [A-Za-z0-9_.]; in this grammar such a
  // character starts another token, and two values without a comma between
  // them are an error, so `007`, `1.`, `1_`, `0x` and `1e` are errors.
  number: (_) =>
    token(
      choice(
        /-?0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*/,
        /-?0b[01](?:_?[01])*/,
        /-?(?:0|[1-9](?:_?[0-9])*)(?:\.[0-9](?:_?[0-9])*)?(?:[eE][+-]?[0-9](?:_?[0-9])*)?/,
      ),
    ),

  // ── Identifiers ────────────────────────────────────────────────────

  identifier: (_) => LOWER_IDENTIFIER,

  tag: (_) => UPPER_IDENTIFIER,
};

module.exports = {
  LOWER_IDENTIFIER,
  UPPER_IDENTIFIER,
  commaList,
  externals,
  extras,
  rules,
  sepBy1,
};
