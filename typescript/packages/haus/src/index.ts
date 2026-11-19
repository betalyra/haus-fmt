import { HausSyntaxError } from "./errors.js"
import { Parser, withDefaults, type Limits } from "./parser.js"
import type { Value } from "./value.js"

export {
  ERROR_CODES, errorCode, errorDocs, errorHint, errorJson, formatPath, HausDecodeError, HausEncodeError, HausSyntaxError, isErrorCode, payloadHint,
  type CasePayload, type ErrorCategory, type ErrorCode, type ErrorDetails, type ErrorJson, type Path,
} from "./errors.js"
export {
  equalsJson, fromHausJson, fromHausJsonLines, fromHausJsonValue, hausJsonDepth, importJson, importJsonLines, importJsonValue, isJsonObject, jsonDepth, jsonObject, JsonNumber,
  JsonPlaces, parseJson, parseJsonLines, stringifyJson, toHausJson, toHausJsonLines, toHausJsonValue, type Json, type JsonLinesOptions, type JsonObject,
} from "./json.js"
export {
  fromBase64, fromSchemaBasedJson, toBase64, toSchemaBasedJson, type JsonCase, type JsonRecordType, type JsonType, type JsonVariantType,
} from "./json-schema-based.js"
export { DEFAULT_LIMITS, limitsIssue, MAX_DEPTH, MAX_SUPPORTED_DEPTH, type Limits } from "./parser.js"
export { parseStream, StreamReader, type ChunkSource, type StreamOptions } from "./stream.js"
export * from "./value.js"
export { format, quote, stringify, type FormatOptions, type FormatStyle } from "./format.js"
export { canonical, compare, compareCodePoints, equals, hash, hashAll, Hasher } from "./canonical.js"
export { floatText, floatValue, specialFloat, toFloat, toFloat32, toFloat64, type FloatType } from "./float.js"
export { normalizeNumber } from "./number.js"
export { infer, inferSchema, printShape, recursiveNames, RecordShape, resolve, Shape, VariantShape, type Inference, type PrintOptions } from "./infer.js"

/**
 * Parse a complete text into its sequence of top-level values, within
 * `limits` (spec §7; the defaults for those not given). Throws
 * HausSyntaxError, and a RangeError for a `maxDepth` above
 * MAX_SUPPORTED_DEPTH (512).
 */
export function parseAll(text: string, limits: Partial<Limits> = {}): Value[] {
  return new Parser(text, undefined, withDefaults(limits)).parseSequence()
}

/**
 * Like `parseAll`, but every value carries `start`/`end` offsets and records
 * carry `keySpans`. Slower; meant for editors and language servers.
 */
export function parseWithLocations(text: string, limits: Partial<Limits> = {}): Value[] {
  return new Parser(text, undefined, withDefaults(limits), true).parseSequence()
}

/** Values with locations plus the [start, end) span of every comment (for editors). */
export function parseDocument(text: string, limits: Partial<Limits> = {}): { values: Value[]; comments: [number, number][] } {
  const parser = new Parser(text, undefined, withDefaults(limits), true)
  const values = parser.parseSequence()
  return { values, comments: parser.comments }
}

/** Parse a complete text that must contain exactly one value. */
export function parse(text: string, limits: Partial<Limits> = {}): Value {
  const values = parseAll(text, limits)
  if (values.length !== 1) {
    throw new HausSyntaxError(`expected exactly one value, found ${values.length}`, 0, 1, 1, "not-one-value", { expected: "one value", found: `${values.length} values` })
  }
  return values[0]!
}
export {
  ATTRIBUTES, BUILTINS, deprecation, HausSchemaFileError, Instance, instanceOf, ModuleError, parseSchemaFile, STD_MODULES, withoutAttributes,
  type Attribute, type Builtin, type Case, type Definition, type Field, type ModuleResolver, type ParseSchemaOptions, type Payload, type RecordType,
  type ResolvedModule, type SchemaFile, type SchemaWarning, type SchemaWarningKind, type StdType, type Type, type VariantType,
} from "./schema-file.js"
export { importHint, moduleOfType, OFFICIAL_EXTENSIONS, schemaOutline, type MissingImport, type SchemaOutline } from "./schema-file.js"
export { importEdits, missingImports, type ImportEdit } from "./schema-imports.js"
export { Secret } from "./secret.js"
export { checkStdTime, isStdTimeType, STD_TIME_TYPES, type StdTimeType } from "./std-time.js"
export { checkData, describeType, type CheckIssue, type CheckOptions } from "./check.js"
export { contextOf, describeValue, hoverAt, hoverContext, hoverMarkdown, hoverText, TAG_NOTES, type HoverContext, type HoverInfo } from "./hover.js"
export { completeAt, type Completion } from "./complete.js"
export { HausValidationError, parseWith, parseWithAsync, type StandardSchemaV1 } from "./standard.js"
export { parsePlain, toPlain } from "./plain.js"
export {
  compileSchemaFile, fromSchemaFile, schemaDeclarations, definitionDoc, deprecatedDoc, type Codec, type CompiledSchemaFile, type CompileOptions, type DeclarationOptions, type FromSchemaFileOptions,
} from "./schema-compile.js"
