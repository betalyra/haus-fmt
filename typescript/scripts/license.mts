// npm ships a package's LICENSE only from the package's own folder: this
// copies the repository's into every package that is published (not private).
//
//   node scripts/license.mts      (from typescript/; `pnpm release` runs it)
import { copyFileSync, existsSync, readdirSync, readFileSync } from "node:fs"
import { join, resolve } from "node:path"

const root = resolve(import.meta.dirname, "../..")

for (const parent of ["typescript/packages", "extensions"]) {
  for (const name of readdirSync(join(root, parent))) {
    const dir = join(root, parent, name)
    const manifest = join(dir, "package.json")
    if (!existsSync(manifest) || JSON.parse(readFileSync(manifest, "utf8")).private) continue
    copyFileSync(join(root, "LICENSE"), join(dir, "LICENSE"))
  }
}
