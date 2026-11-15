/**
 * Copies docs/cheat-sheet.md into the skill as skills/haus/cheat-sheet.md:
 * the Starlight frontmatter becomes a heading, and links to site pages
 * (`/docs/cli`) become absolute (`https://haus-fmt.org/docs/cli`), since the
 * skill is read outside the site.
 *
 *   node claude-plugin/scripts/sync.ts           # write the copy
 *   node claude-plugin/scripts/sync.ts --check   # exit 1 if it is out of date
 */
import { readFileSync, writeFileSync } from "node:fs"
import { fileURLToPath } from "node:url"

const SITE = "https://haus-fmt.org"
const source = fileURLToPath(new URL("../../docs/cheat-sheet.md", import.meta.url))
const target = fileURLToPath(new URL("../skills/haus/cheat-sheet.md", import.meta.url))

const frontmatter = /^---\n([\s\S]*?)\n---\n/

const field = (yaml: string, name: string): string | undefined =>
  yaml.match(new RegExp(`^${name}:\\s*(.+)$`, "m"))?.[1]?.trim().replace(/^"(.*)"$/, "$1")

const skillCopy = (markdown: string): string => {
  const match = frontmatter.exec(markdown)
  if (!match) throw new Error("docs/cheat-sheet.md has no frontmatter")
  const yaml = match[1]!
  const title = field(yaml, "title") ?? "Cheat sheet"
  const description = field(yaml, "description")
  const body = markdown.slice(match[0].length).replace(/\]\(\/(?!\/)/g, `](${SITE}/`)
  return [
    `<!-- Generated from docs/cheat-sheet.md by claude-plugin/scripts/sync.ts. Don't edit: edit the source and run \`node claude-plugin/scripts/sync.ts\`. -->`,
    "",
    `# haus ${title.toLowerCase()}`,
    "",
    ...(description ? [description, ""] : []),
    body.trimStart(),
  ].join("\n")
}

const expected = skillCopy(readFileSync(source, "utf8"))
const current = (() => {
  try {
    return readFileSync(target, "utf8")
  } catch {
    return undefined
  }
})()

if (process.argv.includes("--check")) {
  if (current !== expected) {
    console.error("claude-plugin/skills/haus/cheat-sheet.md is out of date: run `node claude-plugin/scripts/sync.ts`.")
    process.exit(1)
  }
  console.log("claude-plugin/skills/haus/cheat-sheet.md is up to date.")
} else if (current !== expected) {
  writeFileSync(target, expected)
  console.log("Wrote claude-plugin/skills/haus/cheat-sheet.md.")
}
