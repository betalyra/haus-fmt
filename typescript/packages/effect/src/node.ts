/**
 * Reading schema files and packages in Node: the `SchemaFiles` service of
 * `@haus-fmt/effect`, with the file rules of core §13.3 as
 * `@haus-fmt/haus/node` applies them (regular files only, no links, the
 * build's root, the limits). Nothing is looked for: packages come only from
 * the directories and folders given (packages.md §2).
 *
 *   import { NodeSchemaFiles } from "@haus-fmt/effect/node"
 *
 *   const sources = yield* Haus.readSources("order.schema.haus", { packages: ["vendor/acme"] })
 *   // …
 *   program.pipe(Effect.provide(NodeSchemaFiles.layer))
 */
import type { HausError, Result } from "@haus-fmt/haus/internal"
import { readPackage, readPackages, readSourcesSync } from "@haus-fmt/haus/node"
import { Effect, Layer } from "effect"
import { readResult, SchemaFiles } from "./compile.js"

/** The core's read, a Promise of a Result, as an Effect: its failure a HausCompileError. */
const read = <A>(run: () => Promise<Result<A, HausError>>) => Effect.flatMap(Effect.promise(run), readResult)

/** `SchemaFiles` from the file system of Node, through `@haus-fmt/haus/node`. */
export const NodeSchemaFiles = Object.freeze({
  layer: Layer.succeed(SchemaFiles, SchemaFiles.of({
    // Synchronous, as the core reads: `Effect.runSync` can read a schema (a script, a test).
    readSources: (path, options = {}) => Effect.suspend(() => readResult(readSourcesSync(path, options))),
    readPackage: (dir) => read(() => readPackage(dir)),
    readPackages: (folder) => read(() => readPackages(folder)),
  })),
})
