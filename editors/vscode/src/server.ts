// haus language server: syntax diagnostics, quick fixes for missing imports, outline, hover with inferred
// types, formatting, and schema inference.
// Runs in its own process; the parser is the TypeScript one from the repo.
import { existsSync, readFileSync, statSync } from "node:fs"
import { dirname, isAbsolute, join, relative, sep } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import {
  checkData,
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
  missingImports,
  ModuleError,
  moduleOfType,
  parseDocument,
  parseSchemaFile,
  type ImportEdit,
  type MissingImport,
  type SchemaFile,
  type SchemaWarning,
  type HRecord,
  type HoverContext,
  type Inference,
  type Value,
} from "@haus-fmt/haus"
import { MANIFEST, schemaOptions, type NodeResolverOptions } from "@haus-fmt/haus/node"
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
 * The setting `haus.packages` of each workspace folder (sent by the client
 * as absolute paths): each path is a package directory when it has a
 * package.haus, otherwise a folder of packages.
 */
let packageSettings: Readonly<Record<string, readonly string[]>> = {}

/** The paths `haus.packages` gives for the file at `path`: those of the innermost workspace folder that has it. */
const packagesFor = (path: string): readonly string[] => {
  const contains = (folder: string) => {
    const rel = relative(folder, path)
    return rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel)
  }
  const folder = Object.keys(packageSettings).filter(contains).sort((a, b) => b.length - a.length)[0]
  return folder === undefined ? [] : packageSettings[folder]!
}

/** Parse options for the schema file at `path`: node_modules, plus the packages of `haus.packages`. */
function optionsFor(path: string) {
  const given = packagesFor(path)
  const options: NodeResolverOptions = {
    packages: given.filter((p) => existsSync(join(p, MANIFEST))),
    folders: given.filter((p) => !existsSync(join(p, MANIFEST))),
  }
  return schemaOptions(path, options)
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

const schemaCache = new Map<string, { readonly file: SchemaFile; readonly stamps: Stamps }>()
/**
 * A schema file and its imports (packages from node_modules or `haus.packages`,
 * files next to it), cached by path and text until a file it imports changes
 * (a reinstalled package, say).
 */
function compileSchema(text: string, path: string): SchemaFile {
  const key = `${path}\0${text}`
  const hit = schemaCache.get(key)
  if (hit && fresh(hit.stamps)) return hit.file
  if (schemaCache.size > 32) schemaCache.clear()
  const options = optionsFor(path)
  const stamps = new Map<string, string>()
  const file = parseSchemaFile(text, {
    ...options,
    resolver: {
      resolve(module, from) {
        const r = options.resolver!.resolve(module, from)
        stamps.set(r.key, stamp(r.key))
        if (r.package !== undefined) stamps.set(join(dirname(r.key), MANIFEST), stamp(join(dirname(r.key), MANIFEST)))
        return r
      },
    },
  })
  schemaCache.set(key, { file, stamps })
  return file
}

/** All open documents, checked again (after `haus.packages` changed). */
const validateAll = () => {
  schemaCache.clear()
  for (const document of documents.all()) validate(document)
}

connection.onNotification("haus/packages", (settings: Record<string, string[]>) => {
  // The client checked them (trust, inside the workspace folder); network paths are never used.
  packageSettings = Object.fromEntries(Object.entries(settings).map(([folder, paths]) => [folder, paths.filter((p) => !/^[\\/]{2}/.test(p))]))
  validateAll()
})

/** Errors and hints from the data file's schema. */
function schemaDiagnostics(document: TextDocument, values: Value[]): Diagnostic[] {
  const link = schemaLink(document)
  if (!link) return []
  const range = (start: number, end: number): Range => ({ start: document.positionAt(start), end: document.positionAt(end) })
  const at = range(0, 0)
  const name = link.path.split(/[\\/]/).pop()!
  const text = schemaText(link.path)
  if (text === undefined) return [{ range: at, severity: DiagnosticSeverity.Error, source: "haus", message: `schema file not found: ${link.path}` }]
  let file: SchemaFile
  try {
    file = compileSchema(text, link.path)
  } catch (e) {
    if (e instanceof ModuleError) return [{ range: at, severity: DiagnosticSeverity.Error, source: "haus", message: `haus.packages: ${e.message}` }]
    if (!(e instanceof HausSyntaxError)) throw e
    return [{ range: at, severity: DiagnosticSeverity.Error, source: "haus", message: `${name}: ${e.message}` }]
  }
  return checkData(file, link.type, values).map((issue) => ({
    range: range(issue.start, issue.end),
    severity: issue.severity === "error" ? DiagnosticSeverity.Error : DiagnosticSeverity.Hint,
    ...(issue.severity === "hint" ? { code: "not-in-schema" } : {}),
    source: `haus (${name})`,
    message: issue.message,
  }))
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
    file = compileSchema(text, link.path)
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

/** A schema file's warning: an attribute this version doesn't define, or a use of a deprecated type (struck through). */
const warningDiagnostic = (document: TextDocument) => (w: SchemaWarning): Diagnostic => ({
  range: { start: document.positionAt(w.offset), end: document.positionAt(w.end) },
  severity: w.kind === "deprecated" ? DiagnosticSeverity.Hint : DiagnosticSeverity.Warning,
  source: "haus",
  message: w.message,
  ...(w.kind === "deprecated" ? { tags: [DiagnosticTag.Deprecated] } : {}),
})

/** The code of a schema file's error for a known type used without its import; its data is the MissingImport. */
const MISSING_IMPORT = "missing-import"

function validate(document: TextDocument): void {
  const diagnostics: Diagnostic[] = []
  try {
    if (document.languageId === "haus-schema") {
      const options = document.uri.startsWith("file:") ? optionsFor(fileURLToPath(document.uri)) : {}
      const file = parseSchemaFile(document.getText(), options)
      schemas.set(document.uri, file)
      diagnostics.push(...file.warnings.map(warningDiagnostic(document)))
    }
    else {
      const { values, comments } = parseDocument(document.getText())
      parsed.set(document.uri, { values, comments, inference: infer(values) })
      diagnostics.push(...schemaDiagnostics(document, values))
    }
  } catch (e) {
    // The packages or folders of haus.packages can't be used (one was removed, say).
    if (e instanceof ModuleError) {
      diagnostics.push({ range: { start: document.positionAt(0), end: document.positionAt(0) }, severity: DiagnosticSeverity.Error, source: "haus", message: `haus.packages: ${e.message}` })
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
    return contextOf(state.values, { file: compileSchema(text, link.path), type: link.type })
  } catch (e) {
    if (!(e instanceof HausSyntaxError)) throw e
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
  const formatted = format(state.values, { source: text, comments: state.comments })
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
    return format(values, { style, source: text, comments })
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
