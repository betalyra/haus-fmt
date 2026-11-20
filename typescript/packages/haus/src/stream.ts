import { HausSyntaxError, locate, START, type Origin } from "./errors.js"
import { Parser, withDefaults, type Limits } from "./parser.js"
import type { Value } from "./value.js"

type Mode = "normal" | "string" | "block" | "line" | "comment"

export interface StreamOptions {
  /** Parser limits; unspecified fields use DEFAULT_LIMITS. A `maxDepth` above MAX_SUPPORTED_DEPTH (512) is a RangeError. */
  readonly limits?: Partial<Limits>
  /** Largest single value in characters (default 64 Mi). Bounds memory per value. */
  readonly maxValueLength?: number
  /**
   * Require a comma after every value, including the last. A stream that ends
   * without one is reported as truncated instead of yielding a possibly cut-off
   * last value. Recommended for network streams. Default: false.
   */
  readonly requireTerminator?: boolean
}

/**
 * What a stream reader makes of each item: by default its `Value`. `text`
 * gets an item's text (with the comma that ends it) and where it starts;
 * `value`, the last item when it has no comma, parsed already.
 */
export interface ItemReader<T> {
  readonly text: (text: string, origin: Origin, limits: Limits) => T
  readonly value: (value: Value) => T
}

const VALUES: ItemReader<Value> = {
  text: (text, origin, limits) => new Parser(text, origin, limits).parseSingle(),
  value: (value) => value,
}

/**
 * Incremental reader: feed text chunks with `push`, receive every value that
 * has been completed (terminated by a top-level comma). Call `end` once the
 * input is exhausted to receive the last value if it had no trailing comma.
 *
 * Chunks can be split anywhere: inside strings, escapes, comments or `"""`.
 * Memory use is bounded by the largest single value, not the whole stream.
 * After a HausSyntaxError the reader is unusable.
 */
export class StreamReader<T = Value> {
  /**
   * Text of the current value already scanned, as pieces. Appending to one
   * growing string and indexing into it would flatten V8's rope on every
   * chunk, which is quadratic for a large value arriving in small chunks.
   */
  private done: string[] = []
  /** Characters (code points) in `done`. */
  private doneLength = 0
  /** Characters (code points) in `buf` before `counted`. */
  private bufChars = 0
  private counted = 0
  /** Text not scanned yet (plus at most a few characters of lookahead). */
  private buf = ""
  private i = 0
  private mode: Mode = "normal"
  private depth = 0
  private commentDepth = 0
  private origin: Origin = START
  private started = false
  private ended = false
  private readonly limits: Limits
  private readonly maxValueLength: number
  private readonly requireTerminator: boolean

  constructor(
    options: StreamOptions = {},
    /** What each item becomes (see `ItemReader`); its Value by default. */
    private readonly items: ItemReader<T> = VALUES as unknown as ItemReader<T>,
  ) {
    this.limits = withDefaults(options.limits ?? {})
    this.maxValueLength = options.maxValueLength ?? 64 * 1024 * 1024
    this.requireTerminator = options.requireTerminator ?? false
  }

  push(chunk: string): T[] {
    if (this.ended) throw new Error("StreamReader: push() after end()")
    this.buf += chunk
    if (!this.started && this.buf.length > 0) {
      this.started = true
      if (this.buf.charCodeAt(0) === 0xfeff) {
        this.buf = this.buf.slice(1)
        // The byte order mark is column 1, as in the whole-text parser.
        this.origin = { ...this.origin, offset: 1, column: 2 }
      }
    }
    return this.scan(false)
  }

  end(): T[] {
    this.ended = true
    const out = this.scan(true)
    // The scan checks a value's length before each character it reads, so the
    // last value is checked here, after its last character (§7).
    if (this.chars(this.buf.length) > this.maxValueLength) {
      throw new HausSyntaxError(`value longer than ${this.maxValueLength} characters`, this.origin.offset, this.origin.line, this.origin.column, "value-too-long")
    }
    // Whatever is left has no top-level comma: zero or one value.
    const text = this.done.join("") + this.buf
    const rest = new Parser(text, this.origin, this.limits).parseSequence()
    if (rest.length > 0 && this.requireTerminator) {
      const p = locate(text, text.length, this.origin)
      throw new HausSyntaxError("stream ended without ',' after the last value (truncated?)", p.offset, p.line, p.column, "stream-truncated", { expected: "','" })
    }
    out.push(...rest.map(this.items.value))
    this.buf = ""
    this.done = []
    this.doneLength = this.bufChars = this.counted = 0
    return out
  }

  /**
   * Finds top-level commas. Tracks only what is needed for that: bracket
   * depth, strings and comments. Everything else is checked by the Parser
   * when it parses the piece.
   */
  private scan(final: boolean): T[] {
    const out = this.scanBuffer(final)
    // Move the scanned prefix out of `buf`, so the next chunk is appended to a short string.
    if (this.i > 0) {
      this.done.push(this.buf.slice(0, this.i))
      this.doneLength = this.chars(this.i)
      this.bufChars = 0
      this.counted = 0
      this.buf = this.buf.slice(this.i)
      this.i = 0
    }
    return out
  }

  private scanBuffer(final: boolean): T[] {
    const out: T[] = []
    // Is the character `n` positions ahead available (or will it never come)?
    const has = (n: number) => final || this.i + n < this.buf.length

    while (this.i < this.buf.length) {
      if (this.chars(this.i) > this.maxValueLength) {
        throw new HausSyntaxError(`value longer than ${this.maxValueLength} characters`, this.origin.offset, this.origin.line, this.origin.column, "value-too-long")
      }
      const c = this.buf[this.i]
      switch (this.mode) {
        case "normal":
          if (c === "/") {
            if (!has(1)) return out
            const d = this.buf[this.i + 1]
            if (d === "/") this.mode = "line"
            else if (d === "*") {
              this.mode = "comment"
              this.commentDepth = 1
            }
            this.i += d === "/" || d === "*" ? 2 : 1
            continue
          }
          if (c === '"') {
            if (!has(2)) return out
            const block = this.buf.startsWith('"""', this.i)
            this.mode = block ? "block" : "string"
            this.i += block ? 3 : 1
            continue
          }
          if (c === "{" || c === "[" || c === "(") this.depth++
          else if (c === "}" || c === "]" || c === ")") {
            if (--this.depth < 0) this.failUnbalanced()
          } else if (c === "," && this.depth === 0) {
            out.push(this.cut())
            continue
          }
          this.i++
          continue

        case "line":
          if (c === "\n") this.mode = "normal"
          this.i++
          continue

        case "comment":
          if (c === "/" || c === "*") {
            if (!has(1)) return out
            if (this.buf.startsWith("/*", this.i)) {
              this.commentDepth++
              this.i += 2
              continue
            }
            if (this.buf.startsWith("*/", this.i)) {
              if (--this.commentDepth === 0) this.mode = "normal"
              this.i += 2
              continue
            }
          }
          this.i++
          continue

        case "string":
          if (c === "\\") {
            if (!has(1)) return out
            this.i += 2
            continue
          }
          // A line break can't be in a basic string: stop treating the rest as
          // string content so the Parser reports the error at the next cut.
          if (c === '"' || c === "\n") this.mode = "normal"
          this.i++
          continue

        case "block":
          if (c === "\\") {
            if (!has(1)) return out
            this.i += 2
            continue
          }
          if (c === '"') {
            if (!has(2)) return out
            if (this.buf.startsWith('"""', this.i)) {
              this.mode = "normal"
              this.i += 3
              continue
            }
          }
          this.i++
          continue
      }
    }
    return out
  }

  /** Parse the piece before the comma at `i` and drop it from the buffer. */
  private cut(): T {
    const text = this.scanned(this.i + 1) // including the comma
    // With its comma, so an empty item fails as in the whole text: "found ','".
    const value = this.items.text(text, this.origin, this.limits)
    this.origin = locate(text, text.length, this.origin)
    this.buf = this.buf.slice(this.i + 1)
    this.i = 0
    this.done = []
    this.doneLength = this.bufChars = this.counted = 0
    return value
  }

  /**
   * Characters (code points, spec §7) of the current value up to `buf[end]`.
   * A low surrogate isn't one: it is the second half of a character. Counted
   * once per position, also when a pair is split between chunks.
   */
  private chars(end: number): number {
    for (; this.counted < end; this.counted++) {
      const u = this.buf.charCodeAt(this.counted)
      if (u < 0xdc00 || u > 0xdfff) this.bufChars++
    }
    return this.doneLength + this.bufChars
  }

  /** The current value's text up to `buf[end]` (exclusive). */
  private scanned(end: number): string {
    return this.done.join("") + this.buf.slice(0, end)
  }

  private failUnbalanced(): never {
    // Let the Parser produce the precise message.
    const text = this.scanned(this.i + 1)
    new Parser(text, this.origin, this.limits).parseSingle()
    const p = locate(text, text.length - 1, this.origin)
    throw new HausSyntaxError(`unexpected '${this.buf[this.i]}'`, p.offset, p.line, p.column, "unexpected-closer", { found: `'${this.buf[this.i]}'` })
  }
}

export type ChunkSource =
  | AsyncIterable<string | Uint8Array>
  | Iterable<string | Uint8Array>
  | ReadableStream<string | Uint8Array>

/**
 * Parse a stream of haus values as they arrive. Accepts a fetch body, a Node
 * stream, or any (async) iterable of string / UTF-8 byte chunks.
 *
 *   for await (const event of parseStream(response.body!)) { ... }
 */
export async function* parseStream(source: ChunkSource, options: StreamOptions = {}): AsyncGenerator<Value, void, undefined> {
  yield* readStream(source, options)
}

/** `parseStream`, each item made by `items` (see `ItemReader`). */
export async function* readStream<T = Value>(source: ChunkSource, options: StreamOptions = {}, items?: ItemReader<T>): AsyncGenerator<T, void, undefined> {
  const reader = new StreamReader<T>(options, items)
  // ignoreBOM: the reader skips a byte order mark at the start; the decoder must not remove one too.
  const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true })
  for await (const chunk of chunks(source)) {
    yield* reader.push(typeof chunk === "string" ? chunk : decoder.decode(chunk, { stream: true }))
  }
  yield* reader.push(decoder.decode())
  yield* reader.end()
}

/** The chunks of a source, whatever its kind. */
export async function* chunks(source: ChunkSource): AsyncGenerator<string | Uint8Array> {
  if (typeof ReadableStream !== "undefined" && source instanceof ReadableStream) {
    // Not every browser supports async iteration of ReadableStream yet.
    const r = source.getReader()
    try {
      for (;;) {
        const { done, value } = await r.read()
        if (done) return
        yield value
      }
    } finally {
      r.releaseLock()
    }
  }
  yield* source as AsyncIterable<string | Uint8Array>
}
