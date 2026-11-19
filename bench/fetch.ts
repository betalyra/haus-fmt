/**
 * Downloads everything in `sources.haus` into bench/.data/ and checks each
 * file's SHA-256. Files that are already there with the right hash are kept.
 *
 *   corpus      git (shallow, blob-less fetch of the pinned commit from
 *               github.com), then the one file at `path` from that commit
 *   tokenizers  https://huggingface.co/<repo>/resolve/<revision>/<file>
 *
 * Fails on a hash mismatch: a pinned source never changes silently.
 */
import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"
import { readManifest, type CorpusSource, type TokenizerSource } from "./lib/manifest.ts"
import { corpusFile, DATA, ensureDir, tokenizerDir } from "./lib/paths.ts"

const sha256 = (data: Uint8Array): string => createHash("sha256").update(data).digest("hex")

const hasFile = (path: string, hash: string): boolean => existsSync(path) && sha256(readFileSync(path)) === hash

/** Write `data` to `path` once its hash is checked, so a bad download never sits where a good one is expected. */
const store = (path: string, data: Uint8Array, hash: string, what: string): void => {
  const got = sha256(data)
  if (got !== hash) throw new Error(`${what}: SHA-256 is ${got}, the manifest pins ${hash}`)
  ensureDir(dirname(path))
  writeFileSync(`${path}.part`, data)
  renameSync(`${path}.part`, path)
}

const git = (dir: string, ...args: string[]): Buffer =>
  execFileSync("git", ["-C", dir, ...args], { maxBuffer: 1 << 30, stdio: ["ignore", "pipe", "inherit"] })

const fetchCorpus = (s: CorpusSource): void => {
  const target = corpusFile(s.name, s.path)
  if (hasFile(target, s.sha256)) return console.log(`ok      ${s.name} (${target})`)
  const repo = ensureDir(`${DATA}git/${s.name}.git`)
  if (!existsSync(`${repo}HEAD`)) execFileSync("git", ["init", "--quiet", "--bare", repo])
  console.log(`fetch   ${s.repo} @ ${s.commit}`)
  git(repo, "fetch", "--quiet", "--depth=1", "--filter=blob:none", s.repo, s.commit)
  store(target, git(repo, "cat-file", "blob", `${s.commit}:${s.path}`), s.sha256, `${s.name}: ${s.path}`)
  console.log(`stored  ${target}`)
}

const fetchTokenizer = async (t: TokenizerSource): Promise<void> => {
  for (const f of t.files) {
    const target = `${tokenizerDir(t.name)}${f.file}`
    if (hasFile(target, f.sha256)) {
      console.log(`ok      ${t.name}/${f.file}`)
      continue
    }
    const url = `https://huggingface.co/${t.repo}/resolve/${t.revision}/${f.file}`
    console.log(`fetch   ${url}`)
    const res = await fetch(url)
    if (!res.ok) throw new Error(`${url}: HTTP ${res.status} (a gated repository needs a login; this benchmark uses public files only)`)
    store(target, new Uint8Array(await res.arrayBuffer()), f.sha256, `${t.name}: ${f.file}`)
  }
}

const manifest = readManifest()
for (const s of manifest.corpus) fetchCorpus(s)
for (const t of manifest.tokenizers) await fetchTokenizer(t)
