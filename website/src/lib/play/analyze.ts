/**
 * Everything the playground shows, computed from the two texts with the same
 * functions the parsers and the VS Code extension use.
 */
import {
  checkData,
  compileSchemaFile,
  contextOf,
  format,
  HausSyntaxError,
  inferSchema,
  parseDocument,
  parseSchemaFile,
  schemaDeclarations,
  toPlain,
  type CheckIssue,
  type HoverContext,
  type SchemaFile,
  type Value,
} from "../../../../typescript/packages/haus/src/index.ts";
import { plainDeclarations } from "../../../../typescript/packages/haus/src/plain.ts";
import * as h from "../../../../typescript/packages/haus/src/schema.ts";
import { prettyDeclarations } from "./pretty";
import type { CodeInput } from "./in-code";

export interface Problem {
  readonly from: number;
  readonly to: number;
  readonly severity: "error" | "info";
  readonly message: string;
}

export interface Analysis {
  readonly dataProblems: Problem[];
  readonly schemaProblems: Problem[];
  /** For hovers and completion; absent while the data doesn't parse. */
  readonly hover?: HoverContext;
  /** What "In your code" shows, for each target and way of getting the data; absent while the data doesn't parse. */
  readonly code?: CodeInput;
  readonly schema?: { readonly file: SchemaFile; readonly type: string };
  readonly outputs: {
    readonly inferred: string;
    readonly typescript: string;
    readonly json: string;
    readonly formatted: string;
  };
  /** One line on what happened: `3 values, checked against Root: 1 error`. */
  readonly summary: string;
}

export const syntaxProblem = (e: HausSyntaxError, text: string): Problem => ({
  from: Math.min(e.offset, text.length),
  to: Math.min(e.offset + 1, text.length),
  severity: "error",
  message: e.reason,
});

/** The type that describes the whole data file: Root, else the schema's last type without parameters. */
const rootType = (file: SchemaFile) =>
  file.definition("Root")?.name ?? [...file.definitions].reverse().find((d) => d.params.length === 0)?.name;

/** JSON for what a program gets: bigints, dates, maps and bytes written readably. */
const json = (x: unknown) =>
  JSON.stringify(
    x,
    (_, v: unknown) =>
      typeof v === "bigint" ? `${v}n`
      : v instanceof Map ? Object.fromEntries(v)
      : v instanceof Uint8Array ? `x"${[...v].map((b) => b.toString(16).padStart(2, "0")).join("")}"`
      : v,
    2,
  );

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;

export function analyze(data: string, schemaText: string): Analysis {
  const schemaProblems: Problem[] = [];
  let schema: Analysis["schema"];
  if (schemaText.trim()) {
    try {
      const file = parseSchemaFile(schemaText);
      const type = rootType(file);
      if (type) schema = { file, type };
      else schemaProblems.push({ from: 0, to: 0, severity: "error", message: "the schema needs a type without parameters to describe the data (type Root = …)" });
    } catch (e) {
      if (!(e instanceof HausSyntaxError)) throw e;
      schemaProblems.push(syntaxProblem(e, schemaText));
    }
  }

  let values: Value[];
  let comments: [number, number][];
  try {
    ({ values, comments } = parseDocument(data));
  } catch (e) {
    if (!(e instanceof HausSyntaxError)) throw e;
    const empty = "// fix the error to see this";
    return {
      dataProblems: [syntaxProblem(e, data)],
      schemaProblems,
      ...(schema ? { schema } : {}),
      outputs: { inferred: empty, typescript: empty, json: empty, formatted: empty },
      summary: `Syntax error at ${e.line}:${e.column}`,
    };
  }

  const issues: CheckIssue[] = schema ? checkData(schema.file, schema.type, values) : [];
  const dataProblems = issues.map((i): Problem => ({
    from: Math.min(i.start, data.length),
    to: Math.min(i.end, data.length),
    severity: i.severity === "error" ? "error" : "info",
    message: i.message,
  }));
  const errors = issues.filter((i) => i.severity === "error").length;

  // What a program gets: decoded with the schema when the data fits it, else the plain view.
  let program: unknown;
  try {
    const plain = toPlain(values);
    program = values.length === 1 ? plain[0] : plain;
  } catch (e) {
    program = `${(e as Error).message}`;
  }
  let fits = false;
  if (schema && errors === 0) {
    try {
      const { schemas, streams } = compileSchemaFile(schemaText);
      const root = schemas[schema.type]!;
      const decoded = values.map((v) => h.decode(root, v));
      program = streams.has(schema.type) ? decoded : decoded[0];
      fits = true;
    } catch {
      // keep the plain view
    }
  }

  const first = issues.find((i) => i.severity === "error");
  const at = (offset: number) => {
    const lines = data.slice(0, offset).split("\n");
    return `${lines.length}:${lines.at(-1)!.length + 1}`;
  };
  const code: CodeInput = { values, data, program, ...(schema ? { schema } : {}), fits, ...(first ? { error: `${first.message} (at ${at(first.start)})` } : {}) };
  const what = values.length === 1 ? "1 value" : `${values.length} values (a stream)`;
  const checked = schema ? `, checked against ${schema.type}: ${errors === 0 ? "no errors" : plural(errors, "error")}` : "";
  return {
    dataProblems,
    schemaProblems,
    hover: contextOf(values, schema),
    code,
    ...(schema ? { schema } : {}),
    outputs: {
      inferred: inferSchema(values),
      // With a schema, two modules, as @haus-fmt/import generates them: the data file typed by
      // the schema's root type, and the schema file with its types and schemas.
      typescript: schema
        ? [
            "// data.haus",
            `import type { ${schema.type} } from "./data.schema.haus";`,
            "",
            `declare const data: ${schema.file.definition(schema.type)?.template.stream ? `ReadonlyArray<${schema.type}>` : schema.type};`,
            "",
            "export default data;",
            "",
            "",
            "// data.schema.haus",
            prettyDeclarations(schemaDeclarations(schema.file)),
          ].join("\n")
        : `// data.haus\n${prettyDeclarations(plainDeclarations(data, "data.haus"))}`,
      json: (() => {
        try {
          return json(program) ?? "undefined";
        } catch (e) {
          return `// ${(e as Error).message}`;
        }
      })(),
      formatted: format(values, { source: data, comments }),
    },
    summary: `${what}${checked}`,
  };
}
