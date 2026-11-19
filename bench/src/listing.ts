/**
 * A fetched directory of documents is pinned by its listing: the lines
 * `<name>\t<SHA-256 of the file>\n`, sorted by name, whose SHA-256 the
 * manifest holds. fetch writes the listing beside the directory
 * (`<dir>.listing`); readers read the files it names, in its order.
 */

export const listingText = (files: readonly { readonly name: string; readonly sha256: string }[]): string =>
  [...files].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)).map((f) => `${f.name}\t${f.sha256}\n`).join("")

/** The names and hashes of a listing, in order. */
export const parseListing = (text: string): { readonly name: string; readonly sha256: string }[] =>
  text.split("\n").filter((l) => l !== "").map((l) => {
    const [name = "", sha256 = ""] = l.split("\t")
    return { name, sha256 }
  })

export const listingFile = (dir: string): string => `${dir}.listing`
