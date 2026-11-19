/**
 * Downloads everything in `sources.haus` into the data directory and checks
 * each file's SHA-256. Files that are already there with the right hash are
 * kept.
 *
 *   corpus      git (shallow, blob-less fetch of the pinned commit from
 *               github.com), then each pinned file from that commit; for a
 *               pinned directory, all its blobs in one request, checked
 *               together by the listing's SHA-256 (listing.ts)
 *   tokenizers  https://huggingface.co/<repo>/resolve/<revision>/<file>,
 *               a few at a time
 *
 * Fails on a hash mismatch: a pinned source never changes silently. A file is
 * written under a temporary name and renamed once its hash is checked, so a
 * bad download never sits where a good one is expected; a directory's
 * listing is written last.
 */
import { Console, Crypto, Effect, FileSystem, Path, Stream } from "effect"
import { HttpClient, HttpClientResponse } from "effect/http"
import { ChildProcess } from "effect/process"
import { DownloadError, GitError, HashMismatchError } from "../errors.ts"
import { listingFile, listingText, parseListing } from "../listing.ts"
import { Manifest, type CorpusSource, type PinnedFile, type PinnedFiles, type TokenizerFile, type TokenizerSource } from "../manifest.ts"
import { BenchPaths } from "../paths.ts"

/** Downloads at once from the Hub. */
const CONCURRENCY = 4

const hex = (bytes: Uint8Array): string => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")

const concat = (chunks: readonly Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0))
  chunks.reduce((at, c) => (out.set(c, at), at + c.length), 0)
  return out
}

const sha256 = Effect.fn("fetch.sha256")(function* (data: Uint8Array) {
  const crypto = yield* Crypto.Crypto
  return hex(yield* crypto.digest("SHA-256", data))
})

/** The file is there with this hash. */
const hasFile = Effect.fn("fetch.hasFile")(function* (path: string, hash: string) {
  const fs = yield* FileSystem.FileSystem
  if (!(yield* fs.exists(path))) return false
  return (yield* sha256(yield* fs.readFile(path))) === hash
})

/** Writes `data` to `path` once its hash is checked. */
const store = Effect.fn("fetch.store")(function* (path: string, data: Uint8Array, hash: string, what: string) {
  const fs = yield* FileSystem.FileSystem
  const p = yield* Path.Path
  const actual = yield* sha256(data)
  if (actual !== hash) {
    return yield* new HashMismatchError({ what, expected: hash, actual, message: `${what}: SHA-256 is ${actual}, the manifest pins ${hash}` })
  }
  yield* fs.makeDirectory(p.dirname(path), { recursive: true })
  yield* fs.writeFile(`${path}.part`, data)
  yield* fs.rename(`${path}.part`, path)
})

/** Runs git (with `input` on its stdin, if given); its stdout, as bytes. stderr goes to ours. */
const git = Effect.fn("fetch.git")(function* (args: readonly string[], input?: string) {
  const stdin = input === undefined ? "ignore" : Stream.make(new TextEncoder().encode(input))
  const handle = yield* ChildProcess.make("git", args, { stdin, stderr: "inherit" })
  const [chunks, exitCode] = yield* Effect.all([Stream.runCollect(handle.stdout), handle.exitCode], { concurrency: 2 })
  if (exitCode !== 0) return yield* new GitError({ args: [...args], exitCode, message: `git ${args.join(" ")} exited with ${exitCode}` })
  return concat(chunks)
}, Effect.scoped)

/**
 * The objects of `git cat-file --batch` output, in order: each is
 * `<oid> <type> <size>\n`, the content, `\n`. Pure.
 */
export const splitBatch = (out: Uint8Array): Uint8Array[] => {
  const objects: Uint8Array[] = []
  for (let at = 0; at < out.length;) {
    const eol = out.indexOf(0x0a, at)
    const header = new TextDecoder().decode(out.subarray(at, eol)).split(" ")
    const size = Number(header[2])
    if (eol < 0 || header[1] !== "blob" || !Number.isInteger(size)) break // `<oid> missing` and anything else: not a blob
    objects.push(out.slice(eol + 1, eol + 1 + size))
    at = eol + 1 + size + 1
  }
  return objects
}

const gitText =(args: readonly string[]) => git(args).pipe(Effect.map((bytes) => new TextDecoder().decode(bytes)))

/** The git repository of a corpus source, with the pinned commit's trees (no blobs: git fetches those as they are read). */
const repository = Effect.fn("fetch.repository")(function* (s: CorpusSource) {
  const paths = yield* BenchPaths
  const fs = yield* FileSystem.FileSystem
  const p = yield* Path.Path
  const repo = paths.gitDir(s.name)
  yield* fs.makeDirectory(repo, { recursive: true })
  if (!(yield* fs.exists(p.join(repo, "HEAD")))) yield* git(["init", "--quiet", "--bare", repo])
  yield* Console.log(`fetch   ${s.repo} @ ${s.commit}`)
  yield* git(["-C", repo, "fetch", "--quiet", "--depth=1", "--filter=blob:none", s.repo, s.commit])
  return repo
})

/** One pinned file of a source, unless it's there already. */
const fetchFile = Effect.fn("fetch.file")(function* (s: CorpusSource, file: PinnedFile) {
  const paths = yield* BenchPaths
  const target = paths.corpusFile(s.name, file.path)
  if (yield* hasFile(target, file.sha256)) return yield* Console.log(`ok      ${s.name}: ${file.path} (${target})`)
  const repo = yield* repository(s)
  yield* store(target, yield* git(["-C", repo, "cat-file", "blob", `${s.commit}:${file.path}`]), file.sha256, `${s.name}: ${file.path}`)
  yield* Console.log(`stored  ${target}`)
})

/** The stored listing and every file it names match the pin. */
const storedListing = Effect.fn("fetch.storedListing")(function* (dir: string, pin: PinnedFiles) {
  const fs = yield* FileSystem.FileSystem
  const p = yield* Path.Path
  const listing = listingFile(dir)
  if (!(yield* fs.exists(listing))) return false
  const text = yield* fs.readFileString(listing)
  if ((yield* sha256(new TextEncoder().encode(text))) !== pin.sha256) return false
  const entries = parseListing(text)
  if (entries.length !== pin.count) return false
  const ok = yield* Effect.forEach(entries, (e) => hasFile(p.join(dir, e.name), e.sha256), { concurrency: CONCURRENCY })
  return ok.every(Boolean)
})

/**
 * Every file of a pinned directory: the tree's blobs in one request, then
 * each file, the listing checked against the pin before anything is stored.
 */
const fetchFiles = Effect.fn("fetch.files")(function* (s: CorpusSource, pin: PinnedFiles) {
  const paths = yield* BenchPaths
  const fs = yield* FileSystem.FileSystem
  const p = yield* Path.Path
  const dir = paths.corpusDir(s.name, pin.dir)
  if (yield* storedListing(dir, pin)) return yield* Console.log(`ok      ${s.name}: ${pin.dir}/*${pin.suffix} (${pin.count} files in ${dir})`)
  const repo = yield* repository(s)
  // `<mode> blob <oid>\t<name>` per entry
  const entries = (yield* gitText(["-C", repo, "ls-tree", `${s.commit}:${pin.dir}`]))
    .split("\n")
    .map((line) => line.split("\t") as [string, string])
    .filter(([meta, name]) => name !== undefined && meta.split(" ")[1] === "blob" && name.endsWith(pin.suffix))
    .map(([meta, name]) => ({ name, oid: meta.split(" ")[2]! }))
  yield* Console.log(`fetch   ${entries.length} files of ${pin.dir}/*${pin.suffix}`)
  const oids = entries.map((e) => e.oid)
  yield* git(["-C", repo, "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--recurse-submodules=no", "--filter=blob:none", s.repo, ...oids])
  const blobs = yield* git(["-C", repo, "cat-file", "--batch"], oids.map((oid) => `${oid}\n`).join("")).pipe(Effect.map(splitBatch))
  if (blobs.length !== entries.length) return yield* new GitError({ args: ["cat-file", "--batch"], exitCode: 0, message: `git cat-file --batch gave ${blobs.length} objects for ${entries.length}` })
  const files = yield* Effect.forEach(entries, (e, i) => sha256(blobs[i]!).pipe(Effect.map((hash) => ({ name: e.name, data: blobs[i]!, sha256: hash }))))
  const listing = listingText(files)
  const actual = yield* sha256(new TextEncoder().encode(listing))
  if (actual !== pin.sha256 || files.length !== pin.count) {
    return yield* new HashMismatchError({
      what: `${s.name}: ${pin.dir}`,
      expected: pin.sha256,
      actual,
      message: `${s.name}: ${pin.dir}/*${pin.suffix}: ${files.length} files, listing SHA-256 ${actual}; the manifest pins ${pin.count} files, ${pin.sha256}`,
    })
  }
  yield* Effect.forEach(files, (f) => store(p.join(dir, f.name), f.data, f.sha256, `${s.name}: ${pin.dir}/${f.name}`), { concurrency: CONCURRENCY, discard: true })
  yield* fs.writeFileString(listingFile(dir), listing)
  yield* Console.log(`stored  ${files.length} files in ${dir}`)
})

const fetchCorpus = (s: CorpusSource) => {
  switch (s.layout._tag) {
    case "OpenApiExamples":
      return fetchFile(s, s.layout.description)
    case "JsonSchemaDocuments":
      return Effect.andThen(fetchFile(s, s.layout.schema), fetchFiles(s, s.layout.documents))
  }
}

const fetchTokenizerFile = Effect.fn("fetch.tokenizerFile")(function* (t: TokenizerSource, f: TokenizerFile) {
  const paths = yield* BenchPaths
  const target = paths.tokenizerFile(t.name, f.file)
  if (yield* hasFile(target, f.sha256)) return yield* Console.log(`ok      ${t.name}/${f.file}`)
  const url = `https://huggingface.co/${t.repo}/resolve/${t.revision}/${f.file}`
  yield* Console.log(`fetch   ${url}`)
  const client = yield* HttpClient.HttpClient
  const response = yield* client.get(url)
  const data = yield* HttpClientResponse.matchStatus(response, {
    "2xx": (r) => r.arrayBuffer,
    orElse: (r) =>
      Effect.fail(new DownloadError({ url, status: r.status, message: `${url}: HTTP ${r.status} (a gated repository needs a login; this benchmark uses public files only)` })),
  })
  yield* store(target, new Uint8Array(data), f.sha256, `${t.name}: ${f.file}`)
})

export const fetchSources = Effect.fn("bench.fetch")(function* () {
  const manifest = yield* Manifest
  yield* Effect.forEach(manifest.corpus, fetchCorpus, { discard: true })
  const files = manifest.tokenizers.flatMap((t) => t.files.map((f) => [t, f] as const))
  yield* Effect.forEach(files, ([t, f]) => fetchTokenizerFile(t, f), { concurrency: CONCURRENCY, discard: true })
})
