import Haus.Packages.Run

/-!
# What the resolver reads (R7) and how much (R4)

One invariant (`Inv`, with `K` for the searches) holds of every state of
every run, proven a function at a time with `Triple` (`Haus.Packages.Run`),
`load` by induction on its fuel, from the empty state (`runIn_K`):

- **The read set** (R7, P1, F6–F8), `reads_allowed`: every file opened is
  `Allowed`: a package's own `package.haus`, `schema.haus` or
  `package.json` (a regular file directly in a directory with a
  `package.haus`, never through a link: `PkgFile`), a schema file (a regular
  file whose real path ends in `.schema.haus`, or the root: `SchemaFile`),
  or the real path of `D/package.json` for a directory `D` above a schema
  file (`ProjectJson`, opened following links, as §13.3 puts no rule on it).
- **Each file once** (R4, P3), `reads_nodup`; so at most as many as the tree
  has files (`reads_length_le`).
- **The limits** (R4): `count_le`, at most `Limits.files` schema files, the
  root included; `openFile_spec`, the bytes of every file opened are within
  the limit its caller gives (`Limits.manifest` for `package.haus`,
  `Limits.schemaFile`, `Limits.packageJson`), or the run fails before using
  them.
- **Bounded lookups** (R4, F9), `lookups_le`: the searches for a package
  are at most the imports of the schema files loaded, at most the files
  loaded times the most imports in one file (`lookups_le_files`). The
  invariant has room for `j` more searches than imports noted (`K env root
  j`): an import's search comes after its file's imports are noted.
-/

namespace Haus.Packages

/-- A directory with a `package.haus` that is a regular file: a package's directory. -/
def PkgDir (t : Tree) (d : Path) : Prop := t.childKind? d "package.haus" = some .file

/--
A package's own file: its `package.haus`, `schema.haus` or `package.json`,
directly in a package's directory (not through a link), a regular file.
-/
def PkgFile (t : Tree) (p : Path) : Prop :=
  ∃ dir name, p = dir ++ [name] ∧ (name = "package.haus" ∨ name = "schema.haus" ∨ name = "package.json") ∧
    t.childKind? dir name = some .file ∧ PkgDir t dir

/-- A schema file: a regular file whose real path ends in `.schema.haus`, or the root's real path. -/
def SchemaFile (t : Tree) (root : Path) (p : Path) : Prop :=
  t.kindAt? p = some .file ∧ (p.getLast?.any (·.endsWith ".schema.haus") = true ∨ t.realPath root = .ok p)

/-- A project's `package.json`: the real path of `D/package.json`, a regular file, for a directory `D` above a schema file. -/
def ProjectJson (t : Tree) (root : Path) (p : Path) : Prop :=
  ∃ f d, SchemaFile t root f ∧ d ∈ ancestors f.dropLast ∧ t.realPath (d ++ ["package.json"]) = .ok p ∧
    t.kindAt? p = some .file

/-- What the resolver may open (R7). -/
def Allowed (t : Tree) (root : Path) (p : Path) : Prop :=
  PkgFile t p ∨ SchemaFile t root p ∨ ProjectJson t root p

/-- What holds of every state of a run (R4, R7). -/
structure Inv (t : Tree) (c : Config) (root : Path) (s : St) : Prop where
  nodup : s.reads.Nodup
  allowed : ∀ p ∈ s.reads, Allowed t root p
  manifests : ∀ d m, (d, m) ∈ s.manifests → PkgDir t d
  count : s.count ≤ c.limits.files
  scanned : s.scanned ≤ s.count
  imports : s.imports ≤ s.scanned * s.widest

/-- The invariant, with room for `j` more searches for packages than the imports noted so far (R4). -/
def K (env : Env) (root : Path) (j : Nat) (s : St) : Prop :=
  Inv env.tree env.config root s ∧ s.lookups + j ≤ s.imports

theorem K.congr {env : Env} {root : Path} {j : Nat} {s s' : St} (h : K env root j s)
    (hr : s'.reads = s.reads) (hm : s'.manifests = s.manifests) (hc : s'.count = s.count)
    (hsc : s'.scanned = s.scanned) (hi : s'.imports = s.imports) (hw : s'.widest = s.widest)
    (hl : s'.lookups = s.lookups) : K env root j s' := by
  obtain ⟨⟨hn, ha, hm', hc', hsc', hi'⟩, hl'⟩ := h
  exact ⟨⟨hr ▸ hn, hr ▸ ha, hm ▸ hm', hc ▸ hc', hsc ▸ hc ▸ hsc', hi ▸ hsc ▸ hw ▸ hi'⟩, hl ▸ hi ▸ hl'⟩

/-- A step that changes none of what `K` is about. -/
macro "kframe" : tactic => `(tactic| exact fun _ h => K.congr h rfl rfl rfl rfl rfl rfl rfl)

/-- A `modify` that changes none of what `K` is about. -/
macro "tmod" : tactic => `(tactic| refine Triple.bind_modify' (fun _ h => K.congr h rfl rfl rfl rfl rfl rfl rfl) ?_)

/-- Ends a program whose remaining steps are `pure`, `match` and `if`, keeping the invariant. -/
macro "tstep" : tactic => `(tactic| first
  | (with_reducible apply Triple.pure; intro _ h; exact h)
  | with_reducible apply Triple.bind_pure
  | with_reducible apply Triple.bind_look
  | with_reducible apply Triple.bind_ask
  | with_reducible apply Triple.bind_cfg
  | with_reducible exact Triple.bind_fail fun _ h => h
  | with_reducible exact Triple.fail fun _ h => h
  | with_reducible exact Triple.bind_throw fun _ h => h
  | with_reducible exact Triple.throw fun _ h => h
  | (with_reducible apply Triple.bind_get'; intro _ _)
  | split
  | dsimp only
  | (apply Triple.pure; intro _ h; exact h)
  | exact Triple.bind_fail fun _ h => h)

macro "tdone" : tactic => `(tactic| repeat tstep)

section
variable {env : Env} {root : Path} {j : Nat}

theorem openFile_spec {p : Path} {limit : Nat} {tl : Nat → Err} (hp : Allowed env.tree root p) :
    Triple env (K env root j) (openFile p limit tl) (fun bs s => K env root j s ∧ bs.length ≤ limit) (K env root j) := by
  unfold openFile
  apply Triple.bind_read
  split
  · rename_i bs _
    apply Triple.bind_get
    intro s₀
    dsimp only
    have last : ∀ P : St → Prop, (∀ s, P s → K env root j s) →
        Triple env P (if bs.length > limit then (throw (tl bs.length) : M Unit) >>= fun _ => pure bs else pure bs)
          (fun bs s => K env root j s ∧ bs.length ≤ limit) (K env root j) := by
      intro P hP
      split
      · exact Triple.bind (Triple.throw hP) fun _ => Triple.pure fun _ h => h
      · exact Triple.pure fun s hs => ⟨hP s hs, by omega⟩
    split
    · rename_i hnew
      refine Triple.bind_modify (K env root j) ?_ (last _ fun _ h => h)
      rintro s ⟨⟨⟨hn, ha, hm, hc, hsc, hi⟩, hl⟩, rfl⟩
      refine ⟨⟨?_, ?_, hm, hc, hsc, hi⟩, hl⟩
      · exact List.nodup_append.mpr ⟨hn, List.nodup_cons.mpr ⟨by simp, List.nodup_nil⟩, fun a ha b hb => by
          simp at hb; subst hb; rintro rfl; exact hnew ha⟩
      · intro q hq
        rcases List.mem_append.mp hq with hq | hq
        · exact ha q hq
        · simp at hq; subst hq; exact hp
    · exact last _ fun _ h => h.1
  · exact Triple.fail fun _ h => h

theorem openPackageFile_spec {dir : Path} {name : String} {limit : Nat} {code : Code} {owner : String}
    (hname : name = "package.haus" ∨ name = "schema.haus" ∨ name = "package.json")
    (hdir : name = "package.haus" ∨ PkgDir env.tree dir) :
    Triple env (K env root j) (openPackageFile dir name limit code owner)
      (fun r s => K env root j s ∧ (r.isSome → env.tree.childKind? dir name = some .file)) (K env root j) := by
  unfold openPackageFile
  apply Triple.bind_look
  split
  · exact Triple.pure fun s hs => ⟨hs, by simp⟩
  · rename_i heq
    refine Triple.bind (openFile_spec (Or.inl ⟨dir, name, rfl, hname, heq, ?_⟩)) fun bs => Triple.pure fun s hs => ⟨hs.1, fun _ => heq⟩
    rcases hdir with rfl | h
    · exact heq
    · exact h
  · exact Triple.fail fun _ h => h
  · exact Triple.fail fun _ h => h

theorem manifestOf_spec {dir : Path} {shown : String} :
    Triple env (K env root j) (manifestOf dir shown)
      (fun r s => K env root j s ∧ (r.isSome → PkgDir env.tree dir)) (K env root j) := by
  unfold manifestOf
  apply Triple.bind_get'
  intro s₀ h₀
  split
  · rename_i m hm
    exact Triple.pure fun s hs => ⟨hs, fun _ => h₀.1.manifests dir m (lookup_mem hm)⟩
  · apply Triple.bind_cfg
    refine Triple.bind (openPackageFile_spec (Or.inl rfl) (Or.inl rfl)) fun r => ?_
    split
    · exact Triple.pure fun s hs => ⟨hs.1, by simp⟩
    · apply Triple.pre_and
      intro hpk
      have hdir : PkgDir env.tree dir := hpk rfl
      dsimp only
      split
      · refine Triple.bind_pure ?_
        refine Triple.bind_modify' ?_ (Triple.pure fun s hs => ⟨hs, fun _ => hdir⟩)
        rintro s ⟨⟨hn, ha, hm, hc, hsc, hi⟩, hl⟩
        refine ⟨⟨hn, ha, ?_, hc, hsc, hi⟩, hl⟩
        intro d m' hd
        rcases List.mem_cons.mp hd with hd | hd
        · cases hd; exact hdir
        · exact hm d m' hd
      · exact Triple.bind_throw fun _ h => h

theorem packageJsonOf_spec {dir : Path} {owner : String} (hd : PkgDir env.tree dir) :
    Triple env (K env root j) (packageJsonOf dir owner) (fun _ => K env root j) (K env root j) := by
  unfold packageJsonOf
  apply Triple.bind_get'
  intro s₀ _
  split
  · exact Triple.pure fun _ h => h
  · apply Triple.bind_cfg
    refine Triple.bind (openPackageFile_spec (Or.inr (Or.inr rfl)) (Or.inr hd)) fun r => ?_
    split
    · exact Triple.pure fun _ h => h.1
    · exact Triple.bind_modify' (fun _ h => ⟨K.congr h.1 rfl rfl rfl rfl rfl rfl rfl, h.2⟩) (Triple.pure fun _ h => h.1)

theorem projectOf_spec {p : Path} (hp : SchemaFile env.tree root p) :
    Triple env (K env root j) (projectOf p) (fun _ => K env root j) (K env root j) := by
  unfold projectOf
  apply Triple.bind_cfg
  dsimp only
  refine Triple.bind (Triple.forIn (fun _ _ => K env root j) ?_ fun _ _ h => h) fun r => ?_
  · intro d rest b hd
    have hd : d ∈ ancestors p.dropLast := hd.subset List.mem_cons_self
    apply Triple.bind_look
    split
    · tdone
    apply Triple.bind_look
    split
    next real hreal =>
      apply Triple.bind_look
      split
      · tdone
      next hkind =>
      apply Triple.bind_get'
      intro s₀ _
      split
      · tdone
      refine Triple.bind (openFile_spec (Or.inr (Or.inr ⟨p, d, hp, hd, hreal, ?_⟩))) fun bytes => ?_
      · simpa using hkind
      apply Triple.pre_and; intro _
      tmod
      tdone
    · tdone
  · tdone

/-- An importer whose files may be read: an application file is a schema file. -/
def GoodImporter (env : Env) (root : Path) : Importer → Prop
  | .app p => SchemaFile env.tree root p
  | .pkg _ _ _ => True

theorem declared_spec {imp : Importer} (h : GoodImporter env root imp) :
    Triple env (K env root j) (declared imp) (fun _ => K env root j) (K env root j) := by
  unfold declared
  split
  · tdone
  · tdone
  · exact Triple.bind (projectOf_spec h) fun _ => by tdone

/-- `npmLookup` changes nothing of the state. -/
theorem npmLookup_spec {P : St → Prop} {start : Path} {name : String} :
    Triple env P (npmLookup start name) (fun _ => P) P := by
  unfold npmLookup
  apply Triple.bind_cfg
  refine Triple.bind (Triple.forIn (fun _ _ => P) ?_ fun _ _ h => h) fun r => ?_
  · intro d rest b _
    apply Triple.bind_look
    split
    · apply Triple.bind_look
      split
      · tdone
      · exact Triple.bind_fail fun _ h => h
    · tdone
  · tdone

theorem candidates_spec {imp : Importer} {name : String} (h : GoodImporter env root imp) :
    Triple env (K env root (j + 1)) (candidates imp name) (fun _ => K env root j) (K env root j) := by
  unfold candidates
  refine Triple.bind_modify (K env root j) (fun s h => ?_) ?_
  · obtain ⟨hi, hl⟩ := h
    exact ⟨⟨hi.nodup, hi.allowed, hi.manifests, hi.count, hi.scanned, hi.imports⟩, by simp; omega⟩
  apply Triple.bind_ask
  dsimp only
  split
  · tdone
  apply Triple.bind_cfg
  split
  · tdone
  · refine Triple.bind (declared_spec h) fun r => ?_
    split
    · refine Triple.bind npmLookup_spec fun _ => ?_
      tdone
    · tdone

theorem K.weaken {s : St} {k : Nat} (h : K env root (j + k) s) : K env root j s :=
  ⟨h.1, by have := h.2; omega⟩

/-- A target whose files may be read: an application file is a schema file. -/
def GoodTarget (env : Env) (root : Path) : Target → Prop
  | .file p => SchemaFile env.tree root p
  | .copy _ => True

theorem checkNames_spec {P : St → Prop} {imp : Import} {types : List String} {what : String} :
    Triple env P (checkNames imp types what) (fun _ => P) P := by
  unfold checkNames; tdone

theorem decodeScan_spec {P E : St → Prop} {bytes : List UInt8} {what : String} (hE : ∀ s, P s → E s) :
    Triple env P (decodeScan bytes what) (fun _ => P) E := by
  unfold decodeScan
  split
  · exact Triple.fail hE
  · split
    · exact Triple.pure fun _ h => h
    · exact Triple.fail hE

theorem resolveImport_spec {loadFn : Target → M Loaded} {importer : Importer} {imp : Import}
    (hload : ∀ T j, GoodTarget env root T → Triple env (K env root j) (loadFn T) (fun _ => K env root j) (K env root j))
    (himp : GoodImporter env root importer) :
    Triple env (K env root (j + 1)) (resolveImport loadFn importer imp) (fun _ => K env root j) (K env root j) := by
  unfold resolveImport
  split
  · exact Triple.pure fun _ h => K.weaken h
  · refine Triple.mono (P := K env root j) ?_ (fun _ h => K.weaken h) (fun _ _ h => h) (fun _ h => h)
    split
    · tdone
    · rename_i p
      apply Triple.bind_look
      split
      · tdone
      rename_i real _
      apply Triple.bind_look
      split
      · tdone
      split
      · tdone
      apply Triple.bind_look
      split
      · tdone
      rename_i hkind
      refine Triple.bind (hload _ j ⟨by simpa using hkind, Or.inl (by simpa using ‹¬(!Option.any _ (List.getLast? real)) = true›)⟩) fun r => ?_
      exact Triple.bind checkNames_spec fun _ => by tdone
  · rename_i name major
    refine Triple.bind (candidates_spec himp) fun cands => ?_
    refine Triple.bind (Triple.forIn (fun _ _ => K env root j) ?_ fun _ _ h => h) fun r => by tdone
    intro c rest b _
    dsimp only
    refine Triple.bind manifestOf_spec fun m => ?_
    apply Triple.pre_and; intro _
    repeat (first
      | tstep
      | refine Triple.bind (hload (.copy _) j trivial) fun _ => ?_
      | refine Triple.bind checkNames_spec fun _ => ?_)

theorem countFile_spec {what : String} :
    Triple env (K env root j) (countFile what) (fun _ s => K env root j s ∧ s.scanned < s.count) (K env root j) := by
  unfold countFile
  apply Triple.bind_cfg
  apply Triple.bind_get
  intro s₀
  dsimp only
  split
  · exact Triple.bind_fail fun _ h => h.1
  · rename_i hle
    refine Triple.modify fun s ⟨⟨⟨hn, ha, hm, hc, hsc, hi⟩, hl⟩, e⟩ => ?_
    subst e
    exact ⟨⟨⟨hn, ha, hm, by simp; omega, by simp; omega, hi⟩, hl⟩, by simp; omega⟩

theorem noteImports_spec {k : Nat} {E : St → Prop} :
    Triple env (fun s => K env root j s ∧ s.scanned < s.count) (noteImports k) (fun _ => K env root (j + k)) E := by
  unfold noteImports
  refine Triple.modify fun s ⟨⟨⟨hn, ha, hm, hc, hsc, hi⟩, hl⟩, hlt⟩ => ?_
  refine ⟨⟨hn, ha, hm, hc, by simp; omega, ?_⟩, by simp; omega⟩
  simp only
  have h1 : s.imports ≤ s.scanned * max s.widest k :=
    Nat.le_trans hi (Nat.mul_le_mul_left _ (Nat.le_max_left _ _))
  have h2 : k ≤ max s.widest k := Nat.le_max_right _ _
  rw [Nat.succ_mul]
  omega

theorem classify_spec {c : Class} :
    Triple env (K env root j) (classify c) (fun _ => K env root j) (K env root j) := by
  unfold classify
  apply Triple.bind_get'
  intro s₀ _
  split
  · tmod; tdone
  · tdone

theorem load_spec : ∀ (n : Nat) (T : Target) (j : Nat), GoodTarget env root T →
    Triple env (K env root j) (load n T) (fun _ => K env root j) (K env root j)
  | 0, _, _, _ => by unfold load; tdone
  | n + 1, .file p, j, hT => by
    unfold load
    apply Triple.bind_get'
    intro s₀ _
    dsimp only
    split
    · tdone
    · tdone
    tmod
    apply Triple.bind_cfg
    refine Triple.bind (openFile_spec (Or.inr (Or.inl hT))) fun bytes => ?_
    apply Triple.pre_and; intro _
    refine Triple.bind countFile_spec fun _ => ?_
    refine Triple.bind (decodeScan_spec fun _ h => h.1) fun sc => ?_
    refine Triple.bind noteImports_spec fun _ => ?_
    refine Triple.bind (R := fun _ => K env root j)
      (Triple.forIn (fun rest _ => K env root (j + rest.length)) ?_ fun _ _ h => h) fun _ => ?_
    · intro imp rest b _
      exact Triple.bind (Triple.mono
        (resolveImport_spec (j := j + rest.length) (importer := .app p) (fun T j hT => load_spec n T j hT) hT)
        (fun _ h => h) (fun _ _ h => h) (fun _ h => K.weaken h))
        fun _ => Triple.pure fun _ h => h
    · tmod; tdone
  | n + 1, .copy dir, j, hT => by
    unfold load
    apply Triple.bind_get'
    intro s₀ _
    dsimp only
    split
    · tdone
    · tdone
    tmod
    apply Triple.bind_cfg
    refine Triple.bind manifestOf_spec fun m => ?_
    apply Triple.pre_and; intro hm
    split
    next =>
      have hdir : PkgDir env.tree dir := hm rfl
      repeat (first
        | tstep
        | with_reducible refine Triple.bind (packageJsonOf_spec hdir) fun _ => ?_
        | (with_reducible refine (Triple.bind (openPackageFile_spec (Or.inr (Or.inl rfl)) (Or.inr hdir)) fun _ => ?_)
           apply Triple.pre_and; intro _)
        | with_reducible refine Triple.bind countFile_spec fun _ => ?_
        | with_reducible refine (Triple.bind (decodeScan_spec (P := fun s => K env root j s ∧ s.scanned < s.count)
            fun _ h => h.1) fun _ => ?_)
        | with_reducible refine Triple.bind noteImports_spec fun _ => ?_
        | with_reducible exact Triple.bind_fail fun _ h => K.weaken h
        | with_reducible refine (Triple.bind (R := fun _ => K env root j)
            (Triple.forIn (fun rest _ => K env root (j + rest.length)) ?_ fun _ _ h => K.weaken h) fun _ => ?_)
        | (intro imp rest b _; refine (Triple.bind (Triple.mono (resolveImport_spec (j := j + rest.length)
             (importer := .pkg _ _ _) (fun T j hT => load_spec n T j hT) trivial)
             (fun _ h => h) (fun _ _ h => h) (fun _ h => K.weaken h)) fun _ => ?_))
        | with_reducible refine Triple.bind classify_spec fun _ => ?_
        | tmod)
    next => tdone

theorem givenPackages_spec :
    Triple env (K env root j) givenPackages (fun _ => K env root j) (K env root j) := by
  unfold givenPackages
  apply Triple.bind_cfg
  refine Triple.bind (Triple.forIn (fun _ _ => K env root j) ?_ fun _ _ h => h) fun _ => ?_
  · intro d rest b _
    repeat (first
      | with_reducible refine (Triple.bind manifestOf_spec fun _ => ?_)
      | (apply Triple.pre_and; intro _)
      | tstep)
  · dsimp only
    refine Triple.bind (Triple.forIn (fun _ _ => K env root j) ?_ fun _ _ h => h) fun _ => ?_
    · intro d rest b _
      repeat (first
        | with_reducible refine (Triple.bind (Triple.forIn (fun _ _ => K env root j) ?_ fun _ _ h => h) fun _ => ?_)
        | (intro n rest b _)
        | refine (Triple.bind (R := fun _ => K env root j) (Triple.tryCatch (R := K env root j) ?_ fun _ => ?_) fun _ => ?_)
        | with_reducible refine (Triple.bind manifestOf_spec fun _ => ?_)
        | (apply Triple.pre_and; intro _)
        | tstep)
    · tdone

theorem main_spec : Triple env (K env root 0) (main root) (fun _ => K env root 0) (K env root 0) := by
  unfold main
  refine Triple.bind givenPackages_spec fun r => ?_
  dsimp only
  refine Triple.withReader ?_
  apply Triple.bind_look
  split
  · rename_i real hreal
    apply Triple.bind_pure
    apply Triple.bind_look
    split
    · tdone
    · rename_i hkind
      apply Triple.bind_look
      exact Triple.bind (load_spec _ _ 0 ⟨by simpa using hkind, Or.inr hreal⟩) fun _ => Triple.pure fun _ h => h
  · intro s hs
    rw [go_bind]
    exact hs

end

/-! ## A whole run -/

/-- A whole run: its result and its last state. -/
def runIn (t : Tree) (c : Config) (root : Path) : Except Err Unit × St := go (main root) { tree := t, config := c } {}

theorem resolveIn_runIn (t : Tree) (c : Config) (root : Path) : resolveIn t c root = Outcome.of (runIn t c root) := rfl

theorem runIn_K (t : Tree) (c : Config) (root : Path) : K { tree := t, config := c } root 0 (runIn t c root).2 :=
  Triple.final main_spec ⟨⟨List.nodup_nil, by simp, by simp, Nat.zero_le _, Nat.le_refl _, Nat.le_refl _⟩, Nat.le_refl _⟩

theorem runIn_inv (t : Tree) (c : Config) (root : Path) : Inv t c root (runIn t c root).2 := (runIn_K t c root).1

/-- **Each file is read at most once** (R4, §13.3 "Files and limits"): the files a run opens are distinct. -/
theorem reads_nodup (t : Tree) (c : Config) (root : Path) : (resolveIn t c root).reads.Nodup :=
  (runIn_inv t c root).nodup

/--
**The read set** (R7, P1): every file a run opens is a package's own file
(its `package.haus`, `schema.haus` or `package.json`, a regular file directly
in a directory with a `package.haus`, never through a link), a schema file
(a regular file whose real path ends in `.schema.haus`, or the root), or the
`package.json` that a directory above a schema file names, as its real path.
-/
theorem reads_allowed (t : Tree) (c : Config) (root : Path) : ∀ p ∈ (resolveIn t c root).reads, Allowed t root p :=
  (runIn_inv t c root).allowed

/-- At most 256 schema files (by default) are loaded, the root included (R4, §13.3): `countFile` fails first. -/
theorem count_le (t : Tree) (c : Config) (root : Path) : (runIn t c root).2.count ≤ c.limits.files :=
  (runIn_inv t c root).count

/--
**Bounded lookups** (R4, P3): the searches for a package (`candidates`, each
an npm walk of at most one `realPath` per directory above the importer) are
at most the imports of the schema files loaded, so at most the number of
files loaded times the most imports in one file.
-/
theorem lookups_le (t : Tree) (c : Config) (root : Path) :
    (runIn t c root).2.lookups ≤ (runIn t c root).2.imports ∧
    (runIn t c root).2.imports ≤ (runIn t c root).2.count * (runIn t c root).2.widest := by
  obtain ⟨⟨_, _, _, _, hsc, hi⟩, hl⟩ := runIn_K t c root
  exact ⟨by omega, Nat.le_trans hi (Nat.mul_le_mul_right _ hsc)⟩

theorem lookups_le_files (t : Tree) (c : Config) (root : Path) :
    (runIn t c root).2.lookups ≤ c.limits.files * (runIn t c root).2.widest := by
  have ⟨h1, h2⟩ := lookups_le t c root
  exact Nat.le_trans h1 (Nat.le_trans h2 (Nat.mul_le_mul_right _ (count_le t c root)))

theorem kindAt_file_mem {t : Tree} {p : Path} (h : t.kindAt? p = some .file) : p ∈ t.entries.map (·.1) := by
  unfold Tree.kindAt? Tree.at? at h
  rcases hp : p.getLast? with _ | n
  · simp [hp, Entry.kind] at h
  · simp only [hp] at h
    unfold Tree.child? at h
    split at h
    · unfold Tree.get? at h
      split at h
      · simp [Entry.kind] at h
      · obtain ⟨e, he, -⟩ := Option.map_eq_some_iff.mp h
        obtain ⟨⟨q, e'⟩, hq, rfl⟩ := Option.map_eq_some_iff.mp he
        have hq' := List.find?_some hq
        have hmem := List.mem_of_find?_eq_some hq
        simp only [beq_iff_eq] at hq'
        have hpd : p.dropLast ++ [n] = p := by
          have hne : p ≠ [] := by rintro rfl; simp at hp
          rw [List.getLast?_eq_some_getLast hne] at hp
          cases hp
          exact List.dropLast_concat_getLast hne
        exact List.mem_map.mpr ⟨_, hmem, by rw [hq', hpd]⟩
    · simp at h

theorem Allowed.file {t : Tree} {root p : Path} (h : Allowed t root p) : t.kindAt? p = some .file := by
  rcases h with ⟨dir, name, rfl, -, hk, -⟩ | ⟨hk, -⟩ | ⟨-, -, -, -, -, hk⟩
  · simpa [Tree.kindAt?, Tree.at?, Tree.childKind?] using hk
  · exact hk
  · exact hk

/-- A run opens at most as many files as the tree has entries (R4). -/
theorem reads_length_le (t : Tree) (c : Config) (root : Path) :
    (resolveIn t c root).reads.length ≤ t.entries.length := by
  have := (reads_nodup t c root).length_le_of_subset (l₂ := t.entries.map (·.1))
    fun p hp => kindAt_file_mem (reads_allowed t c root p hp).file
  simpa using this

end Haus.Packages
