import type { Value } from "../src/index.js"

/** A value in self-describing JSON (spec §16.2, without the envelope), written independently of the binding's own writer. */
export function suiteJson(v: Value): unknown {
  switch (v.kind) {
    case "string":
      return v.value
    case "number":
      return { _num: v.text }
    case "bytes":
      return { _bytes: Buffer.from(v.bytes).toString("hex") }
    case "array":
      return v.items.map(suiteJson)
    case "record":
      return { _rec: Object.fromEntries([...v.fields].map(([k, x]) => [k, suiteJson(x)])) }
    case "variant":
      return v.args.length ? { _tag: v.tag, _args: v.args.map(suiteJson) } : { _tag: v.tag }
  }
}

/** A line of the conformance suite's valid/NAME.jsonl: the value in its envelope. */
export const suiteJsonLine = (v: Value): unknown => ({ _haus: 1, _value: suiteJson(v) })
