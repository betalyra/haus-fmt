// A schema package's version is in several files: package.json (npm, where
// changesets bumps it), package.haus (its identity in every language:
// @haus-fmt/money@1#Money), Cargo.toml and python/pyproject.toml. This copies
// the package.json version into the others; `--check` only reports a mismatch.
//
//   node scripts/sync-versions.mts [--check]      (from typescript/)
import { readdirSync, readFileSync, writeFileSync, existsSync } from "node:fs"
import { join, resolve } from "node:path"

const extensions = resolve(import.meta.dirname, "../../extensions")
const check = process.argv.includes("--check")

/** Each file with the pattern of its version: the first match is the package's. */
const files: ReadonlyArray<readonly [string, RegExp]> = [
  ["package.haus", /(version:\s*")([^"]*)(")/],
  ["Cargo.toml", /^(version\s*=\s*")([^"]*)(")/m],
  ["python/pyproject.toml", /^(version\s*=\s*")([^"]*)(")/m],
]

let stale = 0
for (const name of readdirSync(extensions)) {
  const dir = join(extensions, name)
  if (!existsSync(join(dir, "package.json"))) continue
  const { version } = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"))
  for (const [file, pattern] of files) {
    const path = join(dir, file)
    if (!existsSync(path)) continue
    const text = readFileSync(path, "utf8")
    const found = pattern.exec(text)?.[2]
    if (found === undefined) throw new Error(`${name}/${file}: no version`)
    if (found === version) continue
    stale++
    if (check) console.error(`${name}/${file}: version ${found}, package.json says ${version}`)
    else writeFileSync(path, text.replace(pattern, `$1${version}$3`))
  }
}
if (check && stale > 0) process.exit(1)
