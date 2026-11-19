#!/usr/bin/env node
// Checks the grammars against the rest of the repository:
//
// - every data file (`.haus`, and the format suite's expected outputs) is
//   parsed with tree-sitter and with the TypeScript reference parser
//   (typescript/packages/haus): where the reference accepts the file, the
//   tree must have no ERROR or MISSING node and must give the same values
//   (compared by their canonical form, spec §12); where it rejects the file,
//   the tree must have an error, unless the reference's error code is one
//   that a grammar can't check (duplicate keys, limits);
// - every schema file (`.schema.haus`, `schema.haus`) must parse without
//   errors, except test-suite/schema/invalid, where the files with a syntax
//   error code must give an error and the others must not;
// - with `--fuzz N`, N documents from fuzz/src/generate.ts go through the
//   same comparison as data files (`--mutate`: half of them mutated, as the
//   differential fuzzer does).
//
//   node scripts/check.mjs [--fuzz N] [--seed S] [--mutate] [--verbose]
//
// Needs the tree-sitter CLI (node_modules/.bin/tree-sitter, or the path in
// $TREE_SITTER) and the built TypeScript package (pnpm --filter
// ./packages/haus build in typescript/). Exits with 1 if anything disagrees.

import { execFile, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { availableParallelism, tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const repo = resolve(root, '../..');

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : fallback;
};
const fuzzCount = Number(option('--fuzz', '0'));
const seed = Number(option('--seed', String(Date.now() % 1_000_000)));
const mutate = args.includes('--mutate');
const verbose = args.includes('--verbose');

// The tree-sitter command: a path, or a command with arguments ("npx tree-sitter").
const [treeSitter, ...treeSitterArgs] = (process.env.TREE_SITTER ?? join(root, 'node_modules', '.bin', 'tree-sitter')).split(' ');
const ref = await import(pathToFileURL(join(repo, 'typescript/packages/haus/dist/index.js')).href);

const SCOPES = { data: 'source.haus', schema: 'source.haus.schema' };

// Error codes (spec/errors.md) for text that is syntactically valid: a
// grammar can't see duplicate keys or count characters and nesting levels.
const SEMANTIC_DATA_CODES = new Set([
  'duplicate-key',
  'nesting-too-deep',
  'number-too-long',
  'exponent-too-large',
  'string-too-long',
  'key-too-long',
  'tag-too-long',
  'value-too-long',
  'unsupported-depth',
]);

// Schema error codes for syntax errors; every other code is a check beyond
// the syntax (spec §14).
const SYNTAX_SCHEMA_CODES = new Set([
  'schema-syntax',
  'attribute-space',
  'attribute-on-spread',
  'row-parameter',
  'import-version',
  'invalid-parameter',
  // `import std/time ()`: the grammar requires at least one name.
  'unknown-import',
  // Comments, whitespace and quoted keys are those of data files, with their
  // codes (spec §14).
  'unterminated-string',
  'unterminated-comment',
  'lone-carriage-return',
  'control-character',
  'bidi-control',
  'invalid-utf8',
  'invalid-escape',
  'string-line-break',
  'stray-slash',
  // `@deprecated("x"`: an attribute's arguments without their `)`.
  'missing-comma',
]);

// Schema error codes that are syntax errors for some files and not for
// others: `unknown-module` is a package name the grammar's `segment` rules out
// (`@Haus/money`, spec §13.3) or a module it allows that doesn't exist
// (`std/money`).
const EITHER_SCHEMA_CODES = new Set(['unknown-module']);

// ── Running tree-sitter ───────────────────────────────────────────────

// Each grammar is compiled once into a shared library, which every
// `tree-sitter parse` then loads (`--scope` would need a configured parser
// directory, and `--grammar-path` rebuilds on every call).
const grammarOf = { 'source.haus': 'haus', 'source.haus.schema': 'haus_schema' };
const libDir = mkdtempSync(join(tmpdir(), 'tree-sitter-haus-'));
const libraries = Object.fromEntries(
  Object.values(grammarOf).map((name) => {
    const lib = join(libDir, `${name}${process.platform === 'win32' ? '.dll' : process.platform === 'darwin' ? '.dylib' : '.so'}`);
    execFileSync(treeSitter, [...treeSitterArgs, 'build', '-o', lib, name], { cwd: root, stdio: ['ignore', 'ignore', 'inherit'] });
    return [name, lib];
  }),
);

const run = (file, scope) =>
  new Promise((done) => {
    const name = grammarOf[scope];
    execFile(treeSitter, [...treeSitterArgs, 'parse', '--lib-path', libraries[name], '--lang-name', name, file], { cwd: root, maxBuffer: 256 << 20 }, (error, stdout, stderr) => {
      done({ status: error ? (error.code ?? 1) : 0, stdout, stderr });
    });
  });

/** Runs `tasks` (functions returning promises) with bounded concurrency. */
async function pool(tasks, size = availableParallelism()) {
  const results = new Array(tasks.length);
  let next = 0;
  const worker = async () => {
    while (next < tasks.length) {
      const i = next++;
      results[i] = await tasks[i]();
    }
  };
  await Promise.all(Array.from({ length: Math.min(size, tasks.length) }, worker));
  return results;
}

// ── Reading `tree-sitter parse` output ────────────────────────────────

// (type [row, column] - [row, column] field: (child …) …), columns in bytes.
const TOKEN = /\s*(?:(\()|(\))|\[(\d+), (\d+)\] - \[(\d+), (\d+)\]|([A-Za-z_][\w]*):(?=\s|\()|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s()]+))/y;

/** The first tree in the output, or undefined if there is none. */
function readTree(output) {
  const at = output.search(/\((?:source_file|schema_file|ERROR)\b/);
  if (at < 0) return undefined;
  TOKEN.lastIndex = at;
  const stack = [];
  let field;
  let rootNode;
  while (TOKEN.lastIndex < output.length) {
    const m = TOKEN.exec(output);
    if (!m) break;
    if (m[1]) {
      const node = { type: undefined, field, start: undefined, end: undefined, children: [] };
      field = undefined;
      if (stack.length) stack.at(-1).children.push(node);
      else rootNode = node;
      stack.push(node);
    } else if (m[2]) {
      stack.pop();
      if (!stack.length) return rootNode;
    } else if (m[3] !== undefined) {
      const node = stack.at(-1);
      node.start = [Number(m[3]), Number(m[4])];
      node.end = [Number(m[5]), Number(m[6])];
    } else if (m[7]) {
      field = m[7];
    } else if (m[8] !== undefined) {
      const node = stack.at(-1);
      if (node && node.type === undefined) node.type = m[8];
    }
  }
  return rootNode;
}

const hasError = (node) => node.type === 'ERROR' || node.type === 'MISSING' || node.children.some(hasError);

// tree-sitter prints only named nodes in the tree, so a missing `}` or `"`
// shows only on the summary line after it (`(MISSING "}" [0, 6] - [0, 6])`).
// Node types and positions are all the output has, never the input's text,
// so `(ERROR` or `(MISSING` anywhere in it is an error in the tree.
const ERROR_IN_OUTPUT = /\((?:ERROR|MISSING)\b/;

/** Whether the parse of `out` has an ERROR or MISSING node. */
const broken = (out, tree) => hasError(tree) || ERROR_IN_OUTPUT.test(out.stdout) || ERROR_IN_OUTPUT.test(out.stderr);

// ── From a tree to haus values ────────────────────────────────────────

class Mismatch extends Error {}

function lineStarts(bytes) {
  const starts = [0];
  for (let i = 0; i < bytes.length; i++) if (bytes[i] === 0x0a) starts.push(i + 1);
  return starts;
}

const COMMENTS = new Set(['line_comment', 'block_comment']);

function converter(bytes) {
  const starts = lineStarts(bytes);
  const offset = ([row, column]) => starts[row] + column;
  const text = (node) => Buffer.from(bytes.subarray(offset(node.start), offset(node.end))).toString('utf8');
  const values = (node) => node.children.filter((c) => !COMMENTS.has(c.type)).map(value);
  const child = (node, name) => node.children.find((c) => c.field === name);

  function unescape(raw) {
    return raw.replace(/\\(u\{([0-9A-Fa-f]{1,6})\}|.)/gsu, (_, e, hex) => {
      if (hex) return String.fromCodePoint(parseInt(hex, 16));
      const simple = { '"': '"', '\\': '\\', n: '\n', r: '\r', t: '\t' }[e];
      if (simple === undefined) throw new Mismatch(`tree-sitter accepted the escape \\${e}`);
      return simple;
    });
  }

  // A basic string from its children: the content and escapes must cover
  // everything between the quotes.
  function basicString(node) {
    const raw = text(node);
    const inner = node.children.map((c) => {
      if (c.type === 'string_content') return text(c);
      if (c.type === 'escape_sequence') return unescape(text(c));
      throw new Mismatch(`unexpected ${c.type} in a string`);
    });
    const covered = node.children.map(text).join('');
    if ('"' + covered + '"' !== raw) throw new Mismatch(`string children don't cover ${JSON.stringify(raw)}`);
    return inner.join('');
  }

  // A block string from its text, with the indentation rules of spec §4.
  function blockString(node) {
    const raw = text(node);
    const open = /^"""[ \t]*\r?\n/.exec(raw);
    if (!open) throw new Mismatch(`block string without a line break after its opening: ${JSON.stringify(raw)}`);
    const lines = raw.slice(open[0].length).split(/\r?\n/);
    const closing = lines.pop();
    if (!/^[ \t]*"""$/.test(closing)) throw new Mismatch(`block string closing not on its own line: ${JSON.stringify(raw)}`);
    const indent = closing.slice(0, -3);
    const content = lines.map((line) => {
      if (line.startsWith(indent)) return line.slice(indent.length);
      if (/^[ \t]*$/.test(line)) return '';
      throw new Mismatch(`tree-sitter accepted a block string line without the indent: ${JSON.stringify(line)}`);
    });
    return unescape(content.join('\n'));
  }

  function value(node) {
    switch (node.type) {
      case 'number': {
        const literal = text(node);
        const normalized = ref.normalizeNumber(literal);
        if (normalized === undefined) throw new Mismatch(`not a number within the limits: ${literal}`);
        return ref.num(normalized);
      }
      case 'string':
        return ref.str(basicString(node));
      case 'block_string':
        return ref.str(blockString(node));
      case 'bytes': {
        const hex = text(node).slice(2, -1).replace(/[ \t]/g, '');
        return ref.bytes(Uint8Array.from(hex.match(/../g) ?? [], (h) => parseInt(h, 16)));
      }
      case 'array':
        return ref.arr(values(node));
      case 'record': {
        const fields = new Map();
        for (const field of node.children.filter((c) => c.type === 'field')) {
          const key = child(field, 'key');
          const name = key.type === 'identifier' ? text(key) : basicString(key);
          if (fields.has(name)) throw new Mismatch(`duplicate key ${JSON.stringify(name)}`);
          fields.set(name, value(child(field, 'value')));
        }
        return ref.rec(fields);
      }
      case 'variant': {
        const tag = text(child(node, 'tag'));
        const payload = child(node, 'payload');
        if (!payload) return ref.variant(tag);
        return ref.variant(tag, payload.type === 'arguments' ? values(payload) : [value(payload)]);
      }
      default:
        throw new Mismatch(`unexpected node ${node.type}`);
    }
  }

  return values;
}

// ── Checks ────────────────────────────────────────────────────────────

// ignoreBOM keeps a byte order mark in the text: the reference handles it.
const decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });

/** The reference's values, or its error code. */
function reference(bytes) {
  let text;
  try {
    text = decoder.decode(bytes);
  } catch {
    return { code: 'invalid-utf8' };
  }
  try {
    return { values: ref.parseAll(text) };
  } catch (e) {
    if (e?.code) return { code: e.code, reason: e.reason ?? e.message };
    throw e;
  }
}

const show = (s, n = 160) => (s.length > n ? s.slice(0, n) + '…' : s);

/** Compares tree-sitter with the reference on one data file. Returns a problem, a note, or nothing. */
async function checkData(file, bytes) {
  const out = await run(file, SCOPES.data);
  const tree = readTree(out.stdout);
  if (!tree) return { problem: `tree-sitter printed no tree (exit ${out.status}): ${show(out.stderr.trim())}` };
  const expected = reference(bytes);
  const error = broken(out, tree);
  if (expected.code !== undefined) {
    if (error) return {};
    if (SEMANTIC_DATA_CODES.has(expected.code)) return { note: `parses; the reference rejects it with ${expected.code}, which a grammar can't check` };
    return { problem: `parses, but the reference rejects it: ${expected.code} (${expected.reason})` };
  }
  if (error) return { problem: 'the reference accepts it, but the tree has an error' };
  let actual;
  try {
    actual = converter(bytes)(tree);
  } catch (e) {
    if (e instanceof Mismatch) return { problem: e.message };
    throw e;
  }
  const a = actual.map(ref.canonical);
  const b = expected.values.map(ref.canonical);
  if (a.length !== b.length) return { problem: `${a.length} values, the reference has ${b.length}` };
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return { problem: `value ${i + 1} differs:\n      tree-sitter ${show(a[i])}\n      reference   ${show(b[i])}` };
  }
  return {};
}

/** A schema file must parse without errors, unless `code` says it has a syntax error. */
async function checkSchema(file, code) {
  const out = await run(file, SCOPES.schema);
  const tree = readTree(out.stdout);
  if (!tree) return { problem: `tree-sitter printed no tree (exit ${out.status}): ${show(out.stderr.trim())}` };
  const error = broken(out, tree);
  if (code === undefined) return error ? { problem: 'the tree has an error' } : {};
  if (SYNTAX_SCHEMA_CODES.has(code)) return error ? {} : { problem: `parses, but it has a syntax error: ${code}` };
  if (EITHER_SCHEMA_CODES.has(code)) return error ? {} : { note: `parses; ${code} is a check beyond the syntax` };
  return error ? { problem: `the tree has an error, but ${code} is not a syntax error` } : { note: `parses; ${code} is a check beyond the syntax` };
}

// ── Files ─────────────────────────────────────────────────────────────

// The files git tracks or would track, so that build output and fuzzer
// leftovers (ignored files) don't count.
const tracked = execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], { cwd: repo, encoding: 'utf8', maxBuffer: 64 << 20 })
  .split('\0')
  .filter(Boolean)
  .map((rel) => join(repo, rel));

const isSchema = (path) => path.endsWith('.schema.haus') || path.endsWith('/schema.haus');
const formatOutput = /\/test-suite\/format\/.*\.(pretty|compact|minimised)$/;

const dataFiles = tracked.filter((p) => (p.endsWith('.haus') && !isSchema(p)) || formatOutput.test(p)).sort();
const schemaFiles = tracked.filter(isSchema).sort();

const groups = new Map();
const record = (group, file, result) => {
  if (!groups.has(group)) groups.set(group, { total: 0, problems: [], notes: [] });
  const g = groups.get(group);
  g.total++;
  if (result.problem) g.problems.push([file, result.problem]);
  if (result.note) g.notes.push([file, result.note]);
};

const groupOf = (path) => {
  const rel = relative(repo, path);
  if (rel.startsWith('test-suite/valid/')) return 'test-suite/valid';
  if (rel.startsWith('test-suite/invalid/')) return 'test-suite/invalid';
  if (rel.startsWith('test-suite/format/')) return 'test-suite/format';
  if (rel.startsWith('test-suite/schema/invalid/')) return 'test-suite/schema/invalid';
  if (rel.startsWith('examples/')) return isSchema(path) ? 'examples (schema)' : 'examples';
  return isSchema(path) ? 'other schema files' : 'other data files';
};

const tasks = [
  ...dataFiles.map((path) => async () => record(groupOf(path), relative(repo, path), await checkData(path, readFileSync(path)))),
  ...schemaFiles.map((path) => async () => {
    const errorFile = path.replace(/\.schema\.haus$/, '.error');
    const code = groupOf(path) === 'test-suite/schema/invalid' ? readFileSync(errorFile, 'utf8').trim() : undefined;
    record(groupOf(path), relative(repo, path), await checkSchema(path, code));
  }),
];

if (fuzzCount > 0) {
  const gen = await import(pathToFileURL(join(repo, 'fuzz/src/generate.ts')).href);
  const rng = new gen.Rng(seed);
  const dir = mkdtempSync(join(tmpdir(), 'tree-sitter-haus-'));
  const seeds = readdirSync(join(repo, 'test-suite/valid'))
    .filter((n) => n.endsWith('.haus'))
    .map((n) => readFileSync(join(repo, 'test-suite/valid', n)));
  for (let i = 0; i < fuzzCount; i++) {
    const bytes = mutate ? gen.input(rng, seeds) : new TextEncoder().encode(gen.file(rng));
    const path = join(dir, `${String(i).padStart(6, '0')}.haus`);
    writeFileSync(path, bytes);
    tasks.push(async () => {
      const result = await checkData(path, Buffer.from(bytes));
      if (result.problem) result.problem += `\n      input ${show(JSON.stringify(new TextDecoder().decode(bytes)), 400)}`;
      else unlinkSync(path);
      record(`fuzz (seed ${seed}${mutate ? ', mutated' : ''})`, path, result);
    });
  }
  tasks.cleanup = () => {
    try {
      rmdirSync(dir); // only if empty: inputs that disagreed are kept
    } catch {}
  };
}

await pool(tasks);
tasks.cleanup?.();
for (const lib of Object.values(libraries)) unlinkSync(lib);
rmdirSync(libDir);

// ── Report ────────────────────────────────────────────────────────────

let failed = false;
for (const [name, g] of [...groups].sort(([a], [b]) => a.localeCompare(b))) {
  const ok = g.total - g.problems.length;
  console.log(`${name}: ${ok}/${g.total} ok${g.notes.length ? `, ${g.notes.length} accepted for checks beyond the syntax` : ''}`);
  for (const [file, note] of verbose ? g.notes : []) console.log(`  note ${file}: ${note}`);
  for (const [file, problem] of g.problems) console.log(`  FAIL ${file}: ${problem}`);
  if (g.problems.length) failed = true;
}
if (!verbose && [...groups.values()].some((g) => g.notes.length)) console.log('(--verbose lists the files accepted for checks beyond the syntax)');
process.exit(failed ? 1 : 0);
