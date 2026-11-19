import Haus.Json.SchemaBasedRoundTrip

/-!
# Record cases (spec §15, §16.3; design review B7)

A case with one argument whose type is a record is a **record case**,
however the record is written: `Circle { r: Float64 }`, `Circle ({ r:
Float64 })`, `Circle Disc` with `type Disc = { r: Float64 }`, through any
chain of aliases, or a name applied to arguments that gives a record
(`Found (Page Int)`). A type parameter is never one: `Ok a` of `Result e a`
writes its argument as `"value"`, also where `a` stands for a record.

In the model, `Tag T` written with a name or in parentheses is
`Case.named tag T`; `caseOf?` resolves it (`Case.resolve`): the record case
of the record `T` is through references (`recordOf?`), or else a case of one
positional argument. A type parameter, once applied, is `Case.positional`,
which resolves to itself.

- `record_case_named`: replacing a record case written in place,
  `Tag { … }`, by `Tag T` for any `T` that is the same record (in
  parentheses, by name, an alias chain, an applied generic's instance)
  changes nothing: decoding haus text, writing schema-based JSON and reading
  it give the same results, for every value and every JSON.
- `recordOf?_ref`, `recordOf?_mono`: `recordOf?` follows a chain of names.
- `positional_one_toJson`, `positional_one_fromJson`: a case of one
  positional argument writes `{"_tag": …, "value": J}` and reads it back
  with `J` the argument's own JSON, whatever its type, records included;
  `result_ok_toJson`, `result_ok_fromJson` for `Ok a` of `Result`.
- The round trip `schemaBased_round_trip` covers record cases written by name
  as it covers the others: its proof goes through `caseOf?`.

The JSON functions take the fuel `F` of the chains of `Maybe`s as an
argument; the theorems hold for every `F`. `toJson` takes `F` from the sizes
of the types (`nullFuel`), and a record written in place counts other nodes
than its name, so the two variants of `record_case_named` get different
values of `F` there; the choice doesn't matter (`Haus.Json.NullFuel`,
`record_case_named_json`).
-/

namespace Haus.Schema
open Haus

/-! ## Finding the record -/

theorem recordOf?_record (env : Env) (f : Nat) (cl : Bool) (fields : List Field) :
    recordOf? env f (.record cl fields) = some (cl, fields) := by
  cases f <;> rfl

/-- A name: its definition, with one step less. -/
theorem recordOf?_ref {env : Env} {f : Nat} {n : String} {t : Ty} (h : env.lookup n = some t) :
    recordOf? env (f + 1) (.ref n) = recordOf? env f t := by
  simp [recordOf?, h]

/-- More fuel finds the same record. -/
theorem recordOf?_mono {env : Env} {r : Bool × List Field} :
    ∀ {f g : Nat} {t : Ty}, f ≤ g → recordOf? env f t = some r → recordOf? env g t = some r
  | f, g, .record cl fields, _, h => by rw [recordOf?_record] at h ⊢; exact h
  | 0, _, .ref n, _, h => by simp [recordOf?] at h
  | f + 1, g + 1, .ref n, hle, h => by
    cases hl : env.lookup n with
    | none => simp [recordOf?, hl] at h
    | some t =>
      rw [recordOf?_ref hl] at h ⊢
      exact recordOf?_mono (by omega) h
  | f + 1, 0, .ref _, hle, _ => by omega
  | 0, _, .string, _, h | 0, _, .bytes, _, h | 0, _, .int _, _, h | 0, _, .float _, _, h
  | 0, _, .decimal, _, h | 0, _, .any, _, h | 0, _, .time _, _, h | 0, _, .secret _, _, h
  | 0, _, .array _, _, h | 0, _, .map _, _, h | 0, _, .variant _ _, _, h => by simp [recordOf?] at h
  | _ + 1, _, .string, _, h | _ + 1, _, .bytes, _, h | _ + 1, _, .int _, _, h | _ + 1, _, .float _, _, h
  | _ + 1, _, .decimal, _, h | _ + 1, _, .any, _, h | _ + 1, _, .time _, _, h | _ + 1, _, .secret _, _, h
  | _ + 1, _, .array _, _, h | _ + 1, _, .map _, _, h | _ + 1, _, .variant _ _, _, h => by simp [recordOf?] at h

/-- `Tag T` with `T` a record (through names) is the record case of that record. -/
theorem Case.resolve_named {env : Env} {tag : String} {t : Ty} {cl : Bool} {fields : List Field}
    (h : recordOf? env env.fuel t = some (cl, fields)) : (Case.named tag t).resolve env = .record tag cl fields := by
  simp [Case.resolve, h]

/-- `Tag T` with `T` not a record is a case of one positional argument. -/
theorem Case.resolve_named_none {env : Env} {tag : String} {t : Ty} (h : recordOf? env env.fuel t = none) :
    (Case.named tag t).resolve env = .positional tag [t] := by
  simp [Case.resolve, h]

/-- **A type parameter never makes a record case**: a positional case stays one, whatever its types are. -/
theorem Case.resolve_positional (env : Env) (tag : String) (ts : List Ty) :
    (Case.positional tag ts).resolve env = .positional tag ts := rfl

theorem Case.resolve_record (env : Env) (tag : String) (cl : Bool) (fields : List Field) :
    (Case.record tag cl fields).resolve env = .record tag cl fields := rfl

/-! ## Variants whose cases resolve alike -/

/-- `caseOf?` only sees the resolved cases. -/
theorem caseOf?_eq_find (env : Env) (cases : List Case) (tag : String) :
    caseOf? env cases tag = (cases.map (Case.resolve env)).find? (·.tag == tag) := by
  rw [caseOf?, List.find?_map]
  congr 2
  funext c
  simp [Case.resolve_tag]

theorem caseOf?_congr {env : Env} {cs cs' : List Case}
    (h : cs.map (Case.resolve env) = cs'.map (Case.resolve env)) (tag : String) :
    caseOf? env cs tag = caseOf? env cs' tag := by
  rw [caseOf?_eq_find, caseOf?_eq_find, h]

theorem isEnum_congr {env : Env} {cl : Bool} {cs cs' : List Case}
    (h : cs.map (Case.resolve env) = cs'.map (Case.resolve env)) :
    isEnum (.variant cl cs) = isEnum (.variant cl cs') := by
  have e : ∀ l : List Case, l.all Case.isBare = (l.map (Case.resolve env)).all Case.isBare := by
    intro l; simp [List.all_map, Function.comp_def, Case.resolve_isBare]
  cases cl
  · rfl
  · simp only [isEnum]; rw [e cs, e cs', h]

theorem whnf_variant {env : Env} {cl : Bool} {cs : List Case} :
    whnf env env.fuel (.variant cl cs) = .ok (0, .variant cl cs) := by
  simp [whnf, peel]

theorem boolTy_variant {env : Env} {cl : Bool} {cs : List Case} : boolTy env (.variant cl cs) = false := by
  unfold boolTy reachesBool; cases env.fuel <;> simp [peel]

theorem origin_variant {env : Env} {o : String} {cl : Bool} {cs : List Case} :
    origin env o (.variant cl cs) = inPlace o := by
  unfold origin lastRef; cases env.fuel <;> simp [peel]

theorem inPlace_inPlace (o : String) : inPlace (inPlace o) = inPlace o := by
  unfold inPlace; split <;> simp_all [preludeMaybe]

theorem origin_inPlace {env : Env} {o : String} {t : Ty} : origin env (inPlace o) t = origin env o t := by
  simp only [origin, inPlace_inPlace]

theorem toJsonF_inPlace {env : Env} {F : Nat} {o : String} {t : Ty} {x : Typed} :
    toJsonF env F (inPlace o) t x = toJsonF env F o t x := by
  simp only [toJsonF, origin_inPlace]

theorem fromJsonF_inPlace {env : Env} {F : Nat} {o : String} {t : Ty} {j : JSON} :
    fromJsonF env F (inPlace o) t j = fromJsonF env F o t j := by
  simp only [fromJsonF, origin_inPlace]

/-- Decoding haus text with a variant only sees its resolved cases. -/
theorem decode_variant_congr {env : Env} {cl : Bool} {cs cs' : List Case}
    (h : cs.map (Case.resolve env) = cs'.map (Case.resolve env)) (v : Value) :
    decode env (.variant cl cs) v = decode env (.variant cl cs') v := by
  rw [decode, decode, whnf_variant, whnf_variant]
  cases v
  case variant tag args => simp only [hidden, caseOf?_congr h tag]
  all_goals rfl

/-- Writing a value of a variant that isn't a `Maybe` only sees its resolved cases. -/
theorem toJsonC_variant_congr {env : Env} {F : Nat} {b : Bool} {o : String} {cl : Bool} {cs cs' : List Case}
    (h : cs.map (Case.resolve env) = cs'.map (Case.resolve env))
    (hm : maybeOf? (.variant cl cs) = none) (hm' : maybeOf? (.variant cl cs') = none) :
    ∀ x : Typed, toJsonC env F b o (.variant cl cs) x = toJsonC env F b o (.variant cl cs') x
  | .secret x => by simp only [toJsonC]; exact toJsonC_variant_congr h hm hm' x
  | .case tag args => by
    rw [toJsonC.eq_def, toJsonC.eq_def]
    simp only [nullArg?_none hm, nullArg?_none hm', isEnum_congr (cl := cl) h, caseOf?_congr h tag, mismatch,
      Ty.name]
  | .str _ | .bytes _ | .int _ | .float _ _ | .decimal _ | .time _ _ | .any _ | .arr _ | .map _ | .record _
  | .unknown _ _ => by rw [toJsonC.eq_def, toJsonC.eq_def] <;> simp only [mismatch, Ty.name]

/-- Reading JSON with a variant that isn't a `Maybe` only sees its resolved cases. -/
theorem fromJsonC_variant_congr {env : Env} {F : Nat} {b : Bool} {o : String} {cl : Bool} {cs cs' : List Case}
    (h : cs.map (Case.resolve env) = cs'.map (Case.resolve env))
    (hm : maybeOf? (.variant cl cs) = none) (hm' : maybeOf? (.variant cl cs') = none) (j : JSON) :
    fromJsonC env F b o (.variant cl cs) j = fromJsonC env F b o (.variant cl cs') j := by
  rw [fromJsonC_none j (nullArg?_none hm), fromJsonC_none j (nullArg?_none hm'), readCore.eq_def, readCore.eq_def]
  cases j
  all_goals (try simp only [isEnum_congr (cl := cl) h, caseOf?_congr h])

/-- The same for `toJsonF` and `fromJsonF` with the variant itself as the type. -/
theorem toJsonF_variant_congr {env : Env} {F : Nat} {o : String} {cl : Bool} {cs cs' : List Case}
    (h : cs.map (Case.resolve env) = cs'.map (Case.resolve env))
    (hm : maybeOf? (.variant cl cs) = none) (hm' : maybeOf? (.variant cl cs') = none) (x : Typed) :
    toJsonF env F o (.variant cl cs) x = toJsonF env F o (.variant cl cs') x := by
  rw [toJsonF_eq x whnf_variant, toJsonF_eq x whnf_variant, boolTy_variant, boolTy_variant,
    origin_variant, origin_variant]
  exact toJsonC_variant_congr h hm hm' x

theorem fromJsonF_variant_congr {env : Env} {F : Nat} {o : String} {cl : Bool} {cs cs' : List Case}
    (h : cs.map (Case.resolve env) = cs'.map (Case.resolve env))
    (hm : maybeOf? (.variant cl cs) = none) (hm' : maybeOf? (.variant cl cs') = none) (j : JSON) :
    fromJsonF env F o (.variant cl cs) j = fromJsonF env F o (.variant cl cs') j := by
  rw [fromJsonF_eq j whnf_variant, fromJsonF_eq j whnf_variant, boolTy_variant, boolTy_variant,
    origin_variant, origin_variant, fromJsonC_variant_congr h hm hm' j]
  rfl

/-- A variant with a case of a record payload, in place or by name, is not the prelude's `Maybe`. -/
theorem maybeOf?_of_mem {cl : Bool} {cs : List Case} {c : Case} (hc : c ∈ cs)
    (hb : ∀ tag, c ≠ .bare tag) (hp : ∀ tag ts, c ≠ .positional tag ts) : maybeOf? (.variant cl cs) = none := by
  cases e : maybeOf? (.variant cl cs) with
  | none => rfl
  | some a =>
    cases maybeOf?_some e
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hc
    rcases hc with rfl | rfl
    · exact absurd rfl (hb _)
    · exact absurd rfl (hp _ _)

/-! ## Naming a record changes nothing -/

/--
**Naming a record changes nothing** (§15, §16.3). In a variant, the case
`Tag T`, with `T` the record `{ … }` through names (`recordOf?`: in
parentheses, `type Disc = { … }`, an alias chain, an applied generic's
instance), and the case `Tag { … }` written in place are the same: decoding
haus text, writing schema-based JSON (for every decoded value) and reading it
(for every JSON) give the same results, for every fuel of the `Maybe` chains.
-/
theorem record_case_named {env : Env} {cl : Bool} {pre post : List Case} {tag : String} {t : Ty}
    {rc : Bool} {fields : List Field} (h : recordOf? env env.fuel t = some (rc, fields)) :
    (∀ v, decode env (.variant cl (pre ++ .named tag t :: post)) v =
      decode env (.variant cl (pre ++ .record tag rc fields :: post)) v) ∧
    (∀ F o x, toJsonF env F o (.variant cl (pre ++ .named tag t :: post)) x =
      toJsonF env F o (.variant cl (pre ++ .record tag rc fields :: post)) x) ∧
    (∀ F o j, fromJsonF env F o (.variant cl (pre ++ .named tag t :: post)) j =
      fromJsonF env F o (.variant cl (pre ++ .record tag rc fields :: post)) j) := by
  have hs : (pre ++ .named tag t :: post).map (Case.resolve env) =
      (pre ++ .record tag rc fields :: post).map (Case.resolve env) := by
    simp [Case.resolve_named h, Case.resolve_record]
  have hm : maybeOf? (.variant cl (pre ++ .named tag t :: post)) = none :=
    maybeOf?_of_mem (c := .named tag t) (by simp) (by simp) (by simp)
  have hm' : maybeOf? (.variant cl (pre ++ .record tag rc fields :: post)) = none :=
    maybeOf?_of_mem (c := .record tag rc fields) (by simp) (by simp) (by simp)
  exact ⟨decode_variant_congr hs, fun F o => toJsonF_variant_congr hs hm hm',
    fun F o => fromJsonF_variant_congr hs hm hm'⟩

/-- The same through a name: `Tag N` with `type N = …` a chain of names that ends in the record. -/
theorem record_case_ref {env : Env} {cl : Bool} {pre post : List Case} {tag n : String} {t : Ty}
    {rc : Bool} {fields : List Field} (hl : env.lookup n = some t) {f : Nat} (hf : f + 1 ≤ env.fuel)
    (h : recordOf? env f t = some (rc, fields)) :
    (∀ v, decode env (.variant cl (pre ++ .named tag (.ref n) :: post)) v =
      decode env (.variant cl (pre ++ .record tag rc fields :: post)) v) ∧
    (∀ F o x, toJsonF env F o (.variant cl (pre ++ .named tag (.ref n) :: post)) x =
      toJsonF env F o (.variant cl (pre ++ .record tag rc fields :: post)) x) ∧
    (∀ F o j, fromJsonF env F o (.variant cl (pre ++ .named tag (.ref n) :: post)) j =
      fromJsonF env F o (.variant cl (pre ++ .record tag rc fields :: post)) j) :=
  record_case_named (recordOf?_mono hf (by rw [recordOf?_ref hl]; exact h))

/-! ## A type parameter is not a record -/

/--
**One positional argument is written as `value`**, whatever its type: the
JSON of `Tag x` is `{"_tag": "Tag", "value": J}` with `J` the JSON of `x` by
its own type, a record too. This is how `Ok a` of `Result e a` and `Box a` of
`type GenBox a = < Box a >` are written for every argument (§16.3).
-/
theorem positional_one_toJson {env : Env} {F : Nat} {o : String} {cl : Bool} {cs : List Case}
    {tag tag' : String} {t : Ty} (y : Typed)
    (hc : caseOf? env cs tag = some (.positional tag' [t])) (hm : maybeOf? (.variant cl cs) = none) :
    toJsonF env F o (.variant cl cs) (.case tag [y]) =
      (under (.arg tag 0) (toJsonF env F o t y)).map fun j => .obj [("_tag", .str tag), ("value", j)] := by
  rw [toJsonF_eq _ whnf_variant, boolTy_variant, origin_variant, ← toJsonF_inPlace (o := o)]
  rw [toJsonC.eq_def]
  simp only [Bool.false_eq_true, ↓reduceIte, nullArg?_none hm, isEnum_false (closed := cl) hc rfl, hc]
  rfl

/-- And it is read back from `value` alone. -/
theorem positional_one_fromJson {env : Env} {F : Nat} {o : String} {cl : Bool} {cs : List Case}
    {tag tag' : String} {t : Ty} (j : JSON)
    (hc : caseOf? env cs tag = some (.positional tag' [t])) (hm : maybeOf? (.variant cl cs) = none)
    (htag : isTag tag.toList = true) :
    fromJsonF env F o (.variant cl cs) (.obj [("_tag", .str tag), ("value", j)]) =
      (under (.key "value") (fromJsonF env F o t j)).map fun y => .case tag [y] := by
  rw [fromJsonF_eq _ whnf_variant, boolTy_variant, origin_variant, fromJsonC_none _ (nullArg?_none hm),
    readCore.eq_def]
  simp only [Bool.false_eq_true, ↓reduceIte, isEnum_false (closed := cl) hc rfl, List.lookup, beq_self_eq_true, htag,
    Bool.not_true, hc, List.length_cons, List.length_nil, hidden]
  rw [memberValue, memberValue]
  simp only [show ("_tag" = "value") = False by decide, ↓reduceIte, fromJsonF_inPlace]
  cases fromJsonF env F o t j <;> simp [under, atExtra]

theorem caseOf?_result_ok (env : Env) (e a : Ty) :
    caseOf? env [.positional "Err" [e], .positional "Ok" [a]] "Ok" = some (.positional "Ok" [a]) := by
  simp [caseOf?, Case.tag, Case.resolve]

theorem maybeOf?_result (e a : Ty) : maybeOf? (Ty.result e a) = none := rfl

/-- **`Ok a` of `Result` is never a record case**: `{"_tag": "Ok", "value": J}`, for every `a`. -/
theorem result_ok_toJson (env : Env) (F : Nat) (o : String) (e a : Ty) (y : Typed) :
    toJsonF env F o (Ty.result e a) (.case "Ok" [y]) =
      (under (.arg "Ok" 0) (toJsonF env F o a y)).map fun j => .obj [("_tag", .str "Ok"), ("value", j)] :=
  positional_one_toJson y (caseOf?_result_ok env e a) (maybeOf?_result e a)

theorem result_ok_fromJson (env : Env) (F : Nat) (o : String) (e a : Ty) (j : JSON) :
    fromJsonF env F o (Ty.result e a) (.obj [("_tag", .str "Ok"), ("value", j)]) =
      (under (.key "value") (fromJsonF env F o a j)).map fun y => .case "Ok" [y] :=
  positional_one_fromJson j (caseOf?_result_ok env e a) (maybeOf?_result e a) (by decide)

/-! ## Examples (the suite's `Boxed`, `AliasBox`, `Found`, `GenRec`) -/

private def boxEnv : Env := ⟨[("BoxRec", .record false [.mk "w" false (.int (.signed 32))]),
  ("BoxAlias", .ref "BoxRec"),
  ("Page(Int32)", .record false [.mk "items" false (.array (.int (.signed 32)))]),
  ("Boxed", .variant false [.named "Box" (.ref "BoxRec")]),
  ("AliasBox", .variant false [.named "Box" (.ref "BoxAlias")]),
  ("ParenBox", .variant false [.named "Box" (.record false [.mk "w" false (.int (.signed 32))])]),
  ("Inline", .variant false [.record "Box" false [.mk "w" false (.int (.signed 32))]]),
  ("Found", .variant false [.named "Found" (.ref "Page(Int32)")]),
  ("GenRec", .variant false [.positional "Box" [.ref "BoxRec"]])]⟩

private def written (t src : String) : Option String :=
  match Parser.parse {} src.toList with
  | .ok [v] =>
    match decode boxEnv (.ref t) v with
    | .ok x => (writeJson boxEnv (.ref t) x).toOption.map String.ofList
    | .error _ => none
  | _ => none

private def readCode (t json : String) : Option Code :=
  match readJson {} boxEnv (.ref t) json.toList with
  | .error e => e.code
  | .ok _ => none

#guard ["Boxed", "AliasBox", "ParenBox", "Inline"].all fun t => written t "Box { w: 1 }" == some "{\"_tag\":\"Box\",\"w\":1}"
#guard written "Found" "Found { items: [1, 2] }" == some "{\"_tag\":\"Found\",\"items\":[1,2]}"
#guard written "GenRec" "Box { w: 1 }" == some "{\"_tag\":\"Box\",\"value\":{\"w\":1}}"
#guard readCode "Boxed" "{\"_tag\":\"Box\",\"value\":{\"w\":1}}" == some .missingField
#guard readCode "GenRec" "{\"_tag\":\"Box\",\"value\":{\"w\":1},\"w\":1}" == some .unexpectedMember
#guard written "Boxed" "Box(1)" == none && written "Boxed" "Box(1, 2)" == none

end Haus.Schema
