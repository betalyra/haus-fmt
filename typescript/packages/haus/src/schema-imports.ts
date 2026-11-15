/**
 * Fixing a schema file's imports, for editors: the known types it uses
 * without importing them, and the edits that import them.
 *
 *   type Order = { placed: Date, total: Money }
 *
 *   missingImports(text)                     // Date from std/time, Money from @haus-fmt/money
 *   importEdits(text, "std/time", ["Date"])  // inserts `import std/time (Date)` above the first type
 *
 * A known type is one of a standard module or an official extension
 * (`moduleOfType`). An existing import of the module gets the names added to
 * its list; otherwise a new import goes after the last one, or above the
 * first type (and its doc comment).
 */
import { moduleOfType, schemaOutline, type MissingImport, type SchemaOutline } from "./schema-file.js"

/** Replace [start, end) of the text with `newText`. Offsets are UTF-16, like the text's. */
export interface ImportEdit {
  readonly start: number
  readonly end: number
  readonly newText: string
}

type Import = SchemaOutline["imports"][number]

/** `@haus-fmt/money@1` is the package `@haus-fmt/money`. */
const packageOf = (module: string) => module.replace(/@[0-9]+$/, "")

/** The outline, or undefined when the file doesn't parse (the syntax error comes first). */
const outlineOf = (text: string): SchemaOutline | undefined => {
  try {
    return schemaOutline(text)
  } catch {
    return undefined
  }
}

/** Names the file defines or imports. */
const namesInScope = (outline: SchemaOutline): Set<string> =>
  new Set([...outline.types.map((t) => t.name), ...outline.imports.flatMap((i) => i.names.map((n) => n.name))])

/** The known types the file uses without importing them, once each, in order of first use. */
export function missingImports(text: string): (MissingImport & { readonly pos: number })[] {
  const outline = outlineOf(text)
  if (!outline) return []
  const seen = namesInScope(outline)
  return outline.uses.flatMap(({ name, pos }) => {
    const module = seen.has(name) ? undefined : moduleOfType(name)
    if (!module) return []
    seen.add(name)
    return [{ module, name, pos }]
  })
}

/**
 * The edits that import `names` from `module`: added to the file's import of
 * the module if it has one, else a new import. Names already in scope are
 * skipped; no edits when there is nothing to add or the file doesn't parse.
 */
export function importEdits(text: string, module: string, names: readonly string[]): ImportEdit[] {
  const outline = outlineOf(text)
  if (!outline) return []
  const inScope = namesInScope(outline)
  const wanted = [...new Set(names)].filter((n) => !inScope.has(n))
  if (wanted.length === 0) return []
  const existing = outline.imports.find((i) => packageOf(i.module) === module)
  return existing ? extendImport(text, existing, wanted) : [newImport(text, outline, `import ${module} (${wanted.join(", ")})`)]
}

/**
 * Add names to an import's list. A sorted list (two names or more) stays
 * sorted; otherwise they go at the end. A list with one name per line gets
 * one per line, with the same indentation.
 */
const extendImport = (text: string, imp: Import, wanted: readonly string[]): ImportEdit[] => {
  const names = imp.names
  const last = names[names.length - 1]!
  const lineStart = text.lastIndexOf("\n", last.pos - 1) + 1
  const indent = text.slice(lineStart, last.pos)
  const sep = /^[ \t]*$/.test(indent) && lineStart > imp.pos ? `,\n${indent}` : ", "
  const sorted = names.length > 1 && names.every((n, i) => i === 0 || names[i - 1]!.name < n.name)
  const afterLast = last.pos + last.name.length
  if (!sorted) return [{ start: afterLast, end: afterLast, newText: sep + wanted.join(sep) }]
  // Each name goes before the first listed name that sorts after it.
  const groups = new Map<number, string[]>()
  for (const name of [...wanted].sort()) {
    const at = names.find((n) => n.name > name)?.pos ?? afterLast
    groups.set(at, [...(groups.get(at) ?? []), name])
  }
  return [...groups].map(([at, group]) =>
    at === afterLast
      ? { start: at, end: at, newText: sep + group.join(sep) }
      : { start: at, end: at, newText: group.join(sep) + sep })
}

/** A new import line: after the last import, or above the first type and its doc comment, or at the end. */
const newImport = (text: string, outline: SchemaOutline, line: string): ImportEdit => {
  const lastImport = outline.imports[outline.imports.length - 1]
  if (lastImport) {
    // At the end of its line, so a comment after it stays where it is.
    const eol = text.indexOf("\n", lastImport.end)
    const at = eol === -1 ? text.length : eol
    return { start: at, end: at, newText: `\n${line}` }
  }
  const first = outline.types[0]
  if (first) return { start: first.start, end: first.start, newText: `${line}\n\n` }
  const newline = text.length > 0 && !text.endsWith("\n") ? "\n" : ""
  return { start: text.length, end: text.length, newText: `${newline}${line}\n` }
}
