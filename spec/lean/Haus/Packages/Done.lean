import Haus.Packages.Steps
import Haus.Packages.Props
import Haus.Packages.Closed

/-!
# What a successful run has checked (a step of R3)

`Local V P T`: loading the target `T` passes every check of its own, as a
property of the tree alone (`Haus.Packages.Steps`): its file is a regular
file within the limit that scans, a copy has a valid manifest, a version
its `package.json` agrees with, a `schema.haus` and no file imports; and
each of its imports resolves, every target it loads has `P` and defines
the types imported (`ImpOk`).

`Good V δ κ` holds of every state of a successful run (`load_good`): every
target finished (`St.finished`, in the order the run finished them) is
`Local`, with `P` "finished before it", so the finished targets with their
imports form a graph without cycles; each file done and each copy done is
finished, with the types its file defines, and each copy's class is its
package (`Corr`: the name, version and bytes of its files); and the
targets started are at most the schema files counted (`δ`: one more while
a target is started and not yet counted).

So the last state of a successful run is closed: every
target it finished passes its checks, and imports only targets finished
before it. That is what a run in another order is compared with
(`Haus.Packages.Walk`).
-/

namespace Haus.Packages

/-! ## The checks of one target -/

/-- The types `load` gives a target. -/
def typesV (V : View) : Target → Option (List String)
  | .file p => ((fileBytes V.tree p V.limits.schemaFile).bind decodeV).map (·.types)
  | .copy d =>
    match pkgFile V.tree d "schema.haus" V.limits.schemaFile with
    | some (some bs) => (decodeV bs).map (·.types)
    | _ => none

/-- The names of a schema file an import of a file names (`./x` is `x.schema.haus`). -/
def fileComps (path : String) : List String :=
  (splitPath path).dropLast ++ [(splitPath path).getLastD "" ++ ".schema.haus"]

/-- A candidate `dir` for the import `imp` of `name`: its package has that name and major, and the names. -/
def CandOk (V : View) (P : Target → Prop) (imp : Import) (name : String) (major : Option String) (dir : Path) :
    Prop :=
  ∃ m, manifestV V dir = some (some m) ∧ m.name = name ∧ (∀ n, major = some n → majorOf m.version = n) ∧
    P (.copy dir) ∧ ∃ ts, typesV V (.copy dir) = some ts ∧ namesOk imp ts

/--
One import of `importer` resolves: every target it loads has `P` and
defines the names imported. (A package's import of a file is an error.)
-/
def ImpOk (V : View) (P : Target → Prop) (importer : Importer) (imp : Import) : Prop :=
  match imp.module with
  | .std _ => True
  | .file path =>
    match importer with
    | .pkg .. => False
    | .app p => ∃ real, resolve V.tree maxLinks p.dropLast (fileComps path) = .ok real ∧
        inPackage V.tree real = none ∧ (real.getLast?.any (·.endsWith ".schema.haus")) = true ∧
        V.tree.kindAt? real = some .file ∧ P (.file real) ∧ ∃ ts, typesV V (.file real) = some ts ∧ namesOk imp ts
  | .pkg name major => ∃ cands, candV V importer name = some cands ∧ ∀ c ∈ cands, CandOk V P imp name major c.1

theorem CandOk.mono {V : View} {P P' : Target → Prop} {imp : Import} {name : String} {major : Option String}
    {dir : Path} (h : CandOk V P imp name major dir) (hP : ∀ T, P T → P' T) : CandOk V P' imp name major dir := by
  obtain ⟨m, h1, h2, h3, h4, h5⟩ := h
  exact ⟨m, h1, h2, h3, hP _ h4, h5⟩

/-- What a copy's `package.json` declares, if `npm` is on or versions are checked. -/
def npmOf (V : View) (dir : Path) : Option (Option NpmInfo) :=
  if (V.mode.npm || V.checkVersions) = true then packageJsonV V dir else some none

/-- The SHOULD check of "Package versions" (§13.3) passes. -/
def VersionOk (V : View) (m : Manifest) (npm : Option NpmInfo) : Prop :=
  V.checkVersions = true → ∀ v, npm.bind (·.version) = some v → v = m.version

/-- Loading `T` passes every check of its own, and its imports resolve to targets with `P`. -/
def Local (V : View) (P : Target → Prop) : Target → Prop
  | .file p => ∃ bs sc, fileBytes V.tree p V.limits.schemaFile = some bs ∧ decodeV bs = some sc ∧
      ∀ imp ∈ sc.imports, ImpOk V P (.app p) imp
  | .copy d => ∃ m npm bs sc, manifestV V d = some (some m) ∧ npmOf V d = some npm ∧ VersionOk V m npm ∧
      pkgFile V.tree d "schema.haus" V.limits.schemaFile = some (some bs) ∧ decodeV bs = some sc ∧
      sc.imports.find? Import.isFile = none ∧ ∀ imp ∈ sc.imports, ImpOk V P (.pkg d m.name npm) imp

/-- The class of the copy `d`: its package's name, version, files and types. -/
def Corr (V : View) (d : Path) (c : Class) : Prop :=
  ∃ m bs sc, manifestV V d = some (some m) ∧ pkgFile V.tree d "schema.haus" V.limits.schemaFile = some (some bs) ∧
    decodeV bs = some sc ∧ c.name = m.name ∧ c.version = m.version ∧ c.manifest = m.bytes ∧ c.schema = bs ∧
    c.types = sc.types

theorem ImpOk.mono {V : View} {P P' : Target → Prop} {importer : Importer} {imp : Import}
    (h : ImpOk V P importer imp) (hP : ∀ T, P T → P' T) : ImpOk V P' importer imp := by
  unfold ImpOk at *
  split at h
  · trivial
  · split at h
    · exact h
    · obtain ⟨real, h1, h2, h3, h4, h5, h6⟩ := h
      exact ⟨real, h1, h2, h3, h4, hP _ h5, h6⟩
  · obtain ⟨cands, hc, h⟩ := h
    exact ⟨cands, hc, fun c hc => (h c hc).mono hP⟩

theorem Local.mono {V : View} {P P' : Target → Prop} {T : Target} (h : Local V P T) (hP : ∀ T, P T → P' T) :
    Local V P' T := by
  cases T with
  | file p =>
    obtain ⟨bs, sc, h1, h2, h3⟩ := h
    exact ⟨bs, sc, h1, h2, fun imp hi => (h3 imp hi).mono hP⟩
  | copy d =>
    obtain ⟨m, npm, bs, sc, h1, h2, h3, h4, h5, h6, h7⟩ := h
    exact ⟨m, npm, bs, sc, h1, h2, h3, h4, h5, h6, fun imp hi => (h7 imp hi).mono hP⟩

/-! ## The state of a run -/

/-- The targets started: a file or copy marked as being loaded (once each, even after it is done). -/
def startedOf (κ : Core) : List Target :=
  κ.files.filterMap (fun e => if e.2.isNone then some (.file e.1) else none) ++
  κ.copies.filterMap (fun e => if e.2 = .loading then some (.copy e.1) else none)

/-- `T'` was finished before `T` (when `T` isn't finished: finished at all). -/
def Before (fin : List Target) (T T' : Target) : Prop := T' ∈ fin ∧ fin.idxOf T' < fin.idxOf T

/-- What holds of every state of a successful run; `δ` targets started but not yet counted. -/
structure Good (V : View) (δ : Nat) (κ : Core) : Prop where
  nodup : κ.finished.Nodup
  started : ∀ T ∈ κ.finished, T ∈ startedOf κ
  count : (startedOf κ).length ≤ κ.count + δ
  local_ : ∀ T ∈ κ.finished, Local V (Before κ.finished T) T
  files : ∀ p ts, κ.files.lookup p = some (some ts) → .file p ∈ κ.finished ∧ typesV V (.file p) = some ts
  copies : ∀ d k, κ.copies.lookup d = some (.done k) →
    .copy d ∈ κ.finished ∧ ∃ c, κ.classes.list[k]? = some c ∧ Corr V d c
  finCls : ∀ d, .copy d ∈ κ.finished → ∃ c ∈ κ.classes.list, Corr V d c
  clsFin : ∀ c ∈ κ.classes.list, ∃ d, .copy d ∈ κ.finished ∧ Corr V d c

/-- A state that a later one grows from. -/
structure Grows (κ κ' : Core) : Prop where
  finished : κ.finished <+: κ'.finished
  classes : κ.classes.list <+: κ'.classes.list
  started : ∀ T ∈ startedOf κ, T ∈ startedOf κ'

theorem Grows.refl (κ : Core) : Grows κ κ := ⟨List.prefix_refl _, List.prefix_refl _, fun _ h => h⟩

theorem Grows.trans {κ₁ κ₂ κ₃ : Core} (h₁ : Grows κ₁ κ₂) (h₂ : Grows κ₂ κ₃) : Grows κ₁ κ₃ :=
  ⟨h₁.finished.trans h₂.finished, h₁.classes.trans h₂.classes, fun T h => h₂.started T (h₁.started T h)⟩

/-! ## Lists -/

section Lists
variable {α β : Type} [BEq α] [LawfulBEq α]

theorem lookup_cons_self (a : α) (b : β) (l : List (α × β)) : ((a, b) :: l).lookup a = some b := by
  simp

theorem lookup_cons_of_ne {a a' : α} (b : β) (l : List (α × β)) (h : a' ≠ a) :
    ((a, b) :: l).lookup a' = l.lookup a' := by
  simp [List.lookup_cons, beq_eq_false_iff_ne.mpr h]

theorem not_mem_of_lookup_none {a : α} {b : β} {l : List (α × β)} (h : l.lookup a = none) : (a, b) ∉ l := by
  intro hm
  induction l with
  | nil => simp at hm
  | cons x xs ih =>
    obtain ⟨k, v⟩ := x
    by_cases e : a = k
    · subst e; simp at h
    · rw [lookup_cons_of_ne _ _ e] at h
      rcases List.mem_cons.mp hm with hm | hm
      · simp at hm; exact e hm.1
      · exact ih h hm

end Lists

theorem prefix_addNew (l : List Target) (T : Target) : l <+: addNew l T := by
  unfold addNew; split
  · exact List.prefix_refl _
  · exact List.prefix_append _ _

theorem mem_addNew (l : List Target) (T : Target) : T ∈ addNew l T := by
  unfold addNew; split
  · assumption
  · simp

theorem mem_addNew_iff {l : List Target} {T T' : Target} : T' ∈ addNew l T ↔ T' ∈ l ∨ T' = T := by
  unfold addNew; split
  · constructor
    · exact Or.inl
    · rintro (h | rfl) <;> assumption
  · simp

theorem nodup_addNew {l : List Target} (h : l.Nodup) (T : Target) : (addNew l T).Nodup := by
  unfold addNew; split
  · exact h
  · rename_i hT
    exact List.nodup_append.mpr ⟨h, List.nodup_cons.mpr ⟨by simp, List.nodup_nil⟩, fun a ha b hb => by
      simp at hb; subst hb; rintro rfl; exact hT ha⟩

theorem prefix_getElem? {α : Type} {l l' : List α} (h : l <+: l') {i : Nat} {x : α} (hx : l[i]? = some x) :
    l'[i]? = some x := by
  obtain ⟨r, rfl⟩ := h
  rw [List.getElem?_append_left (List.getElem?_eq_some_iff.mp hx).1, hx]

theorem idxOf_prefix {l l' : List Target} (h : l <+: l') {T : Target} (hT : T ∈ l) : l'.idxOf T = l.idxOf T := by
  obtain ⟨r, rfl⟩ := h
  rw [List.idxOf_append, if_pos' hT]

theorem idxOf_addNew_self {l : List Target} {T : Target} (h : T ∉ l) : (addNew l T).idxOf T = l.length := by
  unfold addNew
  rw [if_neg' h, List.idxOf_append, if_neg' h]
  simp

theorem Before.mono {l l' : List Target} (h : l <+: l') {T T' : Target} (hT : T ∈ l) (hb : Before l T T') :
    Before l' T T' :=
  ⟨h.subset hb.1, by rw [idxOf_prefix h hb.1, idxOf_prefix h hT]; exact hb.2⟩

/-- A target finished now, before `T` is added at the end. -/
theorem Before.of_new {l : List Target} {T T' : Target} (hT : T ∉ l) (h : T' ∈ l) : Before (addNew l T) T T' := by
  refine ⟨(prefix_addNew l T).subset h, ?_⟩
  rw [idxOf_prefix (prefix_addNew l T) h, idxOf_addNew_self hT]
  exact List.idxOf_lt_length_iff.mpr h

theorem Good.local_mono {V : View} {δ : Nat} {κ : Core} {fin : List Target} (h : Good V δ κ) (hf : κ.finished <+: fin)
    {T : Target} (hT : T ∈ κ.finished) : Local V (Before fin T) T :=
  (h.local_ T hT).mono fun _ hb => hb.mono hf hT

theorem parseManifest_bytes {b : List UInt8} {o : String} {m : Manifest} (h : parseManifest b o = .ok m) :
    m.bytes = b := by
  unfold parseManifest at h
  revert h
  rcases utf8 b with _ | t
  · intro h; cases h
  try dsimp only
  rcases Parser.parse {} t with e | vs
  · intro h; cases h
  try dsimp only
  rcases vs with _ | ⟨v, _ | ⟨w, rest⟩⟩
  · intro h; cases h
  · cases v <;> try (intro h; cases h)
    rename_i fs
    try dsimp only
    generalize List.lookup "name" fs = a
    generalize List.lookup "version" fs = b'
    rcases a with _ | x <;> rcases b' with _ | y <;> try (intro h; cases h)
    · cases x <;> intro h <;> cases h
    · cases x <;> cases y <;> try (intro h; cases h)
      rename_i n v
      by_cases h1 : isPackageName n <;> by_cases h2 : isSemver v <;> simp [h1, h2]
      intro h; subst h; rfl
  · cases v <;> intro h <;> cases h

theorem manifestV_parse {V : View} {d : Path} {m : Manifest} (h : manifestV V d = some (some m)) :
    parseManifest? m.bytes = some m := by
  unfold manifestV at h
  rcases hp : pkgFile V.tree d "package.haus" V.limits.manifest with _ | _ | bytes <;> rw [hp] at h <;> simp at h
  unfold parseManifest? at h ⊢
  revert h
  split
  · rename_i m' hm'
    intro h; cases h
    rw [parseManifest_bytes hm', hm']
  · intro h; cases h

/-! ## The state, step by step -/

def Core.markFile (κ : Core) (p : Path) : Core := { κ with files := (p, none) :: κ.files }
def Core.finishFile (κ : Core) (p : Path) (ts : List String) : Core :=
  { κ with files := (p, some ts) :: κ.files, finished := addNew κ.finished (.file p) }
def Core.markCopy (κ : Core) (d : Path) : Core := { κ with copies := (d, .loading) :: κ.copies }
def Core.finishCopy (κ : Core) (d : Path) (cs : Classes) (i : Nat) : Core :=
  { κ with classes := cs, copies := (d, .done i) :: κ.copies, finished := addNew κ.finished (.copy d) }
def Core.countUp (κ : Core) : Core := { κ with count := κ.count + 1 }

theorem startedOf_markFile (κ : Core) (p : Path) : startedOf (κ.markFile p) = .file p :: startedOf κ := by
  simp [startedOf, Core.markFile]

theorem startedOf_finishFile (κ : Core) (p : Path) (ts : List String) :
    startedOf (κ.finishFile p ts) = startedOf κ := by
  simp [startedOf, Core.finishFile]

theorem startedOf_markCopy (κ : Core) (d : Path) :
    startedOf (κ.markCopy d) = κ.files.filterMap (fun e => if e.2.isNone then some (.file e.1) else none) ++
      .copy d :: κ.copies.filterMap (fun e => if e.2 = .loading then some (.copy e.1) else none) := by
  simp [startedOf, Core.markCopy]

theorem perm_startedOf_markCopy (κ : Core) (d : Path) :
    List.Perm (startedOf (κ.markCopy d)) (.copy d :: startedOf κ) := by
  rw [startedOf_markCopy]; exact List.perm_middle

theorem mem_startedOf_markCopy {κ : Core} {d : Path} {T : Target} :
    T ∈ startedOf (κ.markCopy d) ↔ T = .copy d ∨ T ∈ startedOf κ := by
  rw [(perm_startedOf_markCopy κ d).mem_iff, List.mem_cons]

theorem length_startedOf_markCopy (κ : Core) (d : Path) :
    (startedOf (κ.markCopy d)).length = (startedOf κ).length + 1 := by
  rw [(perm_startedOf_markCopy κ d).length_eq, List.length_cons]

theorem startedOf_finishCopy (κ : Core) (d : Path) (cs : Classes) (i : Nat) :
    startedOf (κ.finishCopy d cs i) = startedOf κ := by
  simp [startedOf, Core.finishCopy]

theorem startedOf_countUp (κ : Core) : startedOf κ.countUp = startedOf κ := rfl

section
variable {V : View} {δ : Nat} {κ : Core}

theorem Good.markFile {p : Path} (h : Good V δ κ) (hp : κ.files.lookup p = none) :
    Good V (δ + 1) (κ.markFile p) ∧ Grows κ (κ.markFile p) := by
  refine ⟨⟨h.nodup, fun T hT => ?_, ?_, h.local_, fun p' ts hl => ?_, h.copies, h.finCls, h.clsFin⟩,
    (Grows.refl κ).finished, (Grows.refl κ).classes, fun T hT => ?_⟩
  · rw [startedOf_markFile]; exact List.mem_cons_of_mem _ (h.started T hT)
  · rw [startedOf_markFile]; have := h.count; simp only [List.length_cons]; simp only [Core.markFile]; omega
  · by_cases e : p' = p
    · subst e; simp [Core.markFile] at hl
    · exact h.files p' ts (by simpa [Core.markFile, lookup_cons_of_ne _ _ e] using hl)
  · rw [startedOf_markFile]; exact List.mem_cons_of_mem _ hT

theorem Good.markCopy {d : Path} (h : Good V δ κ) (hd : κ.copies.lookup d = none) :
    Good V (δ + 1) (κ.markCopy d) ∧ Grows κ (κ.markCopy d) := by
  refine ⟨⟨h.nodup, fun T hT => ?_, ?_, h.local_, h.files, fun d' k hl => ?_, h.finCls, h.clsFin⟩,
    (Grows.refl κ).finished, (Grows.refl κ).classes, fun T hT => ?_⟩
  · exact mem_startedOf_markCopy.mpr (Or.inr (h.started T hT))
  · rw [length_startedOf_markCopy]; have := h.count; simp only [Core.markCopy]; omega
  · by_cases e : d' = d
    · subst e; simp [Core.markCopy] at hl
    · exact h.copies d' k (by simpa [Core.markCopy, lookup_cons_of_ne _ _ e] using hl)
  · exact mem_startedOf_markCopy.mpr (Or.inr hT)

theorem Good.countUp (h : Good V (δ + 1) κ) : Good V δ κ.countUp ∧ Grows κ κ.countUp :=
  ⟨⟨h.nodup, h.started, by have := h.count; rw [startedOf_countUp]; simp only [Core.countUp]; omega,
    h.local_, h.files, h.copies, h.finCls, h.clsFin⟩, ⟨List.prefix_refl _, List.prefix_refl _, fun _ h => h⟩⟩

/-- A target's own `Local`, with its imports finished now; or it is finished already. -/
def NewLocal (V : View) (κ : Core) (T : Target) : Prop := T ∈ κ.finished ∨ Local V (· ∈ κ.finished) T

theorem Good.local_addNew (h : Good V 0 κ) {T : Target} (hT : NewLocal V κ T) :
    ∀ T' ∈ addNew κ.finished T, Local V (Before (addNew κ.finished T) T') T' := by
  intro T' hT'
  rcases mem_addNew_iff.mp hT' with hT' | rfl
  · exact h.local_mono (prefix_addNew _ _) hT'
  · rcases hT with hT | hT
    · exact h.local_mono (prefix_addNew _ _) hT
    · by_cases hin : T' ∈ κ.finished
      · exact h.local_mono (prefix_addNew _ _) hin
      · exact hT.mono fun _ h => Before.of_new hin h

theorem Good.finishFile {p : Path} {ts : List String} (h : Good V 0 κ) (hs : .file p ∈ startedOf κ)
    (ht : typesV V (.file p) = some ts) (hl : NewLocal V κ (.file p)) :
    Good V 0 (κ.finishFile p ts) ∧ Grows κ (κ.finishFile p ts) ∧ .file p ∈ (κ.finishFile p ts).finished := by
  have hpre := prefix_addNew κ.finished (.file p)
  refine ⟨⟨nodup_addNew h.nodup _, fun T hT => ?_, ?_, h.local_addNew hl, fun p' ts' hp => ?_,
    fun d k hk => ?_, fun d hd => ?_, fun c hc => ?_⟩, ⟨hpre, List.prefix_refl _, fun T hT => ?_⟩, mem_addNew _ _⟩
  · rw [startedOf_finishFile]
    rcases mem_addNew_iff.mp hT with hT | rfl
    · exact h.started T hT
    · exact hs
  · rw [startedOf_finishFile]; exact h.count
  · by_cases e : p' = p
    · subst e
      simp only [Core.finishFile, lookup_cons_self, Option.some.injEq] at hp
      subst hp
      exact ⟨mem_addNew _ _, ht⟩
    · obtain ⟨h1, h2⟩ := h.files p' ts' (by simpa [Core.finishFile, lookup_cons_of_ne _ _ e] using hp)
      exact ⟨hpre.subset h1, h2⟩
  · obtain ⟨h1, h2⟩ := h.copies d k hk
    exact ⟨hpre.subset h1, h2⟩
  · rcases mem_addNew_iff.mp hd with hd | hd
    · exact h.finCls d hd
    · cases hd
  · obtain ⟨d, h1, h2⟩ := h.clsFin c hc
    exact ⟨d, hpre.subset h1, h2⟩
  · rw [startedOf_finishFile]; exact hT

theorem Corr.of_same {d d' : Path} {c c' : Class} (h : Corr V d c) (h' : Corr V d' c')
    (hn : c'.name = c.name) (hm : c'.manifest = c.manifest) (hs : c'.schema = c.schema) : Corr V d c' := by
  obtain ⟨m, bs, sc, h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
  obtain ⟨m', bs', sc', h1', h2', h3', h4', h5', h6', h7', h8'⟩ := h'
  have hmm : m' = m := by
    have a := manifestV_parse h1
    have b := manifestV_parse h1'
    rw [← h6', hm, h6, a] at b
    exact (Option.some.inj b).symm
  have hsc : sc' = sc := by
    rw [← h7', hs, h7, h3] at h3'
    exact (Option.some.inj h3').symm
  subst hmm hsc
  exact ⟨m', bs, sc', h1, h2, h3, hn.trans h4, h5', hm.trans h6, hs.trans h7, h8'⟩

theorem Good.finishCopy {d : Path} {desc : Class} {cs : Classes} {i : Nat} (h : Good V 0 κ)
    (hs : .copy d ∈ startedOf κ) (hc : Corr V d desc) (hl : NewLocal V κ (.copy d))
    (ha : addClass desc κ.classes = .ok (i, cs)) :
    Good V 0 (κ.finishCopy d cs i) ∧ Grows κ (κ.finishCopy d cs i) ∧ .copy d ∈ (κ.finishCopy d cs i).finished ∧
      ∃ c, cs.list[i]? = some c ∧ Corr V d c := by
  have hpre := prefix_addNew κ.finished (.copy d)
  obtain ⟨hcp, c, hci, hn, hm, hsch, -⟩ := addClass_same ha
  have hcorr : Corr V d c := by
    rcases addClass_cases ha with ⟨rfl, -⟩ | ⟨hl', rfl⟩
    · obtain ⟨d', -, hd'⟩ := h.clsFin c (List.mem_of_getElem? hci)
      exact Corr.of_same hc hd' hn hm hsch
    · rw [hl'] at hci
      simp at hci
      subst hci
      exact hc
  have hmem : ∀ c' ∈ cs.list, c' ∈ κ.classes.list ∨ c' = c := by
    intro c' hc'
    rcases addClass_cases ha with ⟨rfl, -⟩ | ⟨hl', rfl⟩
    · exact Or.inl hc'
    · rw [hl'] at hc' hci
      simp at hci
      rcases List.mem_append.mp hc' with h' | h'
      · exact Or.inl h'
      · simp at h'; exact Or.inr (h'.trans hci)
  refine ⟨⟨nodup_addNew h.nodup _, fun T hT => ?_, ?_, h.local_addNew hl, fun p ts hp => ?_,
    fun d' k hk => ?_, fun d' hd => ?_, fun c' hc' => ?_⟩, ⟨hpre, hcp, fun T hT => ?_⟩, mem_addNew _ _, c, hci, hcorr⟩
  · rw [startedOf_finishCopy]
    rcases mem_addNew_iff.mp hT with hT | rfl
    · exact h.started T hT
    · exact hs
  · rw [startedOf_finishCopy]; exact h.count
  · obtain ⟨h1, h2⟩ := h.files p ts hp
    exact ⟨hpre.subset h1, h2⟩
  · by_cases e : d' = d
    · subst e
      simp only [Core.finishCopy, lookup_cons_self, Option.some.injEq, Loading.done.injEq] at hk
      subst hk
      exact ⟨mem_addNew _ _, c, hci, hcorr⟩
    · obtain ⟨h1, c', h2, h3⟩ := h.copies d' k (by simpa [Core.finishCopy, lookup_cons_of_ne _ _ e] using hk)
      exact ⟨hpre.subset h1, c', prefix_getElem? hcp h2, h3⟩
  · rcases mem_addNew_iff.mp hd with hd | hd
    · obtain ⟨c', h1, h2⟩ := h.finCls d' hd
      exact ⟨c', hcp.subset h1, h2⟩
    · cases hd
      exact ⟨c, List.mem_of_getElem? hci, hcorr⟩
  · rcases hmem c' hc' with h' | rfl
    · obtain ⟨d', h1, h2⟩ := h.clsFin c' h'
      exact ⟨d', hpre.subset h1, h2⟩
    · exact ⟨d, mem_addNew _ _, hcorr⟩
  · rw [startedOf_finishCopy]; exact hT

end

/-! ## Proofs about a run, with the core of the state fixed between its changes -/

section Steps
variable {α β : Type} {env : Env}

/-- A state with truthful caches and the core `κ`. -/
abbrev At (env : Env) (κ : Core) (s : St) : Prop := Tr env.view s ∧ s.core = κ

theorem Triple.byCore {P : Core → Prop} {x : M α} {Q : α → St → Prop} {E : St → Prop}
    (h : ∀ κ, P κ → Triple env (At env κ) x Q E) : Triple env (fun s => Tr env.view s ∧ P s.core) x Q E :=
  fun s hs => h s.core hs.2 s ⟨hs.1, rfl⟩

theorem Triple.bind_getCore {κ : Core} {f : St → M β} {Q : β → St → Prop} {E : St → Prop}
    (h : ∀ s₀, s₀.core = κ → Tr env.view s₀ → Triple env (At env κ) (f s₀) Q E) :
    Triple env (At env κ) (get >>= f) Q E := by
  intro s hs; rw [go_bind]; exact h s hs.2 hs.1 s hs

/-- A pure step in a run whose failures don't matter (the run that succeeded). -/
theorem Pure.atA {x : M α} {v : Option α} {κ : Core} (h : Pure env x v) :
    Triple env (At env κ) x (fun r s => At env κ s ∧ v = some r) (fun _ => True) :=
  Triple.mono (h κ) (fun _ h => h) (fun _ _ h => h) (fun _ _ => True.intro)

/-- A pure step whose value is known: it doesn't fail. -/
theorem Pure.atB {x : M α} {a : α} {κ : Core} {E : St → Prop} (h : Pure env x (some a)) :
    Triple env (At env κ) x (fun r s => At env κ s ∧ r = a) E :=
  Triple.mono (h κ) (fun _ h => h) (fun _ _ h => ⟨h.1, (Option.some.inj h.2).symm⟩) (fun _ h => nomatch h.2)

theorem modify_at {κ κ' : Core} {g : St → St} {f : Unit → M β} {Q : β → St → Prop} {E : St → Prop}
    (hg : ∀ s, (g s).core = κ' ∨ s.core ≠ κ) (hm : ∀ s, (g s).manifests = s.manifests ∧ (g s).npm = s.npm)
    (h : Triple env (At env κ') (f ()) Q E) : Triple env (At env κ) (modify g >>= f) Q E := by
  refine Triple.bind_modify (At env κ') (fun s hs => ?_) h
  obtain ⟨h2, h3⟩ := hm s
  refine ⟨⟨by rw [h2]; exact hs.1.manifests, by rw [h3]; exact hs.1.npm⟩, ?_⟩
  rcases hg s with h1 | h1
  · exact h1
  · exact absurd hs.2 h1

theorem countFile_atA {κ : Core} {what : String} :
    Triple env (At env κ) (countFile what) (fun _ => At env κ.countUp) (fun _ => True) := by
  unfold countFile
  apply Triple.bind_cfg
  apply Triple.bind_getCore
  intro s₀ hc _
  dsimp only
  split
  · exact Triple.bind_fail fun _ _ => True.intro
  · refine Triple.modify fun s ⟨h1, h2⟩ => ⟨⟨h1.manifests, h1.npm⟩, ?_⟩
    subst h2; rfl

theorem countFile_atB {κ : Core} {what : String} {E : St → Prop} (hle : κ.count + 1 ≤ env.config.limits.files) :
    Triple env (At env κ) (countFile what) (fun _ => At env κ.countUp) E := by
  unfold countFile
  apply Triple.bind_cfg
  apply Triple.bind_getCore
  intro s₀ hc _
  dsimp only
  split
  · rename_i hgt
    rw [show s₀.count = κ.count from congrArg Core.count hc] at hgt
    omega
  · refine Triple.modify fun s ⟨h1, h2⟩ => ⟨⟨h1.manifests, h1.npm⟩, ?_⟩
    subst h2; rfl

theorem classify_at {κ : Core} {c : Class} :
    Triple env (At env κ) (classify c)
      (fun i s => Tr env.view s ∧ ∃ cs, addClass c κ.classes = .ok (i, cs) ∧ s.core = { κ with classes := cs })
      (fun _ => addClass c κ.classes matches .error _) := by
  unfold classify
  apply Triple.bind_getCore
  intro s₀ hc _
  have hcl : s₀.classes = κ.classes := congrArg Core.classes hc
  rw [hcl]
  split
  · rename_i i cs ha
    refine Triple.bind_modify (fun s => Tr env.view s ∧ ∃ cs', addClass c κ.classes = .ok (i, cs') ∧
      s.core = { κ with classes := cs' }) (fun s ⟨h1, h2⟩ => ⟨⟨h1.manifests, h1.npm⟩, cs, ha, ?_⟩)
      (Triple.pure fun _ h => h)
    subst h2; rfl
  · rename_i e ha
    exact Triple.throw fun _ _ => by rw [ha]

end Steps

section Checks
variable {env : Env} {κ : Core}

theorem Pure.copyNpm {dir : Path} {owner : String} : Pure env (copyNpm env.config dir owner) (npmOf env.view dir) := by
  unfold Haus.Packages.copyNpm npmOf
  exact Pure.ite2 (fun _ => Pure.packageJsonOf) (fun _ => Pure.ret)

theorem checkVersion_atA {m : Manifest} {npm : Option NpmInfo} {owner : String} :
    Triple env (At env κ) (checkVersion env.config m npm owner)
      (fun _ s => At env κ s ∧ VersionOk env.view m npm) (fun _ => True) := by
  unfold checkVersion VersionOk
  split
  · rename_i hc
    split
    · rename_i v hv
      split
      · exact Triple.fail fun _ _ => True.intro
      · rename_i hne
        exact Triple.pure fun s hs => ⟨hs, fun _ v' hv' => by rw [hv] at hv'; cases hv'; simpa using hne⟩
    · rename_i hv
      exact Triple.pure fun s hs => ⟨hs, fun _ v' hv' => absurd hv' (hv v')⟩
  · rename_i hc
    exact Triple.pure fun s hs => ⟨hs, fun h => absurd h hc⟩

theorem checkVersion_atB {m : Manifest} {npm : Option NpmInfo} {owner : String} {E : St → Prop}
    (h : VersionOk env.view m npm) :
    Triple env (At env κ) (checkVersion env.config m npm owner) (fun _ => At env κ) E := by
  unfold checkVersion
  split
  · rename_i hc
    split
    · rename_i v hv
      split
      · rename_i hne
        exact absurd (h hc v hv) (by simpa using hne)
      · exact Triple.pure fun _ h => h
    · exact Triple.pure fun _ h => h
  · exact Triple.pure fun _ h => h

theorem checkNoFiles_atA {m : Manifest} {sc : Scanned} :
    Triple env (At env κ) (checkNoFiles m sc)
      (fun _ s => At env κ s ∧ sc.imports.find? Import.isFile = none) (fun _ => True) := by
  unfold checkNoFiles
  split
  · exact Triple.fail fun _ _ => True.intro
  · rename_i hn
    refine Triple.pure fun s hs => ⟨hs, ?_⟩
    cases h : sc.imports.find? Import.isFile with
    | none => rfl
    | some i => exact absurd h (hn i)

theorem checkNoFiles_atB {m : Manifest} {sc : Scanned} {E : St → Prop}
    (h : sc.imports.find? Import.isFile = none) :
    Triple env (At env κ) (checkNoFiles m sc) (fun _ => At env κ) E := by
  unfold checkNoFiles
  split
  · rename_i i hi
    rw [h] at hi; cases hi
  · exact Triple.pure fun _ h => h

end Checks

section Good
variable {env : Env} {w : Walk}

/-- A state of a successful run that started from `κ₀`. -/
abbrev G (env : Env) (κ₀ : Core) (s : St) : Prop := Tr env.view s ∧ (Good env.view 0 s.core ∧ Grows κ₀ s.core)

/-- What `load T` gives on success. -/
def Ret (V : View) (T : Target) (r : Loaded) (κ : Core) : Prop :=
  T ∈ κ.finished ∧ typesV V T = some r.types ∧
    ∀ d, T = .copy d → ∃ k c, r.cls = some k ∧ κ.classes.list[k]? = some c ∧ Corr V d c

/-- `loadFn` keeps `Good` and gives what `load` gives. -/
def LoadOk (env : Env) (loadFn : Target → M Loaded) : Prop :=
  ∀ T κ₀, Triple env (G env κ₀) (loadFn T) (fun r s => G env κ₀ s ∧ Ret env.view T r s.core) (fun _ => True)

theorem G.at {κ₀ κ : Core} {s : St} (h : At env κ s) (hg : Good env.view 0 κ) (hgr : Grows κ₀ κ) : G env κ₀ s := by
  obtain ⟨h1, rfl⟩ := h; exact ⟨h1, hg, hgr⟩

theorem Triple.byG {α : Type} {κ₀ : Core} {R : Core → Prop} {x : M α} {Q : α → St → Prop} {E : St → Prop}
    (h : ∀ κ, Good env.view 0 κ → Grows κ₀ κ → R κ → Triple env (At env κ) x Q E) :
    Triple env (fun s => G env κ₀ s ∧ R s.core) x Q E :=
  fun s hs => h s.core hs.1.2.1 hs.1.2.2 hs.2 s ⟨hs.1.1, rfl⟩

theorem Triple.byG0 {α : Type} {κ₀ : Core} {x : M α} {Q : α → St → Prop} {E : St → Prop}
    (h : ∀ κ, Good env.view 0 κ → Grows κ₀ κ → Triple env (At env κ) x Q E) : Triple env (G env κ₀) x Q E :=
  fun s hs => h s.core hs.2.1 hs.2.2 s ⟨hs.1, rfl⟩

theorem Triple.intro_core {α : Type} {P : St → Prop} {x : M α} {Q : α → St → Prop} {E : St → Prop}
    (h : ∀ s₀, P s₀ → Triple env (At env s₀.core) x Q E) (hP : ∀ s, P s → Tr env.view s) : Triple env P x Q E :=
  fun s hs => h s hs s ⟨hP s hs, rfl⟩

theorem Triple.have_ {α : Type} {γ : Sort _} {P : St → Prop} {v : γ} {b : γ → M α} {Q : α → St → Prop}
    {E : St → Prop} (h : ∀ jp, jp = v → Triple env P (b jp) Q E) : Triple env P (have jp := v; b jp) Q E :=
  h v rfl

theorem getElem!_of_some {l : List Class} {i : Nat} {c : Class} (h : l[i]? = some c) : l[i]! = c := by
  obtain ⟨hi, e⟩ := List.getElem?_eq_some_iff.mp h
  rw [getElem!_pos l i hi, e]

theorem namesOk_of {imp : Import} {ts : List String}
    (h : (if namesOk imp ts then some () else none) = some ()) : namesOk imp ts := by
  split at h
  · assumption
  · cases h

theorem resolveImport_good {loadFn : Target → M Loaded} {importer : Importer} {imp : Import}
    (hload : LoadOk env loadFn) (κ₀ : Core) :
    Triple env (G env κ₀) (resolveImport loadFn importer imp)
      (fun _ s => G env κ₀ s ∧ ImpOk env.view (· ∈ s.core.finished) importer imp) (fun _ => True) := by
  unfold resolveImport
  split
  · rename_i nm heq
    exact Triple.pure fun s h => ⟨h, by unfold ImpOk; rw [heq]; trivial⟩
  · rename_i path heq
    split
    · exact Triple.fail fun _ _ => True.intro
    rename_i p
    apply Triple.bind_look
    split
    · exact Triple.fail fun _ _ => True.intro
    rename_i real hreal
    apply Triple.bind_look
    dsimp only
    split
    · exact Triple.bind_fail fun _ _ => True.intro
    rename_i hin
    split
    · exact Triple.bind_fail fun _ _ => True.intro
    rename_i hend
    apply Triple.bind_look
    split
    · exact Triple.bind_fail fun _ _ => True.intro
    rename_i hkind
    refine Triple.bind (hload _ κ₀) fun r => Triple.byG fun κ hg hgr hret => ?_
    refine Triple.bind (Pure.atA Pure.checkNames) fun _ => Triple.pre_and fun hn => ?_
    refine Triple.pure fun s hs => ⟨G.at hs hg hgr, ?_⟩
    unfold ImpOk; rw [heq]
    rw [hs.2]
    refine ⟨real, hreal, ?_, by simpa using hend, by simpa [Env.view_tree] using hkind, hret.1, r.types, hret.2.1,
      namesOk_of hn⟩
    show inPackage env.tree real = none
    cases h : inPackage env.tree real
    · rfl
    · exact absurd h (hin _)
  · rename_i name major heq
    apply Triple.byG0
    intro κ hg hgr
    refine Triple.bind (Pure.atA Pure.candidates) fun cands => Triple.pre_and fun hc => ?_
    dsimp only
    refine Triple.bind (Triple.mono (Triple.forIn (b := none) (fun rest _ s => Tr env.view s ∧ (Good env.view 0 s.core ∧
      Grows κ₀ s.core ∧ ∃ pre, pre ++ rest = cands ∧
        ∀ c ∈ pre, CandOk env.view (· ∈ s.core.finished) imp name major c.1)) ?_ fun _ _ h => h)
        (fun s hs => ⟨hs.1, by rw [hs.2]; exact ⟨hg, hgr, [], rfl, fun _ h => nomatch h⟩⟩)
        (fun _ _ h => h) (fun _ h => h)) fun r => ?_
    · intro c rest b hsuf
      refine Triple.intro_core (fun s₀ hs₀ => ?_) (fun _ h => h.1)
      obtain ⟨-, hg', hgr', pre, hpre, hcs⟩ := hs₀
      generalize s₀.core = κ' at *
      obtain ⟨dir, shown⟩ := c
      refine Triple.bind (Pure.atA Pure.manifestOf) fun mo => Triple.pre_and fun hm => ?_
      split
      · rename_i m
        dsimp only
        split
        · exact Triple.bind_fail fun _ _ => True.intro
        rename_i hname
        have tail : ∀ {Q : ForInStep (Option Nat) → St → Prop},
            (∀ b' s, (Tr env.view s ∧ (Good env.view 0 s.core ∧ Grows κ₀ s.core ∧ ∃ pre, pre ++ rest = cands ∧
              ∀ c ∈ pre, CandOk env.view (· ∈ s.core.finished) imp name major c.1)) → Q (.yield b') s) →
            (∀ n, major = some n → majorOf m.version = n) →
            Triple env (At env κ') (do
              let r ← loadFn (Target.copy dir)
              if b.isNone = true then do
                  checkNames imp r.types name
                  pure (ForInStep.yield r.cls)
                else do
                  checkNames imp r.types name
                  pure (ForInStep.yield b)) Q (fun _ => True) := by
          intro Q hQ hmaj
          refine Triple.bind (Triple.mono (hload _ κ') (fun s hs => G.at hs hg' (Grows.refl _)) (fun _ _ h => h)
            (fun _ h => h)) fun r => Triple.byG fun κ'' hg'' hgr'' hret => ?_
          have post : ∀ (s : St), At env κ'' s → namesOk imp r.types →
              Tr env.view s ∧ (Good env.view 0 s.core ∧ Grows κ₀ s.core ∧ ∃ pre, pre ++ rest = cands ∧
                ∀ c ∈ pre, CandOk env.view (· ∈ s.core.finished) imp name major c.1) := by
            intro s hs hn
            refine ⟨hs.1, ?_⟩
            rw [hs.2]
            refine ⟨hg'', hgr'.trans hgr'', pre ++ [(dir, shown)], by rw [← hpre]; simp, fun c hc => ?_⟩
            rcases List.mem_append.mp hc with hc | hc
            · exact (hcs c hc).mono fun _ h => hgr''.finished.subset h
            · simp at hc; subst hc
              exact ⟨m, hm, by simpa using hname, hmaj, hret.1, r.types, hret.2.1, hn⟩
          split
          · exact Triple.bind (Pure.atA Pure.checkNames) fun _ => Triple.pre_and fun hn =>
              Triple.pure fun s hs => hQ _ s (post s hs (namesOk_of hn))
          · exact Triple.bind (Pure.atA Pure.checkNames) fun _ => Triple.pre_and fun hn =>
              Triple.pure fun s hs => hQ _ s (post s hs (namesOk_of hn))
        cases major with
        | none => dsimp only; exact tail (fun _ _ h => h) fun _ h => nomatch h
        | some n =>
          dsimp only
          split
          · exact Triple.bind_fail fun _ _ => True.intro
          · rename_i hmaj
            exact tail (fun _ _ h => h) fun n' h => by cases h; simpa using hmaj
      · exact Triple.bind_fail fun _ _ => True.intro
    · refine Triple.pure fun s ⟨h1, hg', hgr', pre, hpre, hcs⟩ => ⟨⟨h1, hg', hgr'⟩, ?_⟩
      unfold ImpOk; rw [heq]
      rw [List.append_nil] at hpre
      subst hpre
      exact ⟨pre, hc, hcs⟩

theorem typesV_file {V : View} {p : Path} {bs : List UInt8} {sc : Scanned}
    (hb : fileBytes V.tree p V.limits.schemaFile = some bs) (hsc : decodeV bs = some sc) :
    typesV V (.file p) = some sc.types := by
  simp [typesV, hb, hsc]

theorem load_good : ∀ (n : Nat), LoadOk env (load w n)
  | 0 => fun T κ₀ => by unfold load; exact Triple.fail fun _ _ => True.intro
  | n + 1 => fun T κ₀ => by
    cases T with
    | file p =>
      unfold load
      apply Triple.byG0; intro κ hg hgr
      apply Triple.bind_getCore; intro s₀ hc _
      rw [show s₀.files = κ.files from congrArg Core.files hc]
      dsimp only
      split
      · rename_i ts hts
        exact Triple.pure fun s hs => ⟨G.at hs hg hgr, by
          rw [hs.2]; exact ⟨(hg.files p ts hts).1, (hg.files p ts hts).2, fun d h => nomatch h⟩⟩
      · exact Triple.fail fun _ _ => True.intro
      rename_i hnone
      obtain ⟨hg1, hgr1⟩ := hg.markFile hnone
      refine modify_at (κ' := κ.markFile p) (fun s => ?_) (fun s => ⟨rfl, rfl⟩) ?_
      · by_cases e : s.core = κ
        · left; rw [← e]; rfl
        · right; exact e
      apply Triple.bind_cfg
      refine Triple.bind (Pure.atA Pure.openFile) fun bytes => Triple.pre_and fun hb => ?_
      refine Triple.bind countFile_atA fun _ => ?_
      obtain ⟨hg2, hgr2⟩ := hg1.countUp
      refine Triple.bind (Pure.atA Pure.decodeScan) fun sc => Triple.pre_and fun hsc => ?_
      refine Triple.bind (Pure.atA Pure.noteImports) fun _ => Triple.pre_and fun _ => ?_
      refine Triple.bind (Triple.mono (Triple.forIn (b := PUnit.unit) (fun rest _ s => Tr env.view s ∧
        (Good env.view 0 s.core ∧ Grows (κ.markFile p).countUp s.core ∧ ∃ pre, pre ++ rest = w.order sc.imports ∧
          ∀ imp ∈ pre, ImpOk env.view (· ∈ s.core.finished) (.app p) imp)) ?_ fun _ _ h => h)
        (fun s hs => ⟨hs.1, by rw [hs.2]; exact ⟨hg2, Grows.refl _, [], rfl, fun _ h => nomatch h⟩⟩)
        (fun _ _ h => h) (fun _ h => h)) fun _ => ?_
      · intro imp rest b hsuf
        refine Triple.intro_core (fun s₀ hs₀ => ?_) (fun _ h => h.1)
        obtain ⟨-, hg', hgr', pre, hpre, hcs⟩ := hs₀
        generalize s₀.core = κ' at *
        refine Triple.bind (Triple.mono (resolveImport_good (importer := .app p) (imp := imp) (load_good n) κ')
          (fun s hs => G.at hs hg' (Grows.refl _)) (fun _ _ h => h) (fun _ h => h)) fun _ => ?_
        refine Triple.pure fun s ⟨⟨h1, hg'', hgr''⟩, himp⟩ => ⟨h1, hg'', hgr'.trans hgr'', pre ++ [imp],
          by rw [← hpre]; simp, fun i hi => ?_⟩
        rcases List.mem_append.mp hi with hi | hi
        · exact (hcs i hi).mono fun _ h => hgr''.finished.subset h
        · simp at hi; subst hi; exact himp
      · refine Triple.intro_core (fun s₀ hs₀ => ?_) (fun _ h => h.1)
        obtain ⟨-, hg', hgr', pre, hpre, hcs⟩ := hs₀
        generalize s₀.core = κ' at *
        rw [List.append_nil] at hpre
        have hstart : .file p ∈ startedOf κ' :=
          hgr'.started _ (by rw [startedOf_countUp, startedOf_markFile]; exact List.mem_cons_self)
        have hts := typesV_file (V := env.view) hb hsc
        obtain ⟨hg3, hgr3, hfin⟩ := hg'.finishFile hstart hts (Or.inr ⟨bytes, sc, hb, hsc, fun i hi =>
          hcs i (hpre ▸ (w.perm _).mem_iff.mpr hi)⟩)
        refine modify_at (κ' := κ'.finishFile p sc.types) (fun s => ?_) (fun s => ⟨rfl, rfl⟩) ?_
        · by_cases e : s.core = κ'
          · left; rw [← e]; rfl
          · right; exact e
        exact Triple.pure fun s hs => ⟨G.at hs hg3 (hgr.trans (hgr1.trans (hgr2.trans (hgr'.trans hgr3)))),
          by rw [hs.2]; exact ⟨hfin, hts, fun d h => nomatch h⟩⟩
    | copy dir =>
      unfold load
      apply Triple.byG0; intro κ hg hgr
      apply Triple.bind_getCore; intro s₀ hc _
      rw [show s₀.copies = κ.copies from congrArg Core.copies hc]
      split
      · rename_i k hk
        apply Triple.bind_getCore; intro s₁ hc1 _
        rw [show s₁.classes = κ.classes from congrArg Core.classes hc1]
        obtain ⟨hfin, cl, hcl, hcorr⟩ := hg.copies dir k hk
        refine Triple.pure fun s hs => ⟨G.at hs hg hgr, ?_⟩
        rw [hs.2]
        have hcl' : κ.classes.list[k]! = cl := getElem!_of_some hcl
        obtain ⟨m, bs, sc, h1, h2, h3, h4, h5, h6, h7, h8⟩ := hcorr
        refine ⟨hfin, ?_, fun d hd => ?_⟩
        · show typesV env.view (.copy dir) = some κ.classes.list[k]!.types
          rw [hcl', h8]; simp [typesV, h2, h3]
        · cases hd; exact ⟨k, cl, rfl, hcl, m, bs, sc, h1, h2, h3, h4, h5, h6, h7, h8⟩
      · exact Triple.fail fun _ _ => True.intro
      rename_i hnone
      obtain ⟨hg1, hgr1⟩ := hg.markCopy hnone
      refine modify_at (κ' := κ.markCopy dir) (fun s => ?_) (fun s => ⟨rfl, rfl⟩) ?_
      · by_cases e : s.core = κ
        · left; rw [← e]; rfl
        · right; exact e
      apply Triple.bind_cfg
      refine Triple.bind (Pure.atA Pure.manifestOf) fun mo => Triple.pre_and fun hm => ?_
      cases mo with
      | none => exact Triple.fail fun _ _ => True.intro
      | some m =>
      dsimp only
      refine Triple.bind (Pure.atA Pure.copyNpm) fun npm => Triple.pre_and fun hnpm => ?_
      refine Triple.bind checkVersion_atA fun _ => Triple.pre_and fun hver => ?_
      refine Triple.bind (Pure.atA Pure.openPackageFile) fun bo => Triple.pre_and fun hbo => ?_
      cases bo with
      | none => exact Triple.fail fun _ _ => True.intro
      | some bytes =>
      dsimp only
      refine Triple.bind countFile_atA fun _ => ?_
      obtain ⟨hg2, hgr2⟩ := hg1.countUp
      refine Triple.bind (Pure.atA Pure.decodeScan) fun sc => Triple.pre_and fun hsc => ?_
      refine Triple.bind (Pure.atA Pure.noteImports) fun _ => Triple.pre_and fun _ => ?_
      refine Triple.bind checkNoFiles_atA fun _ => Triple.pre_and fun hnf => ?_
      refine Triple.bind (Triple.mono (Triple.forIn (b := []) (fun rest _ s => Tr env.view s ∧
        (Good env.view 0 s.core ∧ Grows (κ.markCopy dir).countUp s.core ∧
          ∃ pre, pre ++ rest = w.order sc.imports ∧
            ∀ imp ∈ pre, ImpOk env.view (· ∈ s.core.finished) (.pkg dir m.name npm) imp)) ?_ fun _ _ h => h)
        (fun s hs => ⟨hs.1, by rw [hs.2]; exact ⟨hg2, Grows.refl _, [], rfl, fun _ h => nomatch h⟩⟩)
        (fun _ _ h => h) (fun _ h => h)) fun targets => ?_
      · intro imp rest b hsuf
        refine Triple.intro_core (fun s₀ hs₀ => ?_) (fun _ h => h.1)
        obtain ⟨-, hg', hgr', pre, hpre, hcs⟩ := hs₀
        generalize s₀.core = κ' at *
        refine Triple.bind (Triple.mono (resolveImport_good (importer := .pkg dir m.name npm) (imp := imp)
          (load_good n) κ') (fun s hs => G.at hs hg' (Grows.refl _)) (fun _ _ h => h) (fun _ h => h)) fun r => ?_
        have post : ∀ s : St, (G env κ' s ∧ ImpOk env.view (· ∈ s.core.finished) (.pkg dir m.name npm) imp) →
            Tr env.view s ∧ (Good env.view 0 s.core ∧ Grows (κ.markCopy dir).countUp s.core ∧
              ∃ pre, pre ++ rest = w.order sc.imports ∧
                ∀ imp ∈ pre, ImpOk env.view (· ∈ s.core.finished) (.pkg dir m.name npm) imp) := by
          rintro s ⟨⟨h1, hg'', hgr''⟩, himp⟩
          refine ⟨h1, hg'', hgr'.trans hgr'', pre ++ [imp], by rw [← hpre]; simp, fun i hi => ?_⟩
          rcases List.mem_append.mp hi with hi | hi
          · exact (hcs i hi).mono fun _ h => hgr''.finished.subset h
          · simp at hi; subst hi; exact himp
        split
        · exact Triple.pure fun s h => post s h
        · exact Triple.pure fun s h => post s h
      · refine Triple.intro_core (fun s₀ hs₀ => ?_) (fun _ h => h.1)
        obtain ⟨-, hg', hgr', pre, hpre, hcs⟩ := hs₀
        generalize s₀.core = κ' at *
        rw [List.append_nil] at hpre
        have hstart : .copy dir ∈ startedOf κ' :=
          hgr'.started _ (by rw [startedOf_countUp]; exact mem_startedOf_markCopy.mpr (Or.inl rfl))
        have hcorr : Corr env.view dir (Class.mk m.name m.version m.bytes bytes targets sc.types dir) :=
          ⟨m, bytes, sc, hm, hbo, hsc, rfl, rfl, rfl, rfl, rfl⟩
        have hloc : NewLocal env.view κ' (.copy dir) := Or.inr ⟨m, npm, bytes, sc, hm, hnpm, hver, hbo, hsc, hnf,
          fun i hi => hcs i (hpre ▸ (w.perm _).mem_iff.mpr hi)⟩
        refine Triple.bind (Triple.mono classify_at (fun _ h => h) (fun _ _ h => h) (fun _ _ => True.intro)) fun i => ?_
        refine Triple.bind_modify (fun s => Tr env.view s ∧ ∃ cs, addClass _ κ'.classes = .ok (i, cs) ∧
          s.core = κ'.finishCopy dir cs i) (fun s ⟨h1, cs, ha, h2⟩ => ⟨⟨h1.manifests, h1.npm⟩, cs, ha, ?_⟩) ?_
        · obtain ⟨e1, e2, e3, e4, e5⟩ := Core.mk.inj (h2 : (⟨s.files, s.copies, s.classes, s.count, s.finished⟩ : Core) =
            ⟨κ'.files, κ'.copies, cs, κ'.count, κ'.finished⟩)
          simp only [St.core, Core.finishCopy, e1, e2, e3, e4, e5]
        refine Triple.pure fun s ⟨h1, cs, ha, h2⟩ => ?_
        obtain ⟨hg3, hgr3, hfin, c, hci, hcc⟩ := hg'.finishCopy hstart hcorr hloc ha
        refine ⟨⟨h1, by rw [h2]; exact ⟨hg3, hgr.trans (hgr1.trans (hgr2.trans (hgr'.trans hgr3)))⟩⟩, ?_⟩
        rw [h2]
        exact ⟨hfin, by simp [typesV, Env.view_tree, Env.view_limits, hbo, hsc], fun d hd => by cases hd; exact ⟨i, c, rfl, hci, hcc⟩⟩

theorem Pure.keep {α : Type} {x : M α} {v : Option α} {κ : Core} (h : Pure env x v) :
    Triple env (At env κ) x (fun _ => At env κ) (At env κ) :=
  Triple.mono (h κ) (fun _ h => h) (fun _ _ h => h.1) (fun _ h => h.1)

/-- Reading the packages given leaves the core alone and the caches truthful. -/
theorem givenPackages_at {κ : Core} : Triple env (At env κ) givenPackages (fun _ => At env κ) (At env κ) := by
  unfold givenPackages
  apply Triple.bind_cfg
  refine Triple.bind (Triple.forIn (fun _ _ => At env κ) ?_ fun _ _ h => h) fun _ => ?_
  · intro d rest b _
    repeat (first
      | with_reducible refine (Triple.bind (Pure.keep Pure.manifestOf) fun _ => ?_)
      | tstep)
  · dsimp only
    refine Triple.bind (Triple.forIn (fun _ _ => At env κ) ?_ fun _ _ h => h) fun _ => ?_
    · intro d rest b _
      repeat (first
        | with_reducible refine (Triple.bind (Triple.forIn (fun _ _ => At env κ) ?_ fun _ _ h => h) fun _ => ?_)
        | (intro n rest b _)
        | refine (Triple.bind (R := fun _ => At env κ) (Triple.tryCatch (R := At env κ) ?_ fun _ => ?_) fun _ => ?_)
        | with_reducible refine (Triple.bind (Pure.keep Pure.manifestOf) fun _ => ?_)
        | tstep)
    · tdone

end Good

end Haus.Packages
