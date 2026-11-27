// haus language server: syntax diagnostics, quick fixes for missing imports, outline, hover with inferred
// types, formatting, and schema inference.
// Runs in its own process; the parser is the TypeScript one from the repo.
import { existsSync, readFileSync, statSync } from "node:fs"
import { dirname, isAbsolute, join, relative, sep } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import {
  checkText,
  completeAt,
  contextOf,
  format,
  HausSchemaFileError,
  HausSyntaxError,
  hoverAt,
  hoverMarkdown,
  importEdits,
  importHint,
  infer,
  inferSchema,
  MAX_ERRORS,
  compileForTool,
  HausPackageError,
  isHausError,
  missingImports,
  moduleOfType,
  parseDocument,
  schemaOutline,
  sourcesOf,
  type HausError,
  type ImportEdit,
  type MissingImport,
  type SchemaFile,
  type SchemaWarning,
  type Sources,
  type UncheckedRules,
  type HRecord,
  type HoverContext,
  type Inference,
  type Value,
} from "@haus-fmt/haus/internal"
import { MANIFEST, readSourcesSync, type ReadSourcesOptions } from "@haus-fmt/haus/node"
import {
  CodeActionKind,
  CompletionItemKind,
  createConnection,
  InsertTextFormat,
  DiagnosticSeverity,
  DiagnosticTag,
  ProposedFeatures,
  SymbolKind,
  TextDocuments,
  TextDocumentSyncKind,
  type CodeAction,
  type CompletionItem,
  type Diagnostic,
  type DocumentSymbol,
  type Hover,
  type Range,
  type TextEdit,
} from "vscode-languageserver/node"
import { TextDocument } from "vscode-languageserver-textdocument"

const connection = createConnection(ProposedFeatures.all)
const documents = new TextDocuments(TextDocument)

interface Parsed {
  values: Value[]
  comments: [number, number][]
  inference: Inference
}

/** Last successful parse per document, so outline and hover keep working while there's an error. */
const parsed = new Map<string, Parsed>()

/** Last valid schema file per `.schema.haus` document. */
const schemas = new Map<string, SchemaFile>()

connection.onInitialize(() => ({
  capabilities: {
    textDocumentSync: TextDocumentSyncKind.Incremental,
    documentSymbolProvider: true,
    hoverProvider: true,
    documentFormattingProvider: true,
    completionProvider: { triggerCharacters: ["{", ":", ",", "(", "["] },
    codeActionProvider: { codeActionKinds: [CodeActionKind.QuickFix] },
  },
}))

// ── diagnostics ──────────────────────────────────────────────

// The schema a data file is checked against: `Root` of the `.schema.haus`
// file next to it. A data file never names its schema (spec §14).
interface SchemaLink {
  readonly path: string
  readonly type: string
}

function schemaLink(document: TextDocument): SchemaLink | undefined {
  if (!document.uri.startsWith("file:")) return undefined
  const path = fileURLToPath(document.uri)
  const sibling = path.replace(/\.haus$/, ".schema.haus")
  return sibling !== path && existsSync(sibling) ? { path: sibling, type: "Root" } : undefined
}

/** The schema file's text: from the editor if it is open (unsaved changes count), else from disk. */
function schemaText(path: string): string | undefined {
  const open = documents.get(pathToFileURL(path).toString())
  if (open) return open.getText()
  return existsSync(path) ? readFileSync(path, "utf8") : undefined
}

// ── packages ─────────────────────────────────────────────────

/**
 * The settings of a workspace folder, sent by the client as real absolute
 * paths: `haus.packages` (each a package directory when it has a
 * package.haus, otherwise a folder of packages) and the build's root, the
 * folder itself unless `haus.root` gives another directory.
 */
interface FolderSettings {
  readonly packages: readonly string[]
  readonly root: string
}

/** The settings of each workspace folder, by the folder's path. */
let folderSettings: Readonly<Record<string, FolderSettings>> = {}

/** The settings for the file at `path`: those of the innermost workspace folder that has it, if any. */
const settingsFor = (path: string): FolderSettings | undefined => {
  const contains = (folder: string) => {
    const rel = relative(folder, path)
    return rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel)
  }
  const folder = Object.keys(folderSettings).filter(contains).sort((a, b) => b.length - a.length)[0]
  return folder === undefined ? undefined : folderSettings[folder]
}

/**
 * Read options for the schema file at `path`: the packages of `haus.packages`
 * (the official packages are built in; nothing is looked for, packages.md
 * §2). Its relative imports stay inside the build's root (spec §13.3, "The
 * root"): the workspace folder that has the file, or `haus.root`; a file in
 * no workspace folder has its own directory.
 */
function optionsFor(path: string, onOpen?: (path: string) => void): ReadSourcesOptions {
  const settings = settingsFor(path)
  const given = settings?.packages ?? []
  return {
    packages: given.filter((p) => existsSync(join(p, MANIFEST))),
    folders: given.filter((p) => !existsSync(join(p, MANIFEST))),
    ...(settings === undefined ? {} : { root: settings.root }),
    ...(onOpen === undefined ? {} : { onOpen }),
  }
}

/** An error reading the settings' packages or root, before any import (no place in the file). */
class SettingsError extends Error {}

/** The sources of the schema file at `path`, with the editor's `text` for it (unsaved changes count). Throws SettingsError. */
function sourcesFor(text: string, path: string, onOpen?: (path: string) => void): Sources {
  const read = readSourcesSync(path, optionsFor(path, onOpen))
  if (read._tag === "Failure") throw new SettingsError(settingsMessage(read.failure))
  return sourcesOf({ ...read.success, files: new Map([...read.success.files, [read.success.entry, text]]) })
}

/** The files a compiled schema was built from, with their modification times: it is stale when one changes. */
type Stamps = ReadonlyMap<string, string>
const stamp = (file: string): string => {
  try {
    const { mtimeMs, size } = statSync(file)
    return `${mtimeMs}:${size}`
  } catch {
    return "gone"
  }
}
const fresh = (stamps: Stamps): boolean => [...stamps].every(([file, s]) => stamp(file) === s)

/** A schema compiled for the editor: its file, and the packages whose rules it doesn't check. */
interface Compiled {
  readonly file: SchemaFile
  readonly unchecked: readonly UncheckedRules[]
}

const schemaCache = new Map<string, { readonly compiled: Compiled; readonly stamps: Stamps }>()
/**
 * A schema file and its imports (the official packages, built in; packages
 * of `haus.packages`; files next to it), compiled as tools compile
 * (packages.md §7, "Tools": third-party rules unchecked), cached by path and
 * text until a file it read changes. Throws SettingsError, or the compile's
 * HausError.
 */
function compileSchema(text: string, path: string): Compiled {
  const key = `${path}\0${text}`
  const hit = schemaCache.get(key)
  if (hit && fresh(hit.stamps)) return hit.compiled
  if (schemaCache.size > 32) schemaCache.clear()
  const stamps = new Map<string, string>()
  const sources = sourcesFor(text, path, (file) => stamps.set(file, stamp(file)))
  const result = compileForTool(sources)
  if (result._tag === "Failure") throw result.failure
  const compiled = { file: result.success.schema.file, unchecked: result.success.unchecked }
  schemaCache.set(key, { compiled, stamps })
  return compiled
}

/** A schema file that isn't on disk (an untitled document): its text alone, with the official packages. */
function compileAlone(text: string): Compiled {
  const result = compileForTool(sourcesOf({ entry: "untitled.schema.haus", files: new Map([["untitled.schema.haus", text]]), id: undefined, failures: new Map(), packages: [], folders: [] }))
  if (result._tag === "Failure") throw result.failure
  return { file: result.success.schema.file, unchecked: result.success.unchecked }
}

/** All open documents, checked again (after `haus.packages` or `haus.root` changed). */
const validateAll = () => {
  schemaCache.clear()
  for (const document of documents.all()) validate(document)
}

/**
 * An error of the settings, before any import: the build's root (`haus.root`,
 * or the workspace folder) that doesn't contain the file or isn't there, or
 * packages of `haus.packages` that can't be used.
 */
const settingsMessage = (e: HausError): string =>
  `${e.code === "import-outside-root" || e.message.startsWith("the build's root") ? "haus.root" : "haus.packages"}: ${e.message}`

/** A network path (`\\host\share`, `//host/share`): never used. */
const isNetworkPath = (path: string): boolean => /^[\\/]{2}/.test(path)

connection.onNotification("haus/settings", (settings: Record<string, FolderSettings>) => {
  // The client checked them (trust, inside the workspace folder); network paths are never used.
  folderSettings = Object.fromEntries(
    Object.entries(settings).map(([folder, s]) => [folder, { packages: s.packages.filter((p) => !isNetworkPath(p)), root: isNetworkPath(s.root) ? folder : s.root }]),
  )
  validateAll()
})

/**
 * Errors and hints from the data file's schema, and whether the data text was
 * checked with it (then its syntax error, if any, is among them: a stream is
 * read item by item, so the errors of the items before it are too, spec §14).
 */
function schemaDiagnostics(document: TextDocument): { diagnostics: Diagnostic[]; checked: boolean } {
  const link = schemaLink(document)
  if (!link) return { diagnostics: [], checked: false }
  const range = (start: number, end: number): Range => ({ start: document.positionAt(start), end: document.positionAt(end) })
  const at = range(0, 0)
  const unchecked = (message: string) => ({ diagnostics: [{ range: at, severity: DiagnosticSeverity.Error, source: "haus", message }], checked: false })
  const name = link.path.split(/[\\/]/).pop()!
  const text = schemaText(link.path)
  if (text === undefined) return unchecked(`schema file not found: ${link.path}`)
  let file: SchemaFile
  try {
    file = compileSchema(text, link.path).file
  } catch (e) {
    if (e instanceof SettingsError) return unchecked(e.message)
    if (!isHausError(e)) throw e
    return unchecked(`${name}: ${e.message}`)
  }
  const report = checkText(file, link.type, document.getText())
  const diagnostics = report.issues.map((issue): Diagnostic => ({
    range: range(issue.start, issue.end),
    severity: issue.severity === "error" ? DiagnosticSeverity.Error : DiagnosticSeverity.Hint,
    // A deprecated field or tag the data uses is struck through, at the field or the tag (spec §14);
    // other hints are fields and tags not in the schema (dotted, see extension.ts).
    ...(issue.code === "deprecated" ? { code: "deprecated", tags: [DiagnosticTag.Deprecated] } : issue.severity === "hint" ? { code: "not-in-schema" } : {}),
    // A syntax error of the data (no path) is the parser's, as without a schema.
    source: issue.path === undefined ? "haus" : `haus (${name})`,
    message: issue.message,
  }))
  // The check stops after MAX_ERRORS errors (spec §14): say so.
  const stopped: Diagnostic[] = report.stopped
    ? [{ range: at, severity: DiagnosticSeverity.Information, source: `haus (${name})`, message: `stopped after ${MAX_ERRORS} errors: fix these to see the rest` }]
    : []
  return { diagnostics: [...diagnostics, ...stopped], checked: true }
}

// ── completion ───────────────────────────────────────────────

connection.onCompletion(({ textDocument, position }): CompletionItem[] => {
  const document = documents.get(textDocument.uri)
  if (!document || document.languageId !== "haus") return []
  const link = schemaLink(document)
  const text = link && schemaText(link.path)
  if (!link || text === undefined) return []
  let file: SchemaFile
  try {
    file = compileSchema(text, link.path).file
  } catch {
    return []
  }
  const kinds = { field: CompletionItemKind.Field, tag: CompletionItemKind.EnumMember, value: CompletionItemKind.Value }
  return completeAt(file, link.type, document.getText(), document.offsetAt(position)).map((c) => ({
    label: c.label,
    kind: kinds[c.kind],
    detail: c.detail,
    insertText: c.insertText,
    insertTextFormat: InsertTextFormat.Snippet,
    sortText: c.sortText,
    // A tag is inserted with its payload; filter on the bare name.
    filterText: c.label.replace(/[ ({].*$/, ""),
  }))
})

/** A schema file's warning: an attribute this version doesn't define, a case with no schema-based JSON form, or a use of a deprecated type (struck through). */
const warningDiagnostic = (document: TextDocument) => (w: SchemaWarning): Diagnostic => ({
  range: { start: document.positionAt(w.offset), end: document.positionAt(w.end) },
  severity: w.kind === "deprecated" ? DiagnosticSeverity.Hint : DiagnosticSeverity.Warning,
  source: "haus",
  message: w.message,
  ...(w.kind === "deprecated" ? { tags: [DiagnosticTag.Deprecated] } : {}),
})

/**
 * At each import of a package whose rules the editor has no implementation
 * of (not an official package: those are built in), a hint with the code
 * `missing-codec` (packages.md §7, "Tools").
 */
const uncheckedDiagnostics = (document: TextDocument, unchecked: readonly UncheckedRules[]): Diagnostic[] => {
  if (unchecked.length === 0) return []
  const byName = new Map(unchecked.map((u) => [u.name, u.rules]))
  return schemaOutline(document.getText()).imports.flatMap((imp) => {
    const name = imp.module.replace(/@[0-9]+$/, "")
    const rules = byName.get(name)
    if (rules === undefined) return []
    return [{
      range: { start: document.positionAt(imp.pos), end: document.positionAt(imp.end) },
      severity: DiagnosticSeverity.Hint,
      source: "haus",
      code: "missing-codec",
      message: `the rules of ${name} (${rules}) are not checked here`,
    }]
  })
}

/** The code of a schema file's error for a known type used without its import; its data is the MissingImport. */
const MISSING_IMPORT = "missing-import"

function validate(document: TextDocument): void {
  const diagnostics: Diagnostic[] = []
  try {
    if (document.languageId === "haus-schema") {
      const text = document.getText()
      const compiled = document.uri.startsWith("file:") ? compileSchema(text, fileURLToPath(document.uri)) : compileAlone(text)
      schemas.set(document.uri, compiled.file)
      diagnostics.push(...compiled.file.warnings.map(warningDiagnostic(document)))
      diagnostics.push(...uncheckedDiagnostics(document, compiled.unchecked))
    }
    else {
      const fromSchema = schemaDiagnostics(document)
      try {
        const { values, comments } = parseDocument(document.getText())
        parsed.set(document.uri, { values, comments, inference: infer(values) })
      } catch (e) {
        // Checked with the schema: the syntax error is among its diagnostics, after those of the items before it.
        if (!(e instanceof HausSyntaxError) || !fromSchema.checked) throw e
      }
      diagnostics.push(...fromSchema.diagnostics)
    }
  } catch (e) {
    // The packages or folders of haus.packages can't be used (one was removed, say), the root doesn't contain the file,
    // or an error of the package layer with no place in the file (a package's manifest, two packages with one name).
    if (e instanceof SettingsError || e instanceof HausPackageError) {
      diagnostics.push({ range: { start: document.positionAt(0), end: document.positionAt(0) }, severity: DiagnosticSeverity.Error, source: "haus", message: e.message })
      void connection.sendDiagnostics({ uri: document.uri, diagnostics })
      return
    }
    if (!(e instanceof HausSyntaxError)) throw e
    // Offsets are UTF-16, like LSP positions; highlight the character at the error (the name, for a missing import).
    const missing = e instanceof HausSchemaFileError ? e.missingImport : undefined
    const start = document.positionAt(e.offset)
    const end = document.positionAt(Math.min(e.offset + (missing?.name.length ?? 1), document.getText().length))
    diagnostics.push({
      range: { start, end },
      severity: DiagnosticSeverity.Error,
      source: "haus",
      message: e.reason,
      ...(missing ? { code: MISSING_IMPORT, data: missing } : {}),
    })
  }
  void connection.sendDiagnostics({ uri: document.uri, diagnostics })
}

documents.onDidChangeContent(({ document }) => {
  validate(document)
  // A changed schema: check the open data files again.
  if (document.languageId === "haus-schema") {
    for (const other of documents.all()) if (other.languageId === "haus") validate(other)
  }
})

documents.onDidClose(({ document }) => {
  parsed.delete(document.uri)
  schemas.delete(document.uri)
  void connection.sendDiagnostics({ uri: document.uri, diagnostics: [] })
})

// ── outline ──────────────────────────────────────────────────

connection.onDocumentSymbol(({ textDocument }) => {
  const doc = documents.get(textDocument.uri)
  const schema = schemas.get(textDocument.uri)
  if (doc && schema) {
    return schema.definitions.map((d): DocumentSymbol => {
      const start = doc.offsetAt(doc.positionAt(d.offset))
      const range = { start: doc.positionAt(start), end: doc.positionAt(start + "type ".length + d.name.length) }
      return { name: d.name, detail: d.params.join(" "), kind: SymbolKind.Class, range, selectionRange: range }
    })
  }
  const values = parsed.get(textDocument.uri)?.values
  if (!doc || !values) return []
  const range = (start = 0, end = start): Range => ({ start: doc.positionAt(start), end: doc.positionAt(end) })

  const symbol = (name: string, v: Value, nameSpan?: readonly [number, number]): DocumentSymbol => {
    const full = range(nameSpan?.[0] ?? v.start, v.end)
    return {
      name,
      detail: detail(v),
      kind: symbolKind(v),
      range: full,
      selectionRange: nameSpan ? range(nameSpan[0], nameSpan[1]) : range(v.start, v.end),
      children: children(v),
    }
  }

  const fieldSymbols = (r: HRecord) => [...r.fields].map(([k, x]) => symbol(k, x, r.keySpans?.get(k)))

  const children = (v: Value): DocumentSymbol[] => {
    switch (v.kind) {
      case "record":
        return fieldSymbols(v)
      case "array":
        return v.items.map((x, i) => symbol(`[${i}]`, x))
      case "variant": {
        const [first] = v.args
        if (v.args.length === 1 && first?.kind === "record") return fieldSymbols(first)
        return v.args.map((x, i) => symbol(`[${i}]`, x))
      }
      default:
        return []
    }
  }

  // A single record document shows its fields at the top level.
  const [only] = values
  if (values.length === 1 && only?.kind === "record") return fieldSymbols(only)
  return values.map((v, i) => symbol(v.kind === "variant" ? `[${i}] ${v.tag}` : `[${i}]`, v))
})

const symbolKind = (v: Value): SymbolKind =>
  ({ record: SymbolKind.Object, array: SymbolKind.Array, string: SymbolKind.String, bytes: SymbolKind.Array, number: SymbolKind.Number, variant: SymbolKind.EnumMember })[v.kind]

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`

const detail = (v: Value): string => {
  switch (v.kind) {
    case "number": return v.text
    case "string": return JSON.stringify(v.value.length > 40 ? v.value.slice(0, 40) + "…" : v.value)
    case "bytes": return plural(v.bytes.length, "byte")
    case "array": return plural(v.items.length, "item")
    case "record": return plural(v.fields.size, "field")
    case "variant": return v.args.length === 0 ? v.tag : `${v.tag}(…)`
  }
}

// ── hover ────────────────────────────────────────────────────

connection.onHover(({ textDocument, position }): Hover | null => {
  const doc = documents.get(textDocument.uri)
  if (doc?.languageId === "haus-schema") {
    // A type name: show its definition, or where a standard or extension type comes from.
    const text = doc.getText()
    const offset = doc.offsetAt(position)
    let start = offset
    let end = offset
    while (start > 0 && /[A-Za-z0-9_]/.test(text[start - 1]!)) start--
    while (end < text.length && /[A-Za-z0-9_]/.test(text[end]!)) end++
    const name = text.slice(start, end)
    const d = schemas.get(textDocument.uri)?.definition(name)
    if (d) return { contents: { kind: "markdown", value: `\`\`\`haus-schema\n${d.source}\n\`\`\`` } }
    const module = moduleOfType(name)
    if (!module) return null
    const missing = missingImports(text).some((m) => m.name === name)
    const value = `\`${name}\` is from \`${module}\`${missing ? `: ${importHint({ module, name })}` : ""}`
    return { contents: { kind: "markdown", value }, range: { start: doc.positionAt(start), end: doc.positionAt(end) } }
  }
  const state = parsed.get(textDocument.uri)
  if (!doc || !state) return null
  const info = hoverAt(hoverState(doc, state), doc.offsetAt(position))
  if (!info) return null
  return {
    contents: { kind: "markdown", value: hoverMarkdown(info) },
    range: { start: doc.positionAt(info.start), end: doc.positionAt(info.end) },
  }
})

/** The hover context of a data file: its values, their inferred types and, with a schema, the schema's types. */
function hoverState(doc: TextDocument, state: Parsed): HoverContext {
  const link = schemaLink(doc)
  const text = link && schemaText(link.path)
  if (!link || text === undefined) return { values: state.values, inference: state.inference }
  try {
    return contextOf(state.values, { file: compileSchema(text, link.path).file, type: link.type })
  } catch (e) {
    if (!(e instanceof SettingsError) && !isHausError(e)) throw e
    return { values: state.values, inference: state.inference }
  }
}

// ── quick fixes ──────────────────────────────────────────────

/**
 * For a missing import: add it (to the module's import if there is one), and
 * when more types of that module are missing, add them all at once.
 */
connection.onCodeAction(({ textDocument, context }): CodeAction[] => {
  const doc = documents.get(textDocument.uri)
  if (!doc || doc.languageId !== "haus-schema") return []
  const text = doc.getText()
  const action = (title: string, edits: readonly ImportEdit[], diagnostic: Diagnostic, isPreferred: boolean): CodeAction[] =>
    edits.length === 0 ? [] : [{
      title,
      kind: CodeActionKind.QuickFix,
      diagnostics: [diagnostic],
      isPreferred,
      edit: {
        changes: {
          [doc.uri]: edits.map((e) => ({ range: { start: doc.positionAt(e.start), end: doc.positionAt(e.end) }, newText: e.newText })),
        },
      },
    }]
  return context.diagnostics.flatMap((d) => {
    if (d.code !== MISSING_IMPORT) return []
    const { module, name } = d.data as MissingImport
    const all = missingImports(text).filter((m) => m.module === module).map((m) => m.name)
    return [
      ...action(`Import ${name} from ${module}`, importEdits(text, module, [name]), d, true),
      ...(all.length > 1 ? action(`Add all missing imports from ${module} (${all.join(", ")})`, importEdits(text, module, all), d, false) : []),
    ]
  })
})

// ── formatting ───────────────────────────────────────────────

/**
 * Whether the data file's schema (the `Root` of the `.schema.haus` file next
 * to it) is a `Stream`: then it is formatted as a stream, with a comma after
 * a single item too (spec §11). False without a schema, or one that doesn't
 * compile (its errors are shown as diagnostics).
 */
function isStream(document: TextDocument): boolean {
  const link = schemaLink(document)
  const text = link && schemaText(link.path)
  if (!link || text === undefined) return false
  try {
    return compileSchema(text, link.path).file.definition(link.type)?.template.stream === true
  } catch {
    return false
  }
}

connection.onDocumentFormatting(({ textDocument }): TextEdit[] => {
  const doc = documents.get(textDocument.uri)
  if (!doc || doc.languageId === "haus-schema") return []
  const text = doc.getText()
  let state: { values: Value[]; comments: [number, number][] }
  try {
    state = parseDocument(text)
  } catch {
    return [] // syntax errors are already shown as diagnostics
  }
  const formatted = format(state.values, { source: text, comments: state.comments, stream: isStream(doc) })
  if (formatted === text) return []
  return [{ range: { start: doc.positionAt(0), end: doc.positionAt(text.length) }, newText: formatted }]
})

/** The whole document in the given layout; null on syntax errors. Comments are kept in pretty only. */
connection.onRequest("haus/print", ({ uri, style }: { uri: string; style: "pretty" | "compact" | "minimised" }): string | null => {
  const doc = documents.get(uri)
  if (!doc) return null
  const text = doc.getText()
  try {
    const { values, comments } = parseDocument(text)
    return format(values, { style, source: text, comments, stream: isStream(doc) })
  } catch {
    return null
  }
})

// ── schema inference ─────────────────────────────────────────

connection.onRequest("haus/inferSchema", ({ uri }: { uri: string }): string | null => {
  const state = parsed.get(uri)
  return state ? inferSchema(state.values) : null
})

/** What the prelude says a tag means. */
documents.listen(connection)
connection.listen()
