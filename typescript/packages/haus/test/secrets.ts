/** The suites' `secrets` field (test-suite/README.md): encoding a decoded value without `revealSecrets`. */
import { expect } from "vitest"
import { errorCode, formatPath, HausEncodeError } from "../src/index.js"

/**
 * Encoding `decoded` without `revealSecrets` (spec §15, "Encoding a secret"):
 * with secrets, `cannot-encode` at one of their places; without, the same
 * result as with the option.
 */
export const checkSecrets = (encode: () => unknown, secrets: readonly string[], withOption: () => unknown): void => {
  if (secrets.length === 0) {
    expect(encode()).toEqual(withOption())
    return
  }
  let error: unknown
  try {
    encode()
  } catch (e) {
    error = e
  }
  expect(errorCode(error), "encoding a secret without revealSecrets must fail").toBe("cannot-encode")
  expect(secrets).toContain(formatPath((error as HausEncodeError).path))
}
