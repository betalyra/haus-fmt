import Haus.Layout.Pretty

/-!
# The standard formatter, keeping comments (spec §11)

`format` reformats a document: it reads the text into a concrete syntax tree
(`Node`, `File`) that keeps what the values (`Value`) leave out — comments,
line breaks and blank lines, and the spellings of numbers, strings and byte
strings — and writes it in one of the three layouts of §11 (`Style`):

* **pretty** (`pretty`, `prettyFile`): one entry per line in every non-empty
  record and array, positional payloads inline when they fit, comments kept
  next to the entries they belong to, blank lines between entries kept (at
  most one), the options `indent` and `width` (`Layout.Options`);
* **compact** and **minimised** (`line`, `lineFile`): every top-level item
  on one line, comments dropped, with or without the spaces between tokens
  (`Layout.Spacing`).

It is a model of what the bindings' formatters do (TypeScript's
`format(values, { source, comments })` is the fuzzer's other reference),
including the points that spec §11 leaves open, as listed in
`plans/zig-findings.md` F15–F20d.

## The tree

Between any two tokens there is a `Gap`: the runs of whitespace (`Ws`: no
line break, a line break, or a blank line) and the comments between them,
in order. A run of whitespace is never split by a token, so two runs on
either side of a token (`{`, `,`, a key) stay two pieces: a blank line is
two line breaks with only blanks between them, never across a token.

A container keeps the gap after its opening bracket (`first`) and, for each
entry, the gap after it up to the next entry or the closing bracket; the
comma, wherever it was, is dropped (the gap before it and the gap after it
are joined). A field also keeps the gaps between its key and its colon and
between the colon and its value. Leaves keep their spelling (`Node.leaf`).
Blanks between a tag and its `(` or `{` are not kept; nothing else can be
there (§4: a payload starts on the tag's line).

## Where comments go (§11, F15–F20d)

Of the comments in the gap after an entry, those before the first line
break stay after the entry's comma (`trailing`); a comment with a line
break in it ends them (the comments after it lead the next entry). The rest
are written on their own lines above the next entry, or, after the last
entry, at the end of the container ("dangling"). Comments in the first gap
of a container lead its first entry, or dangle when it has none. Comments
between a key and its value move above the entry, after its own leading
comments.

A comment on its own line, and an entry, follow a blank line when the
source had one right before them (since the previous comment or entry), and
never as the first line of a container. An entry with comments moved above
it follows no blank line of its own: one it had goes before the moved
comments (F20b). In a stream (more than one top-level item), an item whose
value is written over more than one line is followed by a blank line before
the next item and the comments that lead it (after the comments on its own
line, F19; one blank line, never two); not before the comments after the
last item, unless the source has one there. A file with one item is a
stream too when the options say so (`Options.stream`, §11): it then has a
comma after its item, in every layout.

`Tag({ … })` is written `Tag { … }`: the gaps between the parentheses and
the braces join the record's (F16, F20c).

The text of a comment is written as it is, its CR LF as LF (F17: the lines
of a block comment are not re-indented).

## Reading

`read` first runs the reference parser (`Parser.parse`), so a text is
formatted exactly when it is a haus file, and rejected with the parser's
error otherwise. Then `parseTree` builds the tree: the structure as the
parser reads it, the parser's own readers for keys and leaves, a one-pass
scanner for the gaps (`scan`) and for the leaves' spellings
(`leafSpelling`). `read` checks that the tree's values are the parser's and
that each leaf's spelling reads as its value (`Node.ok`); a text failing
that would be rejected as a bug of the model (no input does).

Proven in `Haus.Layout.FormatRoundTrip`: the compact and minimised layouts
of a document parse to the document's values (`parse_format_compact`,
`parse_format_minimised`).
-/

namespace Haus.Format
open Haus Parser Layout

/-! ## The concrete syntax tree -/

/-- A run of blanks and line breaks: none, one line break, or a blank line (two or more). -/
inductive Ws where
  | none
  | line
  | blank
  deriving DecidableEq, Repr, Inhabited

/-- Two runs on either side of a token, or one after the other: the more. -/
def Ws.max : Ws → Ws → Ws
  | .blank, _ | _, .blank => .blank
  | .line, _ | _, .line => .line
  | .none, .none => .none

/-- A run with `n` line breaks. -/
def Ws.ofBreaks : Nat → Ws
  | 0 => .none
  | 1 => .line
  | _ => .blank

/-- A piece of a gap: a run of whitespace or a comment (its text as written, `//` or `/*` included). -/
inductive Piece where
  | ws (w : Ws)
  | comment (text : Text)
  deriving Repr, Inhabited, BEq

/-- What stands between two tokens: runs of whitespace and comments, in source order. -/
abbrev Gap := List Piece

mutual
/-- A value as written. -/
inductive Node where
  /-- A number, string or byte string: its spelling and its value. -/
  | leaf (spelling : Text) (value : Value)
  /-- `[ … ]`: the gap after `[` and the items. -/
  | arr (first : Gap) (items : List Item)
  /-- `{ … }`: the gap after `{` and the fields. -/
  | record (first : Gap) (fields : List Field)
  /-- `Tag` -/
  | bare (tag : String)
  /-- `Tag( … )`: the gap after `(` and the arguments (`Tag({ … })` is one record argument). -/
  | args (tag : String) (first : Gap) (items : List Item)
  /-- `Tag { … }`: the gap after `{` and the fields. -/
  | braces (tag : String) (first : Gap) (fields : List Field)

/-- An item of an array or a payload, or a top-level item, and the gap after it (its comma dropped). -/
inductive Item where
  | mk (value : Node) (after : Gap)

/-- A field: its key, the gaps before and after its colon, its value, and the gap after it. -/
inductive Field where
  | mk (key : String) (beforeColon afterColon : Gap) (value : Node) (after : Gap)
end

/-- A file: the gap before its first item (after a byte order mark), and its items. -/
structure File where
  first : Gap
  items : List Item

/-! ## Values -/

mutual
/-- The value a node is written for. -/
def Node.value : Node → Value
  | .leaf _ v => v
  | .arr _ xs => .arr (Item.values xs)
  | .record _ fs => .record (Field.values fs)
  | .bare t => .variant t []
  | .args t _ xs => .variant t (Item.values xs)
  | .braces t _ fs => .variant t [.record (Field.values fs)]

def Item.values : List Item → List Value
  | [] => []
  | .mk v _ :: xs => v.value :: Item.values xs

def Field.values : List Field → List (String × Value)
  | [] => []
  | .mk k _ _ v _ :: fs => (k, v.value) :: Field.values fs
end

/-- The values of a file. -/
def File.values (f : File) : List Value := Item.values f.items

/-! ## Comments in the tree -/

/-- No comment in the gap. -/
def Gap.quiet (g : Gap) : Bool := g.all fun | .comment _ => false | .ws _ => true

mutual
/-- No comment anywhere in the node. -/
def Node.quiet : Node → Bool
  | .leaf _ _ | .bare _ => true
  | .arr g xs | .args _ g xs => Gap.quiet g && Item.quiet xs
  | .record g fs | .braces _ g fs => Gap.quiet g && Field.quiet fs

def Item.quiet : List Item → Bool
  | [] => true
  | .mk v g :: xs => v.quiet && Gap.quiet g && Item.quiet xs

def Field.quiet : List Field → Bool
  | [] => true
  | .mk _ g₁ g₂ v g :: fs => Gap.quiet g₁ && Gap.quiet g₂ && v.quiet && Gap.quiet g && Field.quiet fs
end

/-- The gap without its comments. -/
def Gap.dropComments (g : Gap) : Gap := g.filter fun | .comment _ => false | .ws _ => true

mutual
/-- The node without its comments (line breaks and blank lines kept). -/
def Node.dropComments : Node → Node
  | .leaf s v => .leaf s v
  | .bare t => .bare t
  | .arr g xs => .arr (Gap.dropComments g) (Item.dropComments xs)
  | .args t g xs => .args t (Gap.dropComments g) (Item.dropComments xs)
  | .record g fs => .record (Gap.dropComments g) (Field.dropComments fs)
  | .braces t g fs => .braces t (Gap.dropComments g) (Field.dropComments fs)

def Item.dropComments : List Item → List Item
  | [] => []
  | .mk v g :: xs => .mk v.dropComments (Gap.dropComments g) :: Item.dropComments xs

def Field.dropComments : List Field → List Field
  | [] => []
  | .mk k g₁ g₂ v g :: fs =>
    .mk k (Gap.dropComments g₁) (Gap.dropComments g₂) v.dropComments (Gap.dropComments g) :: Field.dropComments fs
end

/-- The file without its comments: what "the pretty file without its comments" formats (F15). -/
def File.dropComments (f : File) : File := ⟨Gap.dropComments f.first, Item.dropComments f.items⟩

/-! ## Reading the tree

The structure is read as `Parser.value` reads it, with the parser's readers
for keys and leaves; the gaps and the leaves' spellings by a one-pass scan
each (`scan`, `leafSpelling`), which keeps the reader linear in the text.
It runs only on texts `Parser.parse` accepted (`read`). -/

/-- The whitespace run so far, with `n` line breaks, as a piece (none for a run without one). -/
def wsPiece (n : Nat) : Gap := if n = 0 then [] else [.ws (.ofBreaks n)]

/-- Where the gap scanner is: in whitespace, in a line comment, or in a block comment `depth` levels deep. -/
inductive Mode where
  | ws
  | line (acc : Text)
  | block (depth : Nat) (acc : Text)

/--
The gap at the start of a text, and the rest: blanks and line breaks (`n`
so far in the current run), line comments (ending before their line
break), block comments (nested, ending after the matching `*/`), as
`Parser.ws` skips them. `acc` holds a comment's text so far, `g` the pieces
so far, both reversed. One pass over the text; on a text `Parser.parse`
accepted, it stops where `Parser.ws` does.
-/
def scan : Mode → Nat → Gap → Text → Gap × Text
  | .ws, n, g, ' ' :: r | .ws, n, g, '\t' :: r => scan .ws n g r
  | .ws, n, g, '\n' :: r | .ws, n, g, '\r' :: '\n' :: r => scan .ws (n + 1) g r
  | .ws, n, g, '/' :: '/' :: r => scan (.line ['/', '/']) 0 (wsPiece n ++ g) r
  | .ws, n, g, '/' :: '*' :: r => scan (.block 1 ['*', '/']) 0 (wsPiece n ++ g) r
  | .ws, n, g, t => ((wsPiece n ++ g).reverse, t)
  | .line acc, _, g, '\n' :: r | .line acc, _, g, '\r' :: '\n' :: r => scan .ws 1 (.comment acc.reverse :: g) r
  | .line acc, _, g, [] => ((Piece.comment acc.reverse :: g).reverse, [])
  | .line acc, _, g, c :: r => scan (.line (c :: acc)) 0 g r
  | .block d acc, _, g, '/' :: '*' :: r => scan (.block (d + 1) ('*' :: '/' :: acc)) 0 g r
  | .block d acc, _, g, '*' :: '/' :: r =>
    if d ≤ 1 then scan .ws 0 (.comment ('/' :: '*' :: acc).reverse :: g) r
    else scan (.block (d - 1) ('/' :: '*' :: acc)) 0 g r
  | .block d acc, _, g, c :: r => scan (.block d (c :: acc)) 0 g r
  | .block _ _, _, g, [] => (g.reverse, [])

/-- Whitespace and comments, as `Parser.ws` skips them, kept as a gap. -/
def gap : P Gap := do
  let (g, r) := scan .ws 0 [] (← get)
  set r
  return g

/-- The length of a `"…"` string or byte string after its opening quote, up to and including its closing quote. -/
def quotedLength : Text → Nat
  | '\\' :: _ :: r => 2 + quotedLength r
  | '"' :: _ => 1
  | _ :: r => 1 + quotedLength r
  | [] => 0

/--
The spelling of the leaf at the start of a text: a block string up to its
closing quotes (`Parser.findClose`), a `"…"` string or byte string up to its
closing quote, a number as `Parser.lexNumber` lexes it.
-/
def leafSpelling : Text → Text
  | '"' :: '"' :: '"' :: r =>
    match findClose r with
    | some (content, _) => ['"', '"', '"'] ++ content ++ ['"', '"', '"']
    | none => []
  | '"' :: r => '"' :: r.take (quotedLength r)
  | 'x' :: '"' :: r => 'x' :: '"' :: r.take (quotedLength r)
  | t => (lexNumber t).elim [] (·.literal)

/--
A leaf read by `p` (the parser's reader for it), with its spelling. `read`
checks that the spelling, read alone by `p`, gives the leaf's value
(`Node.ok`).
-/
def spelled (p : P Value) : P Node := do
  let t ← get
  return .leaf (leafSpelling t) (← p)

mutual
/-- A value as a node (`Parser.value`). -/
def readNode (L : Limits) : Nat → P Node
  | 0 => fail .outOfFuel "out of fuel"
  | fuel + 1 => do
    match ← get with
    | '{' :: _ => skip; let g ← gap; return .record g (← readFields L fuel)
    | '[' :: _ => skip; let g ← gap; return .arr g (← readItems L fuel ']')
    | '"' :: '"' :: '"' :: _ => spelled (.str <$> blockString L)
    | '"' :: _ => spelled (.str <$> basicString L)
    | 'x' :: '"' :: _ => spelled (bytes L)
    | c :: _ =>
      if c == '-' || isDigit c then spelled (number L)
      else if isUpper c then readVariant L fuel
      else fail .expectedValue "expected a value"
    | [] => fail .expectedValue "expected a value"

/-- `Tag`, `Tag( … )` or `Tag { … }` (`Parser.variant`). -/
def readVariant (L : Limits) : Nat → P Node
  | 0 => fail .outOfFuel "out of fuel"
  | fuel + 1 => do
    let tag := String.ofList (← takeWhile isIdentChar)
    let afterTag ← get
    let _ ← takeWhile isBlank
    match ← get with
    | '(' :: _ => skip; let g ← gap; return .args tag g (← readItems L fuel ')')
    | '{' :: _ => skip; let g ← gap; return .braces tag g (← readFields L fuel)
    | _ => set afterTag; return .bare tag

/-- Items up to and including `close`, after the gap that follows the opening bracket (`Parser.itemsLoop`). -/
def readItems (L : Limits) : Nat → Char → P (List Item)
  | 0, _ => fail .outOfFuel "out of fuel"
  | fuel + 1, close => do
    match ← get with
    | c :: r =>
      if c == close then set r; return []
      let v ← readNode L fuel
      let g ← gap
      match ← get with
      | ',' :: r => set r; let g' ← gap; return .mk v (g ++ g') :: (← readItems L fuel close)
      | c :: r => if c == close then set r; return [.mk v g] else fail .missingComma "expected ','"
      | [] => fail .unclosedBracket "unclosed bracket"
    | [] => fail .unclosedBracket "unclosed bracket"

/-- Fields up to and including `}`, after the gap that follows `{` (`Parser.fields`). -/
def readFields (L : Limits) : Nat → P (List Field)
  | 0 => fail .outOfFuel "out of fuel"
  | fuel + 1 => do
    match ← get with
    | '}' :: r => set r; return []
    | [] => fail .unclosedBracket "unclosed '{'"
    | _ =>
      let k ← key L
      let g₁ ← gap
      expect ':' .missingColon "expected ':'"
      let g₂ ← gap
      let v ← readNode L fuel
      let g ← gap
      match ← get with
      | ',' :: r => set r; let g' ← gap; return .mk k g₁ g₂ v (g ++ g') :: (← readFields L fuel)
      | '}' :: r => set r; return [.mk k g₁ g₂ v g]
      | _ => fail .missingComma "expected ',' or '}'"
end

/-- The top-level items (`Parser.fileLoop`). -/
def fileItems (L : Limits) (fuel : Nat) : Nat → P (List Item)
  | 0 => fail .outOfFuel "out of fuel"
  | n + 1 => do
    if (← get).isEmpty then return []
    let v ← readNode L fuel
    let g ← gap
    match ← get with
    | [] => return [.mk v g]
    | ',' :: r => set r; let g' ← gap; return .mk v (g ++ g') :: (← fileItems L fuel n)
    | _ => fail .missingComma "expected ','"

/-- The tree of a text that `Parser.parse` accepts; a byte order mark is skipped, as the parser does. -/
def parseTree (L : Limits) (input : Text) : Except Error File :=
  let t := match input with
    | '\uFEFF' :: r => r
    | r => r
  let fuel := 4 * (t.length + 1)
  (do let g ← gap; return File.mk g (← fileItems L fuel fuel)).run' t

/-! ## What `read` checks

The tree reader is not proven to agree with the parser; `read` checks the
two facts about its tree that the proofs (`Haus.Layout.FormatRoundTrip`)
rely on: the tree's values are the parser's (`valuesEq`), and each leaf's
spelling, read again alone by the parser's reader for it, gives the leaf's
value (`Node.ok`; and a payload `( … )` has an argument). Neither check
fails on any input: if one did, `read` would reject the text as a bug of
the model. -/

mutual
/-- Equal values (a `BEq` that is proven lawful where it is used: `valueEq_sound`). -/
def valueEq : Value → Value → Bool
  | .num a, .num b => a == b
  | .str a, .str b => a == b
  | .bytes a, .bytes b => a == b
  | .arr xs, .arr ys => valuesEq xs ys
  | .record fs, .record gs => fieldsEq fs gs
  | .variant t xs, .variant u ys => t == u && valuesEq xs ys
  | _, _ => false

def valuesEq : List Value → List Value → Bool
  | [], [] => true
  | x :: xs, y :: ys => valueEq x y && valuesEq xs ys
  | _, _ => false

def fieldsEq : List (String × Value) → List (String × Value) → Bool
  | [], [] => true
  | (k, x) :: fs, (l, y) :: gs => k == l && valueEq x y && fieldsEq fs gs
  | _, _ => false
end

/-- The spelling `s`, read alone by `p`, gives `v` and nothing is left. -/
def readsAs (p : P Value) (s : Text) (v : Value) : Bool :=
  match p.run s with
  | .ok (w, []) => valueEq w v
  | _ => false

/-- A leaf's spelling, read alone by the parser's reader for its kind, gives its value. -/
def leafOk (L : Limits) (s : Text) : Value → Bool
  | v@(.num _) => readsAs (number L) s v
  | v@(.str _) =>
    match s with
    | '"' :: '"' :: '"' :: _ => readsAs (.str <$> blockString L) s v
    | '"' :: _ => readsAs (.str <$> basicString L) s v
    | _ => false
  | v@(.bytes _) =>
    match s with
    | 'x' :: '"' :: _ => readsAs (bytes L) s v
    | _ => false
  | _ => false

mutual
/-- Every leaf of the node reads as its value (`leafOk`), and every payload `( … )` has an argument. -/
def Node.ok (L : Limits) : Node → Bool
  | .leaf s v => leafOk L s v
  | .bare _ => true
  | .arr _ xs => Item.ok L xs
  | .args _ _ xs => !xs.isEmpty && Item.ok L xs
  | .record _ fs | .braces _ _ fs => Field.ok L fs

def Item.ok (L : Limits) : List Item → Bool
  | [] => true
  | .mk v _ :: xs => v.ok L && Item.ok L xs

def Field.ok (L : Limits) : List Field → Bool
  | [] => true
  | .mk _ _ _ v _ :: fs => v.ok L && Field.ok L fs
end

/--
**A document read for formatting**: rejected exactly when `Parser.parse`
rejects it, with its error; otherwise its tree, which holds the parser's
values.
-/
def read (L : Limits) (input : Text) : Except Error File :=
  match Parser.parse L input with
  | .error e => .error e
  | .ok vs =>
    match parseTree L input with
    | .ok f =>
      if valuesEq f.values vs && Item.ok L f.items then .ok f
      else .error ⟨.outOfFuel, "model bug: the tree doesn't hold the parser's values", 0⟩
    | .error e => .error { e with reason := s!"model bug: no tree ({e.reason})" }

/-! ## Leaves

Numbers and byte strings are written as spelled (§11, also in minimised). A
`"…"` string keeps its spelling, with raw U+2028 and U+2029 escaped; a block
string is written from its value: in pretty as a block string again (one
level deeper than its entry) when it holds a line feed, otherwise as `"…"`,
as is a `"…"` string with a line feed in pretty. -/

/-- A text with its raw U+2028 and U+2029 escaped (`\u{2028}`, `\u{2029}`). -/
def escapeSeps (t : Text) : Text := t.flatMap fun c => if isLineSep c then Pretty.unicode c else [c]

/-- A string on one line: its spelling, separators escaped, or `"…"` from its value when it was a block string. -/
def basic (spelling : Text) (s : String) : Text :=
  if spelling.take 3 = ['"', '"', '"'] then Canonical.string s else escapeSeps spelling

/-- A leaf on one line. -/
def leafLine (spelling : Text) : Value → Text
  | .str s => basic spelling s
  | _ => spelling

/-- A leaf in pretty, its entry at the indent `ind`. -/
def leafPretty (o : Options) (ind spelling : Text) : Value → Text
  | .str s => if s.toList.contains '\n' then Pretty.blockString (deeper o ind) s else basic spelling s
  | _ => spelling

/-! ## Compact and minimised -/

mutual
/-- A node on one line, with the spacing `sp` (compact or minimised); comments dropped. -/
def line (sp : Spacing) : Node → Text
  | .leaf s v => leafLine s v
  | .arr _ xs => '[' :: lineItems sp xs ++ [']']
  | .record _ fs => lineRecord sp fs
  | .bare t => t.toList
  | .braces t _ fs => t.toList ++ sp.tag ++ lineRecord sp fs
  | .args t _ [.mk (.record _ fs) _] => t.toList ++ sp.tag ++ lineRecord sp fs
  | .args t _ xs => t.toList ++ '(' :: lineItems sp xs ++ [')']

/-- `{}`, or the fields in braces. -/
def lineRecord (sp : Spacing) : List Field → Text
  | [] => ['{', '}']
  | f :: fs => '{' :: sp.inner ++ lineFields sp (f :: fs) ++ sp.inner ++ ['}']

/-- Items separated by `,` and the spacing. -/
def lineItems (sp : Spacing) : List Item → Text
  | [] => []
  | [.mk v _] => line sp v
  | .mk v _ :: x :: xs => line sp v ++ ',' :: sp.comma ++ lineItems sp (x :: xs)

/-- Fields `key: value` separated by `,` and the spacing. -/
def lineFields (sp : Spacing) : List Field → Text
  | [] => []
  | [.mk k _ _ v _] => Canonical.key k ++ ':' :: sp.colon ++ line sp v
  | .mk k _ _ v _ :: f :: fs => Canonical.key k ++ ':' :: sp.colon ++ line sp v ++ ',' :: sp.comma ++ lineFields sp (f :: fs)
end

/-- A top-level item of a stream on its line, followed by a comma. -/
def streamLine (sp : Spacing) : Item → Text
  | .mk v _ => line sp v ++ [',', '\n']

/--
Top-level items in a one-line layout, as `Layout.linesAs` writes values: a
single item without a comma, unless the file is a stream (`stream`, §11).
-/
def lineItemsFile (sp : Spacing) (stream : Bool) : List Item → Text
  | [] => []
  | [.mk v g] => if stream then streamLine sp (.mk v g) else line sp v ++ ['\n']
  | x :: y :: ys => (x :: y :: ys).flatMap (streamLine sp)

/--
A file in a one-line layout: one item per line, a comma after each when
there is more than one, or when the file is a stream (`stream`).
-/
def lineFile (sp : Spacing) (stream : Bool) (f : File) : Text := lineItemsFile sp stream f.items

/-! ## Pretty -/

/--
The comments of a gap, each with the whitespace before it: since the
previous comment, or, for the first, since the start of the gap (`acc`
holds what came before that); and the whitespace after the last one.
-/
def comments : Gap → Ws → List (Text × Ws) × Ws
  | [], acc => ([], acc)
  | .ws w :: g, acc => comments g (acc.max w)
  | .comment t :: g, acc => let r := comments g .none; ((t, acc) :: r.1, r.2)

/--
The comments that stay after an entry (on its line: no line break before
them since the entry, also not in an earlier comment), and the rest.
-/
def trailing : List (Text × Ws) → List Text × List (Text × Ws)
  | (t, .none) :: cs => if t.contains '\n' then ([t], cs) else let r := trailing cs; (t :: r.1, r.2)
  | cs => ([], cs)

/-- A comment's text with LF line endings. -/
def clean (t : Text) : Text := t.filter (· != '\r')

/-- A line break before a line, for a blank line, unless the line is the first of its container. -/
def blankLine (first blank : Bool) : Text := if !first && blank then ['\n'] else []

/--
Comments on their own lines at `ind`, each after a blank line where the
source had one before it (or after a multi-line stream item, `multi`).
-/
def commentLines (ind : Text) : Bool → Bool → List (Text × Ws) → Text
  | _, _, [] => []
  | first, multi, (t, w) :: cs => blankLine first (w == .blank || multi) ++ ind ++ clean t ++ '\n' :: commentLines ind false false cs

/-- The comments after an entry's comma, each after a space. -/
def trailingText (cs : List Text) : Text := cs.flatMap fun t => ' ' :: clean t

/--
The entries of a container (or a file) at the indent `ind`, each followed by
`sep`; `stream`: the top-level items of a stream; `tail`: a gap to add after
the last entry (`Tag({ … })`).
-/
structure Run where
  ind : Text
  sep : Text
  stream : Bool
  tail : Gap

/-
The writers below take the text that follows (`rest`) and write in front
of it, so that a deeply nested value is not copied once per level.
-/
mutual
/--
**The pretty layout** of a node at the indent `ind`, with `used` columns of
its line taken (§11), followed by `rest`.
-/
def pretty (o : Options) (ind : Text) (used : Nat) : Node → Text → Text
  | .leaf s v, rest => leafPretty o ind s v ++ rest
  | .bare t, rest => t.toList ++ rest
  | .arr g xs, rest =>
    let (cs, w) := comments g .none
    if xs.isEmpty && cs.isEmpty then '[' :: ']' :: rest
    else '[' :: '\n' :: items o ⟨deeper o ind, [','], false, []⟩ true false cs w xs (ind ++ ']' :: rest)
  | .record g fs, rest =>
    let (cs, w) := comments g .none
    if fs.isEmpty && cs.isEmpty then '{' :: '}' :: rest
    else '{' :: '\n' :: fields o ⟨deeper o ind, [','], false, []⟩ true false cs w fs (ind ++ '}' :: rest)
  | .braces t g fs, rest =>
    let (cs, w) := comments g .none
    t.toList ++ ' ' ::
      if fs.isEmpty && cs.isEmpty then '{' :: '}' :: rest
      else '{' :: '\n' :: fields o ⟨deeper o ind, [','], false, []⟩ true false cs w fs (ind ++ '}' :: rest)
  -- `Tag({ … })` is `Tag { … }`: the gaps in the parentheses join the record's.
  | .args t g [.mk (.record g' fs) after], rest =>
    let (cs, w) := comments (g ++ g' ++ (if fs.isEmpty then after else [])) .none
    t.toList ++ ' ' ::
      if fs.isEmpty && cs.isEmpty then '{' :: '}' :: rest
      else '{' :: '\n' :: fields o ⟨deeper o ind, [','], false, after⟩ true false cs w fs (ind ++ '}' :: rest)
  | .args t g xs, rest =>
    -- On one line when it can be and fits (the line is written only then).
    if Gap.quiet g && Item.quiet xs && flatList (Item.values xs) && used + (line .spaced (.args t g xs)).length ≤ o.width
    then line .spaced (.args t g xs) ++ rest
    else
      let (cs, w) := comments g .none
      t.toList ++
        if xs.isEmpty && cs.isEmpty then '(' :: ')' :: rest
        else '(' :: '\n' :: items o ⟨deeper o ind, [','], false, []⟩ true false cs w xs (ind ++ ')' :: rest)

/--
Items one per line (a top-level item, an array item, an argument), with
their comments, followed by `rest`. `first`: nothing written yet; `multi`:
the previous item was a multi-line item of a stream; `carry`: the comments
that lead the next item, and `ws` the whitespace after them.
-/
def items (o : Options) (r : Run) (first multi : Bool) (carry : List (Text × Ws)) (ws : Ws) :
    List Item → Text → Text
  | [], rest => commentLines r.ind first false carry ++ rest
  | .mk v after :: xs, rest =>
    let start := commentLines r.ind first multi carry ++
      blankLine (first && carry.isEmpty) (ws == .blank || (multi && carry.isEmpty))
    let used := r.ind.length + r.sep.length
    let (cs, w) := comments (if xs.isEmpty then after ++ r.tail else after) .none
    let (tr, own) := trailing cs
    -- An item of a stream is multi-line by its value (F19).
    let multi' := r.stream && (pretty o r.ind used v []).contains '\n'
    start ++ r.ind ++ pretty o r.ind used v (r.sep ++ trailingText tr ++ '\n' :: items o r false multi' own w xs rest)

/-- Fields one per line, with their comments, followed by `rest`; comments between a key and its value move above the field. -/
def fields (o : Options) (r : Run) (first multi : Bool) (carry : List (Text × Ws)) (ws : Ws) :
    List Field → Text → Text
  | [], rest => commentLines r.ind first false carry ++ rest
  | .mk k g₁ g₂ v after :: fs, rest =>
    let moved := (comments (g₁ ++ g₂) ws).1
    let lead := carry ++ moved
    let start := commentLines r.ind first multi lead ++
      blankLine (first && lead.isEmpty) ((moved.isEmpty && ws == .blank) || (multi && lead.isEmpty))
    let pre := Canonical.key k ++ [':', ' ']
    let used := r.ind.length + pre.length + r.sep.length
    let (cs, w) := comments (if fs.isEmpty then after ++ r.tail else after) .none
    let (tr, own) := trailing cs
    let multi' := r.stream && (pretty o r.ind used v []).contains '\n'
    start ++ r.ind ++ pre ++ pretty o r.ind used v (r.sep ++ trailingText tr ++ '\n' :: fields o r false multi' own w fs rest)
end

/--
**A file in the pretty layout**: its items at indent 0, a comma after each
when there is more than one, or when the options say the file is a stream
(`o.stream`, §11).
-/
def prettyFile (o : Options) (f : File) : Text :=
  let stream := o.stream || f.items.length > 1
  let (cs, w) := comments f.first .none
  items o ⟨[], if stream then [','] else [], stream, []⟩ true false cs w f.items []

/-! ## Formatting -/

/-- The three layouts of §11. -/
inductive Style where
  | pretty
  | compact
  | minimised
  deriving DecidableEq, Repr

def Style.ofString? : String → Option Style
  | "pretty" => some .pretty
  | "compact" => some .compact
  | "minimised" => some .minimised
  | _ => none

/-- A file in a layout; compact and minimised ignore the options but `stream`. -/
def File.format (style : Style) (o : Options) (f : File) : Text :=
  match style with
  | .pretty => prettyFile o f
  | .compact => lineFile .spaced o.stream f
  | .minimised => lineFile .tight o.stream f

/-- **The standard formatter** (§11): the text in a layout, or why it isn't a haus file. -/
def format (L : Limits) (style : Style) (o : Options) (input : Text) : Except Error Text :=
  (read L input).map (File.format style o)

/-! ## Examples -/

private def fmt (style : Style) (src : String) (o : Options := {}) : String :=
  match format {} style o src.toList with
  | .ok t => String.ofList t
  | .error e => s!"error {e.code}"

-- Spec §11's example, from a compact source.
#guard fmt .pretty "Person { name: \"John Doe\", tags: [\"a\", \"b\"], price: Money(7.90, EUR) }" ==
  "Person {\n  name: \"John Doe\",\n  tags: [\n    \"a\",\n    \"b\",\n  ],\n  price: Money(7.90, EUR),\n}\n"
-- Spellings kept; keys from their value.
#guard fmt .compact "{ \"a\": 0xFF, b: 1_000, \"c-d\": x\"0B 34\", e: \"\\u{41}\" }" ==
  "{ a: 0xFF, b: 1_000, \"c-d\": x\"0B 34\", e: \"\\u{41}\" }\n"
#guard fmt .minimised "{ a: 0xFF, b: [1, 2], c: T({ x: 1 }) }, Some(1)" == "{a:0xFF,b:[1,2],c:T{x:1}},\nSome(1),\n"
-- Comments: above, after the comma, at the end, moved above the entry.
#guard fmt .pretty "{ // c\n  a: 1, /* d */\n\n  b /* e */ : 2,\n  // f\n}" ==
  "{\n  // c\n  a: 1, /* d */\n\n  /* e */\n  b: 2,\n  // f\n}\n"
-- `Tag({ … })` is `Tag { … }`, the comments in its parentheses inside the braces.
#guard fmt .pretty "[After({ a: 1 } /* c */), Empty(/* n */ {})]" ==
  "[\n  After {\n    a: 1, /* c */\n  },\n  Empty {\n    /* n */\n  },\n]\n"
-- A comment in a positional payload breaks it.
#guard fmt .pretty "Pair(1 /* one */, 2)" == "Pair(\n  1, /* one */\n  2,\n)\n"
-- Streams: a blank line after a multi-line item, not after its comments.
#guard fmt .pretty "[1], // c\n2" == "[\n  1,\n], // c\n\n2,\n"
-- Comments only: kept in pretty, nothing in compact and minimised.
#guard fmt .pretty "// a\n\n/* b */" == "// a\n\n/* b */\n" && fmt .compact "// a\n" == "" && fmt .minimised "" == ""
-- CR LF in comments as LF; block strings from their value.
#guard fmt .pretty "[ /* a\r\n b */ \"\"\"\r\n  x\r\n  y\r\n  \"\"\" ]" ==
  "[\n  /* a\n b */\n  \"\"\"\n    x\n    y\n    \"\"\",\n]\n"
#guard fmt .compact "\"\"\"\n  x\n  \"\"\"" == "\"x\"\n"
-- The points of plans/zig-findings.md, as every binding formats them.
-- F16: a comment after the `}` of `Tag({ … })` on the last entry's line stays after it.
#guard fmt .pretty "S({ a: 1 } /* c */)" == "S {\n  a: 1, /* c */\n}\n"
-- F20b: a blank line between a key and the comment moved above its entry stays before the comment.
#guard fmt .pretty "{ a: 1,\n  e\n\n  : // c\n  1 }" == "{\n  a: 1,\n\n  // c\n  e: 1,\n}\n"
-- F20c: a blank line before the `}` stays before a comment after it that goes to the end.
#guard fmt .pretty "S({ a: 1\n\n} /* c */)" == "S {\n  a: 1,\n\n  /* c */\n}\n"
-- F20d: blank lines inside a positional payload don't break it.
#guard fmt .pretty "N(7,\n\n1)" == "N(7, 1)\n"
-- A blank line is two line breaks with only blanks between them: a comma between them makes none.
#guard fmt .pretty "[1\n,\n2]" == "[\n  1,\n  2,\n]\n" && fmt .pretty "[1\n\n,2]" == "[\n  1,\n\n  2,\n]\n"
-- Blank lines inside an entry (between its key and its value) are dropped; so are those at the start and end of a file.
#guard fmt .pretty "{ a: 1, b\n\n: 2 }" == "{\n  a: 1,\n  b: 2,\n}\n" && fmt .pretty "\n\n// c\n\n1\n\n" == "// c\n\n1\n"
-- After a comment with a line break, the comments lead the next entry; at most one blank line.
#guard fmt .pretty "[1, /* a\nb */ /* c */ 2]" == "[\n  1, /* a\nb */\n  /* c */\n  2,\n]\n"
#guard fmt .pretty "A, // c\n\n\nB" == "A, // c\n\nB,\n"
-- Several comments on one line above an entry: each on its own line.
#guard fmt .pretty "/* a */ /* b */\n1" == "/* a */\n/* b */\n1\n"
-- Told that the file is a stream (§11): a comma after a single item too, in every layout; nothing else changes.
#guard fmt .pretty "// log\nPaged { n: 1 } // first" { stream := true } == "// log\nPaged {\n  n: 1,\n}, // first\n"
#guard fmt .compact "Paged { n: 1 }" { stream := true } == "Paged { n: 1 },\n"
#guard fmt .minimised "Paged { n: 1 }" { stream := true } == "Paged{n:1},\n"
#guard fmt .pretty "A, B" { stream := true } == fmt .pretty "A, B"
#guard fmt .pretty "// only\n" { stream := true } == "// only\n" && fmt .compact "" { stream := true } == ""
-- Not haus: the parser's error.
#guard fmt .pretty "[1 2]" == "error missing-comma"

end Haus.Format
