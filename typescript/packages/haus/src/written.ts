/**
 * The safety net of the writers (spec §11, "Values don't change"). A value
 * that exists is within the limits it was built with (value.ts records each
 * container's size and depth when it is built), so the writers, the
 * canonical form, hashing, equality and order check no limit. They check one
 * thing before they walk a value: that it is still the value that was built.
 * TypeScript can't stop code from changing a value (a cast, a Map's `set`),
 * and a changed value could contain itself, or be larger or deeper than its
 * recorded size and depth; walking it could then hang or overflow the stack.
 *
 * `checkUnchanged` walks the value with a stack of its own, counting every
 * value as often as it is written, and stops as soon as the count passes the
 * size recorded at the root, or a part is deeper than its recorded depth:
 * HausEncodeError `value-changed`. So it ends, linear in the recorded size,
 * whatever was done to the value. A change that keeps the size and depth is
 * not noticed: what the writers make of it is undefined (spec §11).
 */
import { HausEncodeError, type Path } from "./errors.js"
import { isContainer, type Value } from "./value.js"

/** `value-changed`, at `at`, naming `which` operand when there are two. */
const changed = (at: Path, which?: string): never => {
  throw new HausEncodeError(
    `${which === undefined ? "the value" : `the ${which} value`} was changed after it was built (a part added, removed, or made to contain itself): values are read-only`,
    at,
    "value-changed",
  )
}

/**
 * Throws HausEncodeError `value-changed` (at `at`) when `root` is no longer
 * the value that was built: it holds more or fewer values than its recorded
 * size, or nests deeper than its recorded depth. Never hangs: it stops once
 * it has counted one value more than the recorded size.
 */
export const checkUnchanged = (root: Value, at: Path = [], which?: string): void => {
  if (!isContainer(root)) return
  const size = root.size
  const depth = root.depth
  let count = 1
  // Containers to look into, each with its level (0 for the root), as value.ts counts depth.
  const stack: Value[] = [root]
  const levels: number[] = [0]
  while (stack.length > 0) {
    const v = stack.pop()!
    const level = levels.pop()!
    if (level >= depth) changed(at, which)
    let parts: Iterable<Value>
    let inner = level + 1
    if (v.kind === "record") parts = v.fields.values()
    else if (v.kind === "array") parts = v.items
    else if (v.kind === "variant") {
      parts = v.args
      // `Tag { … }`: the record is the level (spec §7).
      if (v.args.length === 1 && v.args[0]!.kind === "record") inner = level
    } else continue
    for (const p of parts) {
      if (++count > size) changed(at, which)
      if (isContainer(p)) {
        stack.push(p)
        levels.push(inner)
      }
    }
  }
  if (count !== size) changed(at, which)
}
