import Haus.Lexical

/-!
# Package names, versions and quoted text (spec §13.3, §9.2)

- `isPackageName`: `@organisation/name`, npm's rules for scoped names in
  lowercase: each part starts with a letter or digit and has only `a`–`z`,
  `0`–`9`, `-`, `.` and `_`, is not `node_modules`, and the whole name has at
  most 214 characters. ASCII only, so no `\d` or `$` subtleties.
- `isSemver`: a semantic version (SemVer 2.0.0): `MAJOR.MINOR.PATCH`, numbers
  without leading zeros, an optional pre-release and build. ASCII only.
- `isMajor`: the major version of an import, `0` or `[1-9][0-9]*`.
- `quote`: text from a file in a message (§9.2), `Haus.quoteBody` between
  quotes: control and bidirectional characters escaped, at most 40 characters.
-/

namespace Haus.Packages

def isLowerAlnum (c : Char) : Bool := ('a' ≤ c && c ≤ 'z') || ('0' ≤ c && c ≤ '9')

/-- A character of a package name's part after the first: `[a-z0-9._-]`. -/
def isSegmentChar (c : Char) : Bool := isLowerAlnum c || c == '.' || c == '_' || c == '-'

/-- A part of a package name: `[a-z0-9][a-z0-9._-]*`, not `node_modules`. -/
def isSegment (s : List Char) : Bool :=
  match s with
  | c :: cs => isLowerAlnum c && cs.all isSegmentChar && s != "node_modules".toList
  | [] => false

/-- A package name (§13.3): `@`, a part, `/`, a part; at most 214 characters. -/
def isPackageName (s : String) : Bool :=
  s.length ≤ 214 && match s.toList with
    | '@' :: rest =>
      match rest.dropWhile (· != '/') with
      | '/' :: name => isSegment (rest.takeWhile (· != '/')) && isSegment name
      | _ => false
    | _ => false

/-- A numeric identifier of a version: `0` or no leading zero, ASCII digits. -/
def isNumeric (s : String) : Bool :=
  match s.toList with
  | ['0'] => true
  | c :: cs => '1' ≤ c && c ≤ '9' && cs.all isDigit
  | [] => false

def isIdentChar' (c : Char) : Bool := isLowerAlnum c || ('A' ≤ c && c ≤ 'Z') || c == '-'

/-- A pre-release identifier: numeric without leading zeros, or alphanumeric with a non-digit. -/
def isPreId (s : String) : Bool :=
  !s.isEmpty && s.all isIdentChar' && (isNumeric s || s.any (fun c => !isDigit c))

def isBuildId (s : String) : Bool := !s.isEmpty && s.all isIdentChar'

/-- A semantic version (SemVer 2.0.0). -/
def isSemver (s : String) : Bool :=
  let (main, build) := match s.splitOn "+" with
    | [m] => (m, some [])
    | [m, b] => (m, some (b.splitOn "."))
    | _ => (s, none)
  match build with
  | none => false
  | some bs =>
    (bs.isEmpty || bs.all isBuildId) &&
    let (core, pre) := match main.splitOn "-" with
      | [] => (main, [])
      | c :: rest => (c, if rest.isEmpty then [] else ["-".intercalate rest])
    (pre.all fun p => (p.splitOn ".").all isPreId) &&
    match core.splitOn "." with
    | [a, b, c] => isNumeric a && isNumeric b && isNumeric c
    | _ => false

/-- The major version of a version: the text before the first `.`. Compared as text. -/
def majorOf (v : String) : String := (v.splitOn ".").headD v

/-- The major version an import names: `0` or `[1-9][0-9]*`. -/
def isMajor (s : String) : Bool := isNumeric s

/-- `quoteBody` between quotes. -/
def quote (s : String) : String := "\"" ++ String.ofList (quoteBody s) ++ "\""

#guard isPackageName "@haus-fmt/money"
#guard isPackageName "@acme/l00a"
#guard !isPackageName "@Acme/Common"
#guard !isPackageName "@acme/.."
#guard !isPackageName "@acme/node_modules"
#guard !isPackageName "@acme/common\n"
#guard !isPackageName "acme/common"
#guard !isPackageName "@acme/a/b"
#guard isSemver "1.0.0"
#guard isSemver "0.3.0-rc.1+build.7"
#guard isSemver "1.0.0+build.5"
#guard isSemver "1.0.0-x-y.1"
#guard !isSemver "1"
#guard !isSemver "v1.0.0"
#guard !isSemver "1.0.0\n"
#guard !isSemver "1\u0662.0.0"
#guard !isSemver "01.0.0"
#guard !isSemver "1.0.0-01"
#guard !isSemver "1.0.0 do-not-print"
#guard !isSemver "1.0.0+"
#guard isMajor "0" && isMajor "18446744073709551616" && !isMajor "01" && !isMajor "1.1" && !isMajor ""
#guard majorOf "0.3.0-rc.1+build.7" = "0"
#guard quote "a\nb" = "\"a\\u{A}b\""
-- At most 40 characters as shown, after escaping, the `…` within the 40 (§9.2).
#guard quote (String.ofList (List.replicate 40 'a')) = "\"" ++ String.ofList (List.replicate 40 'a') ++ "\""
#guard quote (String.ofList (List.replicate 45 'a')) = "\"" ++ String.ofList (List.replicate 39 'a') ++ "…\""
#guard quote (String.ofList (List.replicate 41 '\x01')) = "\"" ++ String.join (List.replicate 7 "\\u{1}") ++ "…\""
#guard quote (String.ofList (List.replicate 36 'a' ++ ['\x01'])) = "\"" ++ String.ofList (List.replicate 36 'a') ++ "…\""
#guard quote "\x1b[2J" = "\"\\u{1B}[2J\""

end Haus.Packages
