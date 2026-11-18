/** Long TypeScript types broken over lines, for the playground's outputs. */

/** Split `text` at `sep` where it is not inside brackets or a string. */
export function splitTop(text: string, sep: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let inString = false;
  let last = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;
    if (c === '"' && text[i - 1] !== "\\") inString = !inString;
    if (inString) continue;
    if ("{[(<".includes(c)) depth++;
    else if ("}])>".includes(c)) depth--;
    else if (depth === 0 && text.startsWith(sep, i)) {
      parts.push(text.slice(last, i));
      last = i + sep.length;
      i += sep.length - 1;
    }
  }
  parts.push(text.slice(last));
  return parts;
}

export const WIDTH = 76;

/** A TypeScript type, broken over lines where it is too long: one union member or field per line. */
export function prettyType(type: string, indent: string, room: number): string {
  // Objects with more than one field always get a line per field; anything else only when too long.
  const isObject = type.startsWith("{ ") && type.endsWith(" }");
  if (type.length <= room && !(isObject && splitTop(type.slice(2, -2), "; ").length > 1)) return type;
  const members = splitTop(type, " | ");
  if (members.length > 1) return members.map((m) => `\n${indent}  | ${prettyType(m, indent + "    ", WIDTH - indent.length - 4)}`).join("");
  if (isObject) {
    const fields = splitTop(type.slice(2, -2), "; ");
    return `{\n${fields.map((f) => {
      const colon = splitTop(f, ": ");
      const head = colon[0]!;
      const rest = colon.slice(1).join(": ");
      return `${indent}  ${head}: ${prettyType(rest, indent + "  ", room - head.length - 4)};`;
    }).join("\n")}\n${indent}}`;
  }
  return type;
}

/**
 * Generated declarations, made readable: doc comments dropped (the
 * playground shows the schema next to it) and long types broken over lines.
 */
export function prettyDeclarations(ts: string): string {
  return ts
    .replace(/\/\*\*[\s\S]*?\*\/\n/g, "")
    .split("\n")
    .map((line) => {
      const m = /^((?:export )?(?:declare const \S+: |type \S+ = ))(.*);$/.exec(line);
      if (!m) return line;
      const pretty = prettyType(m[2]!, "", WIDTH - m[1]!.length);
      return `${m[1]}${pretty.startsWith("\n") ? pretty.trimEnd().replace(/^ /, "") : pretty};`.replace(/= \n/, "=\n");
    })
    .join("\n")
    .replace(/;\n(?=export |declare |type )/g, ";\n\n")
    .replace(/^(import[^\n]*\n)(?!\n)/, "$1\n");
}
