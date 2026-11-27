/**
 * The Vite plugin: `.haus` imports in Vite projects (dev server and build).
 *
 *   // vite.config.ts
 *   import haus from "@haus-fmt/import/vite"
 *   export default { plugins: [haus({ target: "effect" })] }
 *   export default { plugins: [haus({ packages: ["vendor/acme"], folders: ["schemas"] })] }    // relative to Vite's root
 *   export default { plugins: [haus({ bundles: ["@acme/orders"] })] }                       // a library's bundle, imported
 *   export default { plugins: [haus({ optimize: { "src/github.schema.haus": ["Issue"] } })] }  // Issue optimized, code built ahead
 *
 * Use the same target as in tsconfig.json, so the types match the values.
 * Data without a schema is baked into the bundle as JS values, so no haus
 * parser ships for it. Schema files and data with a schema are decoded when
 * the module loads; their schema imports are resolved at build time, and the
 * schema files are watched.
 */
import type { Plugin } from "vite"
import { readFileSync } from "node:fs"
import { isSchemaFile } from "@haus-fmt/haus/node"
import { backend, moduleFor, optimizeOf, packagesOf, targetOf, type Backend, type ImportOptions } from "./generate.js"

export default function haus(options: ImportOptions = {}): Plugin {
  const target = targetOf(options)
  // The options' shape, checked now.
  packagesOf(options, process.cwd())
  optimizeOf(options, process.cwd())
  let root = process.cwd()
  let b: Promise<Backend> | undefined
  return {
    name: "haus",
    enforce: "pre",
    configResolved(config) {
      root = config.root
      b = undefined
    },
    async load(id) {
      const path = id.split("?")[0]!
      if (!path.endsWith(".haus")) return null
      b ??= backend(target, packagesOf(options, root), optimizeOf(options, root))
      // A schema file is read by the resolver, as every file of its schema (a regular file, without blocking).
      const { code, files } = moduleFor(isSchemaFile(path) ? "" : readFileSync(path, "utf8"), path, await b, (p) => `@haus-fmt/import/${p}`)
      for (const f of files) this.addWatchFile(f)
      return { code, map: null }
    },
  }
}
