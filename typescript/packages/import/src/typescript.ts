/**
 * The TypeScript 7.1 content mapper. TypeScript starts this process
 * (package.json#typescript.contentMapper) and asks it, per imported `.haus`
 * file, for a virtual TypeScript module (generate.ts). The target comes from
 * the tsconfig entry:
 *
 *   "contentMappers": [{ "package": "@haus-fmt/import", "extensions": [".haus"], "options": { "target": "effect" } }]
 *
 * Syntax and schema errors become diagnostics at the right place in the file.
 * `packages` and `folders` in the options are relative to the tsconfig.json;
 * `bundles` are imported from its directory.
 */
import { HausSyntaxError, isHausError } from "@haus-fmt/haus"
import { isSchemaFile } from "@haus-fmt/haus/node"
import { dirname } from "node:path"
import { runContentMapper, stringIndexToPosition } from "ts-content-mapper"
import { backend, packagesOf, targetOf, typesFor, type Backend, type ImportOptions } from "./generate.js"

runContentMapper<ImportOptions, Backend>({
  diagnosticSource: "haus",
  async openProject(params) {
    const root = params.configFileName === "" ? process.cwd() : dirname(params.configFileName)
    return { project: await backend(targetOf(params.options), packagesOf(params.options, root)) }
  },
  transform(params, context) {
    const at = (offset: number) => stringIndexToPosition(params.content, offset, context.positionEncoding)
    try {
      const { text, diagnostics } = typesFor(params.content, params.fileName, context.project)
      return {
        text,
        extension: ".mts",
        diagnostics: diagnostics.map((d) => ({ messageText: d.message, start: at(d.offset), length: d.length, code: 91002 })),
      }
    } catch (e) {
      // A syntax error at its place; an error of the package layer (no place) at the start.
      if (!isHausError(e)) throw e
      return {
        text: isSchemaFile(params.fileName) ? "export {};\n" : "declare const value: unknown;\nexport default value;\n",
        extension: ".mts",
        diagnostics: [{ messageText: e.reason, start: at(e instanceof HausSyntaxError ? e.offset : 0), length: 1, code: 91001 }],
      }
    }
  },
})
