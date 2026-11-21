/**
 * The limits a value built in code must fit to be written (spec §7, §11):
 * writers check every one of them, the canonical form and hashing (§12) only
 * the node limit. A parsed value fits the limits it was parsed with; a value
 * built in code may be deeper, longer, or share its parts with each other (a
 * DAG), which written out expands: every place writes the shared part again.
 *
 * Both checks walk the value once before it is written, iteratively (any
 * depth works without the call stack), and count every value as often as it
 * is written: the value itself and every element, field value and argument.
 */
import { HausEncodeError, type ErrorCode, type Path } from "./errors.js"
import { numberLimitIssue } from "./number.js"
import { longerThan, type Limits } from "./reader.js"
import type { HVariant, Value } from "./value.js"

/** The limits a writer checks. */
export type WriteLimits = Pick<Limits, "maxDepth" | "maxNumberLength" | "maxExponent" | "maxStringLength" | "maxNodes">

/** `too-many-nodes`, at the value given (`$`, or `$[i]` for value i of several). */
const tooMany = (max: number, at: Path): never => {
  throw new HausEncodeError(tooManyNodes(max), at, "too-many-nodes")
}

/** The reason of a `too-many-nodes` error. */
export const tooManyNodes = (max: number): string => `value has more than ${max} nodes (its parts share each other: written out, it would be larger than the node limit)`

/**
 * Whether `root` has at most `max` values, each counted as often as it is
 * written (spec §7, "Values written"). Stops as soon as the count is over,
 * and ends for a value that contains itself (forged past the constructors).
 */
export const nodesWithin = (root: Value, max: number): boolean => {
  let count = 1
  // Only containers are pushed, each counted with its children: the stack holds at most `max` of them.
  const stack: Value[] = [root]
  while (stack.length > 0) {
    const v = stack.pop()!
    if (v.kind === "record") {
      if ((count += v.fields.size) > max) return false
      for (const x of v.fields.values()) if (isContainer(x)) stack.push(x)
    } else if (v.kind === "array" || v.kind === "variant") {
      const children = v.kind === "array" ? v.items : v.args
      if ((count += children.length) > max) return false
      for (let i = 0; i < children.length; i++) if (isContainer(children[i]!)) stack.push(children[i]!)
    }
  }
  return count <= max
}

const isContainer = (v: Value): boolean => v.kind === "record" || v.kind === "array" || (v.kind === "variant" && v.args.length > 0)

/**
 * Fails with `too-many-nodes` (at `at`) if `root` has more than `max`
 * values, each counted as often as it is written (`nodesWithin`). The only
 * limit of the canonical form and hashing (spec §12).
 */
export const checkNodes = (root: Value, max: number, at: Path = []): void => {
  if (!nodesWithin(root, max)) tooMany(max, at)
}

/**
 * Fails with the limit's code if `root` breaks any limit a writer checks
 * (spec §11): the nesting depth (counted as for values built in code: a
 * record payload `Tag { … }` is one level, an empty record, array or payload
 * is a level), the length of each string, key and tag and of each byte
 * string's hex digits, the number and exponent limits, and the node limit.
 * The error is at the place of the value that breaks it (a key's at its
 * record), under `at`; `too-many-nodes` at `at` itself.
 */
export const checkWritable = (root: Value, limits: WriteLimits, at: Path = []): void => {
  if (!isContainer(root)) return checkLeaf(root, limits, root, at)
  const { maxDepth, maxStringLength, maxNodes } = limits
  // Containers only, each with the levels it is inside (as the parser counts them); counted with their children.
  let count = 1
  const containers: Value[] = [root]
  const depths: number[] = [0]
  while (containers.length > 0) {
    const v = containers.pop()!
    const depth = depths.pop()!
    if (depth >= maxDepth) fail(root, v, at, "nesting-too-deep", `value nested deeper than ${maxDepth} levels`)
    let children: readonly Value[]
    let inner = depth + 1
    if (v.kind === "record") {
      if ((count += v.fields.size) > maxNodes) tooMany(maxNodes, at)
      for (const [k, x] of v.fields) {
        if (k.length > maxStringLength && longerThan(k, maxStringLength)) fail(root, v, at, "key-too-long", `key longer than ${maxStringLength} characters`)
        if (isContainer(x)) {
          containers.push(x)
          depths.push(inner)
        } else checkLeaf(x, limits, root, at)
      }
      continue
    } else if (v.kind === "array") children = v.items
    else {
      checkLeaf(v, limits, root, at) // the tag
      children = (v as HVariant).args
      // `Tag { … }` is one level, the record's: the shorter spelling (spec §7).
      if (children.length === 1 && children[0]!.kind === "record") inner = depth
    }
    if ((count += children.length) > maxNodes) tooMany(maxNodes, at)
    for (let i = 0; i < children.length; i++) {
      const x = children[i]!
      if (isContainer(x)) {
        containers.push(x)
        depths.push(inner)
      } else checkLeaf(x, limits, root, at)
    }
  }
}

/** A writer's error at `v`, found inside `root` (given at `at`). */
const fail = (root: Value, v: Value, at: Path, code: ErrorCode, reason: string): never => {
  throw new HausEncodeError(reason, [...at, ...pathTo(root, v)], code)
}

/** The limits of a number, string, byte string or tag (spec §7). Hot: most values need one comparison. */
const checkLeaf = (v: Value, limits: WriteLimits, root: Value, at: Path): void => {
  switch (v.kind) {
    case "number":
      // Most numbers are short and have no exponent: nothing to check.
      if (v.text.length > limits.maxNumberLength || v.text.includes("e")) {
        const issue = numberLimitIssue(v.text, limits)
        if (issue !== undefined) fail(root, v, at, issue.code, issue.reason)
      }
      return
    case "string":
      if (longerThan(v.value, limits.maxStringLength)) fail(root, v, at, "string-too-long", `string longer than ${limits.maxStringLength} characters`)
      return
    case "bytes":
      if (v.bytes.length * 2 > limits.maxStringLength) fail(root, v, at, "string-too-long", `byte string longer than ${limits.maxStringLength} hex digits`)
      return
    case "variant":
      // Tags are ASCII: their length is their number of characters.
      if (v.tag.length > limits.maxStringLength) fail(root, v, at, "tag-too-long", `tag longer than ${limits.maxStringLength} characters`)
  }
}

/**
 * The path from `root` to `target` (the first place it is found, depth
 * first), for an error's place. Only called once a check has failed, so the
 * value is known to be within reach.
 */
const pathTo = (root: Value, target: Value): Path => {
  const stack: { readonly v: Value; readonly path: Path }[] = [{ v: root, path: [] }]
  while (stack.length > 0) {
    const { v, path } = stack.pop()!
    if (v === target) return path
    switch (v.kind) {
      case "array":
        v.items.forEach((x, i) => stack.push({ v: x, path: [...path, i] }))
        break
      case "record":
        for (const [k, x] of v.fields) stack.push({ v: x, path: [...path, k] })
        break
      case "variant":
        v.args.forEach((x, i) => stack.push({ v: x, path: [...path, i] }))
    }
  }
  return []
}
