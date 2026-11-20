/**
 * A new own data property `key` of `o`, defined, not assigned: a key the
 * prototype chain has (`__proto__`, maybe a setter or read-only) can't
 * replace the prototype or be refused.
 */
export const defineOwn = (o: object, key: string, value: unknown): void => {
  Object.defineProperty(o, key, { value, enumerable: true, writable: true, configurable: true })
}
