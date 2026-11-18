/**
 * "In your code": what `import data from "./data.haus"` gives a program,
 * one line per top-level field (or stream item): its type, its value, and a
 * note where haus differs from JSON.
 *
 * With a schema the types come from the schema, printed as the
 * @haus-fmt/import declarations resolve (`Option<string>`, not
 * `Option$.Option<string>`; without codecs, `Haus$.Lookup<…, string>` is
 * `string`). Without one, both targets give the plain view, typed by what the
 * data has in common (the plain declarations of the data).
 */
import type { Case, Field, SchemaFile, Type, Value } from "../../../../typescript/packages/haus/src/index.ts";
import { Secret } from "../../../../typescript/packages/haus/src/index.ts";
import { plainDeclarations } from "../../../../typescript/packages/haus/src/plain.ts";
import { prettyType, splitTop } from "./pretty";

export type Target = "plain" | "effect";

export interface CodeInput {
  readonly values: readonly Value[];
  /** The data's text, for the plain declarations. */
  readonly data: string;
  /** What the program gets: one value, or an array for a stream (the plain view when the data doesn't fit the schema). */
  readonly program: unknown;
  /** The schema the data is checked against, if any. */
  readonly schema?: { readonly file: SchemaFile; readonly type: string };
  /** Whether the data fits the schema (only then does the import succeed). */
  readonly fits: boolean;
  /** The first error checking the data against the schema, with its position. */
  readonly error?: string;
}

/** Fits the output panel beside the editors. */
const WIDTH = 66;
/** Items of a stream shown before "… and n more". */
const SHOWN_ITEMS = 6;
/** Values longer than this are cut. */
const VALUE_ROOM = 56;

const KEY = /^[A-Za-z_$][A-Za-z0-9_$]*$/;
const prop = (k: string) => (KEY.test(k) ? k : JSON.stringify(k));
const access = (k: string) => (KEY.test(k) ? `.${k}` : `[${JSON.stringify(k)}]`);
const isEnum = (cases: readonly Case[]) => cases.length > 0 && cases.every((c) => c.payload.kind === "none");
/** A type with its references followed (a few steps: recursive types point back at themselves). */
const deref = (t: Type): Type => {
  for (let i = 0; i < 8 && t.kind === "ref"; i++) t = t.instance.body;
  return t;
};

// ── types ────────────────────────────────────────────────────

/** A schema type as TypeScript, the way the target's declarations resolve it. */
function printType(t: Type, target: Target): string {
  const p = (x: Type) => printType(x, target);
  const fields = (fs: readonly Field[]) => fs.map((f) => `${prop(f.key)}${f.optional ? "?" : ""}: ${p(f.type)}`);
  const record = (fs: readonly Field[]) => (fs.length === 0 ? "{}" : `{ ${fields(fs).join("; ")} }`);
  switch (t.kind) {
    case "builtin":
      switch (t.name) {
        case "String": case "Decimal": return "string";
        case "Bytes": return "Uint8Array";
        case "Bool": return "boolean";
        case "Int": case "Int64": case "UInt64": return "bigint";
        case "Any": return "Value";
        default: return "number";
      }
    case "std": return "string";
    case "array": return `ReadonlyArray<${p(t.item)}>`;
    case "map": return target === "effect" ? `{ [key: string]: ${p(t.value)} }` : `ReadonlyMap<string, ${p(t.value)}>`;
    case "maybe": return target === "effect" ? `Option<${p(t.item)}>` : `Maybe<${p(t.item)}>`;
    case "secret": return target === "effect" ? `Redacted<${p(t.item)}>` : `Secret<${p(t.item)}>`;
    case "record": return record(t.fields);
    case "variant": {
      if (t.cases.length === 0) return t.open ? "string | Unknown" : "never";
      // The plain target makes an open enum tagged objects (an unknown tag needs one); Effect keeps the strings.
      const cases = isEnum(t.cases) && (!t.open || target === "effect")
        ? t.cases.map((c) => JSON.stringify(c.tag))
        : t.cases.map((c) => {
          const tag = `_tag: ${JSON.stringify(c.tag)}`;
          switch (c.payload.kind) {
            case "none": return `{ ${tag} }`;
            case "record": {
              const fs = c.payload.record.fields;
              return fs.some((f) => f.key === "_tag") ? `{ ${tag}; value: ${record(fs)} }` : `{ ${[tag, ...fields(fs)].join("; ")} }`;
            }
            case "positional": return `{ ${tag}; values: [${c.payload.items.map(p).join(", ")}] }`;
          }
        });
      return [...cases, ...(t.open ? ["Unknown"] : [])].join(" | ");
    }
    case "ref": {
      const args = t.instance.args;
      return args.length ? `${t.instance.name}<${args.map(p).join(", ")}>` : t.instance.name;
    }
    case "param": return t.name;
  }
}

/** Where a schema type maps to something JSON doesn't have, one short line on it. */
function typeNote(t: Type, target: Target, depth = 0): string | undefined {
  const effect = target === "effect";
  switch (t.kind) {
    case "builtin":
      switch (t.name) {
        case "Int": return "Int: exact at any size, so a bigint";
        case "Int64": case "UInt64": return `${t.name}: too big for a number, so a bigint`;
        case "Decimal": return "Decimal: its exact text, never 19.899999…";
        default: return undefined;
      }
    case "std": return `${t.name}: the text as written`;
    case "maybe": return effect ? "Maybe: Effect's Option, never null" : "Maybe: None or Some, never null";
    case "secret": return effect ? "Secret: Effect's Redacted, hidden in logs" : "Secret: shows <redacted> in logs; .expose() reads it";
    case "map": return effect ? undefined : "a map: a ReadonlyMap";
    case "array": {
      const inner = depth < 2 ? typeNote(t.item, target, depth + 1) : undefined;
      return inner && `each item: ${inner}`;
    }
    case "variant":
      if (isEnum(t.cases)) return t.open ? "open: tags added later arrive as Unknown" : "closed: only these tags";
      if (t.open) return "open: switch on ._tag; new tags arrive as Unknown";
      return t.cases.length === 1 ? `always ${t.cases[0]!.tag}: a tagged record` : "a variant: switch on ._tag";
    case "ref": return depth < 2 && t.instance.args.length === 0 ? typeNote(t.instance.body, target, depth + 1) : undefined;
    default: return undefined;
  }
}

/** The same for a value without a schema: what the plain view made of it. */
function valueNote(v: Value | undefined, depth = 0): string | undefined {
  if (!v) return undefined;
  switch (v.kind) {
    case "number": return /^-?\d+$/.test(v.text) ? "an Int: exact at any size, so a bigint" : "a Decimal: its exact text, never 19.899999…";
    case "array": {
      const inner = depth < 2 ? valueNote(v.items[0], depth + 1) : undefined;
      return inner && `each item: ${inner}`;
    }
    case "variant":
      if (v.tag === "True" || v.tag === "False") return undefined;
      if (v.tag === "None" || v.tag === "Some") return "None or Some: there is no null";
      if (v.args.length === 1 && v.args[0]!.kind === "string" && /^[A-Z]/.test(v.tag) && TIME_TAGS.has(v.tag)) return `${/^[AEIOU]/.test(v.tag) ? "an" : "a"} ${v.tag}: the text as written`;
      return v.args.length === 0 ? "a tag: just its name" : "a variant: switch on ._tag";
    default: return undefined;
  }
}

const TIME_TAGS = new Set(["Date", "Time", "DateTime", "Instant", "ZonedDateTime", "Duration", "YearMonth", "TimeZone"]);

/** The plain declarations' type of the data (one item's, for a stream), without `readonly`. */
function plainType(data: string): string {
  const ts = plainDeclarations(data, "data.haus").replace(/\/\*\*[\s\S]*?\*\/\n/g, "");
  const m = /^declare const data: (.*);$/m.exec(ts);
  const type = (m?.[1] ?? "unknown").replace(/(?<![\w"])readonly (?!\[)/g, "").replace(/readonly \[/g, "[");
  return /^ReadonlyArray<.*>$/.test(type) ? type.slice("ReadonlyArray<".length, -1) : type;
}

/** The fields of a printed object type, `{ a: T; b?: U }`, or undefined if it isn't one. */
function printedFields(type: string): Map<string, string> | undefined {
  if (!(type.startsWith("{ ") && type.endsWith(" }"))) return undefined;
  const out = new Map<string, string>();
  for (const f of splitTop(type.slice(2, -2), "; ")) {
    const m = /^("(?:[^"\\]|\\.)*"|[A-Za-z_$][\w$]*)\??: ([\s\S]*)$/.exec(f);
    if (!m) return undefined;
    out.set(m[1]!.startsWith('"') ? (JSON.parse(m[1]!) as string) : m[1]!, m[2]!);
  }
  return out;
}

// ── values ───────────────────────────────────────────────────

/** A value as a TypeScript expression, shaped by its schema type where there is one. */
function printValue(v: unknown, t: Type | undefined, target: Target): string {
  const tt = t && deref(t);
  const effect = target === "effect";
  if (tt?.kind === "maybe" && effect && isTagged(v)) {
    return v._tag === "None" ? "Option.none()" : `Option.some(${printValue((v as { value?: unknown }).value, tt.item, target)})`;
  }
  if (v instanceof Secret) return effect ? "Redacted(<redacted>)" : "Secret(<redacted>)";
  if (typeof v === "bigint") return `${v}n`;
  if (typeof v === "string") return JSON.stringify(v);
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  if (v === undefined) return "undefined";
  if (v === null) return "null";
  if (v instanceof Uint8Array) return `Uint8Array [${[...v].join(", ")}]`;
  if (v instanceof Map) {
    const item = tt?.kind === "map" ? tt.value : undefined;
    const entries = [...v].map(([k, x]) => [String(k), printValue(x, item, target)] as const);
    return effect
      ? object(entries)
      : `new Map([${entries.map(([k, x]) => `[${JSON.stringify(k)}, ${x}]`).join(", ")}])`;
  }
  if (Array.isArray(v)) {
    const item = tt?.kind === "array" ? tt.item : undefined;
    return `[${v.map((x) => printValue(x, item, target)).join(", ")}]`;
  }
  if (typeof v === "object") {
    const o = v as Record<string, unknown>;
    // A tag the open variant doesn't know, with its raw haus value.
    if (o._tag === "@unknown" && typeof o.tag === "string") return `{ _tag: "@unknown", tag: ${JSON.stringify(o.tag)}, value: … }`;
    // Effect gives an open enum's known tags as strings.
    if (effect && tt?.kind === "variant" && isEnum(tt.cases) && isTagged(o) && Object.keys(o).length === 1) return JSON.stringify(o._tag);
    // A positional case: its values by position.
    const c = tt?.kind === "variant" && isTagged(o) ? tt.cases.find((x) => x.tag === o._tag) : undefined;
    if (c?.payload.kind === "positional" && Array.isArray(o.values)) {
      const items = c.payload.items;
      return object([["_tag", JSON.stringify(o._tag)], ["values", `[${o.values.map((x, i) => printValue(x, items[i], target)).join(", ")}]`]]);
    }
    const types = fieldTypes(o, tt);
    return object(Object.entries(o).map(([k, x]) => [k, printValue(x, types?.get(k), target)] as const));
  }
  return String(v);
}

const isTagged = (v: unknown): v is { readonly _tag: string } =>
  typeof v === "object" && v !== null && typeof (v as { _tag?: unknown })._tag === "string";

const object = (entries: readonly (readonly [string, string])[]) =>
  entries.length === 0 ? "{}" : `{ ${entries.map(([k, x]) => `${prop(k)}: ${x}`).join(", ")} }`;

/** The types of an object's fields: a record's, or the fields of the variant case it is. */
function fieldTypes(o: Record<string, unknown>, t: Type | undefined): Map<string, Type> | undefined {
  if (t?.kind === "record") return new Map(t.fields.map((f) => [f.key, f.type]));
  if (t?.kind === "variant" && isTagged(o)) {
    const c = t.cases.find((x) => x.tag === o._tag);
    if (c?.payload.kind === "record") {
      // A payload with a field `_tag` is nested in `value`.
      if (c.payload.record.fields.some((f) => f.key === "_tag")) return new Map([["value", c.payload.record]]);
      return new Map(c.payload.record.fields.map((f) => [f.key, f.type]));
    }
  }
  return undefined;
}

const cut = (s: string, room: number) => (s.length <= room ? s : `${s.slice(0, room - 2)} …`);

// ── lines ────────────────────────────────────────────────────

interface Row {
  readonly label: string;
  readonly type?: string;
  readonly value?: string;
  readonly note?: string;
}

/**
 * Rows as commented TypeScript, labels aligned:
 *
 *   data.born  // bigint · 1815n
 *              //   ↳ Int: exact at any size, so a bigint
 */
function render(rows: readonly Row[]): string {
  const w = Math.min(Math.max(...rows.map((r) => r.label.length)), 22);
  const pad = " ".repeat(w);
  const room = WIDTH - w - 4;
  const out: string[] = [];
  for (const r of rows) {
    const head = `${r.label.padEnd(w)}  // `;
    const more = `${pad}  //   `;
    const value = r.value === undefined ? undefined : cut(r.value, Math.min(VALUE_ROOM, room - 2));
    // A literal type that is the value itself (`"Done"`) is said once.
    const type = r.type === r.value ? undefined : r.type;
    if (type !== undefined && value !== undefined && `${type} · ${value}`.length <= room) out.push(`${head}${type} · ${value}`);
    else {
      if (type !== undefined) {
        // One line while it fits; then a field or union member per line.
        const lines = (type.length <= room ? type : prettyType(type, "", room).replace(/^\n\s*/, "")).split("\n");
        out.push(`${head}${lines[0]}`, ...lines.slice(1).map((l) => `${pad}  // ${l}`));
      }
      if (value !== undefined) out.push(type === undefined ? `${head}${value}` : `${more}· ${value}`);
    }
    if (r.note) out.push(`${more}↳ ${r.note}`);
  }
  return out.join("\n");
}

/** One row per field of a record, or one for the whole value. */
function rowsOf(label: string, program: unknown, value: Value | undefined, type: { schema?: Type; printed?: string }, target: Target): Row[] {
  const t = type.schema && deref(type.schema);
  const isRecord = typeof program === "object" && program !== null && !Array.isArray(program) && !(program instanceof Map) && !(program instanceof Uint8Array) && !(program instanceof Secret) && !isTagged(program);
  if (isRecord && t?.kind === "record") {
    const o = program as Record<string, unknown>;
    return t.fields.map((f) => ({
      label: `${label}${access(f.key)}`,
      type: `${printType(f.type, target)}${f.optional ? " | undefined" : ""}`,
      value: f.key in o ? printValue(o[f.key], f.type, target) : "undefined",
      note: typeNote(f.type, target),
    }));
  }
  // A record case of a variant: its tag, then its fields.
  if (t?.kind === "variant" && isTagged(program)) {
    const o = program as Record<string, unknown> & { _tag: string };
    const c = t.cases.find((x) => x.tag === o._tag);
    if (c?.payload.kind === "record" && !c.payload.record.fields.some((f) => f.key === "_tag")) {
      const tags = t.cases.map((x) => JSON.stringify(x.tag)).join(" | ");
      const note = typeNote(t, target);
      return [
        { label: `${label}._tag`, type: tags, value: JSON.stringify(o._tag), ...(note ? { note } : {}) },
        ...rowsOf(label, Object.fromEntries(Object.entries(o).filter(([k]) => k !== "_tag")), undefined, { schema: c.payload.record }, target),
      ];
    }
  }
  // Without a schema: the fields of the printed type, for a record or a record case.
  const payload = value?.kind === "variant" && value.args.length === 1 && value.args[0]!.kind === "record" ? value.args[0] : value;
  const fields = (isRecord || isTagged(program)) && type.printed !== undefined ? printedFields(type.printed) : undefined;
  if (fields && payload?.kind === "record") {
    const o = program as Record<string, unknown>;
    return [...fields].map(([k, ft]) => ({
      label: `${label}${access(k)}`,
      type: ft,
      value: k in o ? printValue(o[k], undefined, target) : "undefined",
      ...(() => {
        const note = valueNote(payload.fields.get(k));
        return note ? { note } : {};
      })(),
    }));
  }
  return [{
    label,
    ...(type.schema ? { type: printType(type.schema, target) } : type.printed !== undefined ? { type: type.printed } : {}),
    value: printValue(program, type.schema, target),
    ...(() => {
      const note = type.schema ? typeNote(type.schema, target) : valueNote(value);
      return note ? { note } : {};
    })(),
  }];
}

/** A stream: its item type once, then the first items. */
function streamRows(items: readonly unknown[], values: readonly Value[], type: { schema?: Type; printed?: string }, target: Target, how: How): Row[] {
  const item = type.schema ? printType(type.schema, target) : type.printed ?? "unknown";
  const count = items.length === 1 ? "1 item" : `${items.length} items`;
  const rows: Row[] = how === "file"
    ? [{ label: "data", type: `ReadonlyArray<${item}>`, note: `a stream: ${count}, one per value in the file` }]
    : [{ label: "item", type: item, note: `one at a time, as they arrive (${count} here)` }];
  items.slice(0, SHOWN_ITEMS).forEach((x, i) => {
    const note = type.schema ? undefined : valueNote(values[i]);
    rows.push({ label: how === "file" ? `data[${i}]` : `#${i}`, value: printValue(x, type.schema, target), ...(note ? { note } : {}) });
  });
  if (items.length > SHOWN_ITEMS) rows.push({ label: "", value: `… and ${items.length - SHOWN_ITEMS} more` });
  return rows;
}

/** How the program gets the data: a file it imports, or text it receives and parses. */
export type How = "file" | "parse";

const IMPORT = `import data from "./data.haus";`;

/** The plain view of the data, as both targets give it without a schema. */
function plainView(input: CodeInput, target: Target, how: How = "file"): string {
  const printed = plainType(input.data);
  const stream = input.values.length !== 1;
  const rows = stream
    ? streamRows(input.program as unknown[], input.values, { printed }, target, how)
    : rowsOf("data", input.program, input.values[0], { printed }, target);
  return render(rows);
}

/** The values alone: what parsing without a schema gives, typed `unknown`. */
function untypedView(input: CodeInput): string {
  const stream = input.values.length !== 1;
  const items = stream ? (input.program as unknown[]) : [input.program];
  const rows: Row[] = items.slice(0, SHOWN_ITEMS).map((x, i) => ({ label: stream ? `data[${i}]` : "data", value: printValue(x, undefined, "plain") }));
  if (items.length > SHOWN_ITEMS) rows.push({ label: "", value: `… and ${items.length - SHOWN_ITEMS} more` });
  return render(rows);
}

/** The schema's root type and whether the file is a stream of it. */
const rootOf = (schema: NonNullable<CodeInput["schema"]>) => {
  const def = schema.file.definition(schema.type);
  return { body: def?.template.body, stream: def?.template.stream ?? false };
};

/** The data typed by the schema: a row per field, or the stream's items. */
function typedView(input: CodeInput, target: Target, how: How): string {
  const { body, stream } = rootOf(input.schema!);
  const type = body ? { schema: body } : {};
  return render(stream
    ? streamRows(input.program as unknown[], input.values, type, target, how)
    : rowsOf("data", input.program, input.values[0], type, target));
}

/** What `import data from "./data.haus"` gives. */
function fileImport(input: CodeInput, target: Target): string {
  const { schema } = input;
  const use = "// For files that ship with your code: config, fixtures, seed data.";
  if (!schema) {
    const effect = target === "effect"
      ? ["", "// Without a schema the Effect target gives the same values as plain", "// TypeScript. Add one (Infer a schema → Use as schema) for Effect types."]
      : [];
    return [`${IMPORT}  // types inferred from the data`, use, ...effect, "", plainView(input, target)].join("\n");
  }
  if (!input.fits) {
    return [
      IMPORT,
      "",
      `// data.haus doesn't match ${schema.type} yet, so this import would throw.`,
      "// Fix the errors on the left. Without the schema, you would get:",
      "",
      plainView(input, "plain"),
    ].join("\n");
  }
  const view = typedView(input, target, "file");
  // Effect changes the values only for Maybe, Secret, maps and open enums: say so when there are none.
  const same = target === "effect" && view === typedView(input, "plain", "file")
    ? ["", "// Here the values are the same as plain TypeScript: Effect differs for", "// Maybe (Option), Secret (Redacted) and maps. And in parsing: try Parse."]
    : [];
  return [`${IMPORT}  // typed by data.schema.haus`, use, ...same, "", view].join("\n");
}

/** What parsing text received at runtime gives. */
function parsed(input: CodeInput, target: Target): string {
  const { schema } = input;
  const use = "// For data you receive: a request body, a message, an upload.";
  if (!schema) {
    if (target === "effect") {
      const stream = input.values.length !== 1;
      return [
        `import * as Haus from "@haus-fmt/effect";`,
        "",
        use,
        stream
          ? "const items = Haus.decodeStream(Haus.Any)(response.body!);"
          : "const data = yield* Haus.decode(Haus.Any)(text);",
        stream
          ? "// Stream<Value, HausError>: each item a parsed haus Value"
          : "// Value: the parsed haus value, syntax checked, nothing more",
        "",
        "// Effect gives data a type through a schema: a schema file",
        "// (Infer a schema → Use as schema), or an Effect Schema you",
        "// write, e.g. Schema.Struct({ name: Schema.String }).",
      ].join("\n");
    }
    return [
      `import { parsePlain } from "@haus-fmt/haus";`,
      "",
      use,
      "const data = parsePlain(text);  // unknown",
      "",
      "// Nothing says what received data is, so TypeScript only knows",
      "// `unknown`. Give it a schema (Infer a schema → Use as schema),",
      "// or any Standard Schema (Zod, Valibot, …) with parseWith.",
      "",
      untypedView(input),
    ].join("\n");
  }
  const { stream, body } = rootOf(schema);
  const name = schema.type;
  const item = body ? printType(body, target) : name;
  const head = target === "effect"
    ? [`import * as Haus from "@haus-fmt/effect";`, `import { ${name} } from "./data.schema.haus";  // an Effect schema`, "", use]
    : [`import * as h from "@haus-fmt/haus/schema";`, `import { ${name} } from "./data.schema.haus";`, "", use];
  const call = target === "effect"
    ? stream
      ? [`const items = Haus.decodeStream(${name})(response.body!);`, "// Stream<Item, HausError>: each item checked as it arrives"]
      : [`const data = yield* Haus.decode(${name})(text);`, "// fails with HausParseError | HausSchemaError, never throws"]
    : stream
      ? [`for await (const item of h.decodeStream(${name}, response.body!)) { … }`, "// each item checked as it arrives; throws HausDecodeError"]
      : [`const data = h.parse(${name}, text);`, "// throws HausDecodeError on a mismatch, with the path"];
  if (!input.fits) {
    const failure = target === "effect" ? "fails" : "throws";
    return [...head, ...call, "", `// With this data it ${failure}:`, `//   ${input.error ?? `the data doesn't match ${name}`}`].join("\n");
  }
  return [...head, ...call, "", typedView(input, target, "parse")].join("\n");
}

/** The program's view of the data, for `target`, imported as a file or parsed at runtime. */
export function inYourCode(input: CodeInput, target: Target, how: How = "file"): string {
  return how === "file" ? fileImport(input, target) : parsed(input, target);
}
