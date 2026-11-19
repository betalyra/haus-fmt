/** The stream reader checks the value length of the last value too (spec §7), also without a comma after it. */
import { expect, it } from "vitest"
import { StreamReader } from "../src/stream.js"
import { errorCode } from "../src/index.js"
const run = (text: string, max: number) => { const r = new StreamReader({ maxValueLength: max }); try { r.push(text); r.end(); return "ok" } catch (e) { return errorCode(e) } }
it("checks the last value at its last character", () => {
  expect(run("12345", 5)).toBe("ok")
  expect(run("123456", 5)).toBe("value-too-long")
  expect(run("1,12345", 5)).toBe("ok")
  expect(run("1,123456", 5)).toBe("value-too-long")
  expect(run("12345,", 5)).toBe("ok")
  expect(run("123456,", 5)).toBe("value-too-long")
})
it("counts characters, not UTF-16 code units, also when a pair is split between chunks", () => {
  expect(run('"😀"', 3)).toBe("ok")
  expect(run('"😀",', 3)).toBe("ok")
  expect(run('"😀😀"', 3)).toBe("value-too-long")
  const r = new StreamReader({ maxValueLength: 3 })
  const text = '"😀",'
  const values = [...text.split("").flatMap((c) => r.push(c)), ...r.end()]
  expect(values.length).toBe(1)
})
