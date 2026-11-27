/** An error at a place in a data file: `orders.haus:3:7: …`. */
export const located = (text: string, fileName: string, offset: number | undefined, message: string): Error => {
  const before = text.slice(0, offset ?? 0).split("\n")
  return new Error(`${fileName}:${before.length}:${before.at(-1)!.length + 1}: ${message}`)
}
