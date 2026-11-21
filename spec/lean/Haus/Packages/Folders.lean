import Haus.Packages.Walk

/-!
# Folders are conservative (R6, security review F2)

Adding a folder of packages never turns one successful result into a
different successful result: it gives the same packages or an error
(`resolveIn_addFolders`; `resolveIn_folders` for any settings with more
folders and everything else the same, `MoreFolders`).

A folder only adds packages given with `byDir` false (`givenPackages_ok`:
the packages given are exactly those of the directories and folders given),
so every candidate set of an import only grows (`Wider`, `Wider.cand`);
`declared`, the npm walk, manifests and files are the same. Two successful
runs, `S` without the folders and `S'` with them (both `Good`, R3's
`load_good`), make the same packages:

* Every target a run finishes is reached from the root (`Reach`,
  `load_reach`): the root, or what a reached target's import loads
  (`Loads`: the file it names or a candidate).
* Without ⊆ with: what the run without the folders reaches, `S'` has
  finished, since `S'` is closed under the larger candidate sets
  (`Good.loads_wider`). So every package of `S` is one of `S'`.
* With ⊆ without: what the run with the folders reaches is a file `S`
  finished, or a copy of a package whose name a copy `S` finished has
  (`InWithout`). A copy only in a folder has its name, so in `S'` the class
  of that copy, so the same schema and imports (`Good.same_scan`, one
  package per name); those imports resolve in `S` (R3's `Local`), to copies
  with the names imported. So every package of `S'` has the name of one of
  `S`, whose copy `S'` finished too, with its version.
-/

namespace Haus.Packages

/-! ## Reachability: every target a run finishes is reached from the root -/

/-- `T`'s schema, as `load` reads it: who imports, and its imports. -/
def Scan (V : View) : Target → Importer → List Import → Prop
  | .file p, importer, imps => ∃ bs sc, fileBytes V.tree p V.limits.schemaFile = some bs ∧ decodeV bs = some sc ∧
      importer = .app p ∧ imps = sc.imports
  | .copy d, importer, imps => ∃ m npm bs sc, manifestV V d = some (some m) ∧ npmOf V d = some npm ∧
      pkgFile V.tree d "schema.haus" V.limits.schemaFile = some (some bs) ∧ decodeV bs = some sc ∧
      importer = .pkg d m.name npm ∧ imps = sc.imports

/-- A target that the import `imp` of `importer` loads: the file it names, or a candidate. -/
def Res (V : View) (importer : Importer) (imp : Import) (T : Target) : Prop :=
  match imp.module, importer with
  | .file path, .app p => ∃ real, resolve V.tree maxLinks p.dropLast (fileComps path) = .ok real ∧ T = .file real
  | .pkg name _, _ => ∃ cands, candV V importer name = some cands ∧ ∃ c ∈ cands, T = .copy c.1
  | _, _ => False

/-- Loading `T` loads `T'`. -/
def Loads (V : View) (T T' : Target) : Prop :=
  ∃ importer imps, Scan V T importer imps ∧ ∃ imp ∈ imps, Res V importer imp T'

/-- `T` is reached from `T₀`. -/
inductive Reach (V : View) (T₀ : Target) : Target → Prop
  | refl : Reach V T₀ T₀
  | tail {T T' : Target} : Reach V T₀ T → Loads V T T' → Reach V T₀ T'

/-- Every target finished is reached from `T₀`. -/
def RInv (V : View) (T₀ : Target) (κ : Core) : Prop := ∀ T ∈ κ.finished, Reach V T₀ T

/-- A state of a run that loads `T₀`. -/
abbrev RI (env : Env) (T₀ : Target) (s : St) : Prop := Tr env.view s ∧ RInv env.view T₀ s.core

section Reach
variable {α : Type} {env : Env} {T₀ : Target}

/-- A step that keeps the caches truthful and the targets finished. -/
theorem RI.step {x : M α}
    (h : ∀ κ, Triple env (At env κ) x (fun _ s => Tr env.view s ∧ s.core.finished = κ.finished) (fun _ => True)) :
    Triple env (RI env T₀) x (fun _ => RI env T₀) (fun _ => True) := by
  intro s hs
  have := h s.core s ⟨hs.1, rfl⟩
  revert this
  rcases go x env s with ⟨r, s'⟩
  cases r with
  | error e => intro _; exact True.intro
  | ok a =>
    intro ⟨h1, h2⟩
    refine ⟨h1, fun T hT => hs.2 T ?_⟩
    rw [← h2]; exact hT

theorem RI.pure {x : M α} {v : Option α} (h : Pure env x v) :
    Triple env (RI env T₀) x (fun r s => RI env T₀ s ∧ v = some r) (fun _ => True) :=
  Triple.mono (Pure.triple (I := RInv env.view T₀) h) (fun _ h => h) (fun _ _ h => h) (fun _ _ => True.intro)

theorem RI.countFile {what : String} : Triple env (RI env T₀) (countFile what) (fun _ => RI env T₀) (fun _ => True) :=
  RI.step fun _ => Triple.mono countFile_atA (fun _ h => h) (fun _ _ h => ⟨h.1, by rw [h.2]; rfl⟩) (fun _ h => h)

theorem RI.checkVersion {m : Manifest} {npm : Option NpmInfo} {owner : String} :
    Triple env (RI env T₀) (checkVersion env.config m npm owner) (fun _ => RI env T₀) (fun _ => True) :=
  RI.step fun _ => Triple.mono checkVersion_atA (fun _ h => h) (fun _ _ h => ⟨h.1.1, by rw [h.1.2]⟩) (fun _ h => h)

theorem RI.checkNoFiles {m : Manifest} {sc : Scanned} :
    Triple env (RI env T₀) (checkNoFiles m sc) (fun _ => RI env T₀) (fun _ => True) :=
  RI.step fun _ => Triple.mono checkNoFiles_atA (fun _ h => h) (fun _ _ h => ⟨h.1.1, by rw [h.1.2]⟩) (fun _ h => h)

theorem RI.classify {c : Class} : Triple env (RI env T₀) (classify c) (fun _ => RI env T₀) (fun _ => True) :=
  RI.step fun _ => Triple.mono classify_at (fun _ h => h)
    (fun _ _ h => ⟨h.1, by obtain ⟨cs, -, e⟩ := h.2; rw [e]⟩) (fun _ _ => True.intro)

theorem resolveImport_reach {loadFn : Target → M Loaded} {importer : Importer} {imp : Import}
    (hload : ∀ T, Reach env.view T₀ T → Triple env (RI env T₀) (loadFn T) (fun _ => RI env T₀) (fun _ => True))
    (hres : ∀ T, Res env.view importer imp T → Reach env.view T₀ T) :
    Triple env (RI env T₀) (resolveImport loadFn importer imp) (fun _ => RI env T₀) (fun _ => True) := by
  unfold resolveImport
  split
  · exact Triple.pure fun _ h => h
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
    split
    · exact Triple.bind_fail fun _ _ => True.intro
    apply Triple.bind_look
    split
    · exact Triple.bind_fail fun _ _ => True.intro
    refine Triple.bind (hload _ (hres _ ?_)) fun r => ?_
    · simp only [Res, heq]; exact ⟨real, hreal, rfl⟩
    exact Triple.bind (RI.pure Pure.checkNames) fun _ => Triple.pure fun _ h => h.1
  · rename_i name major heq
    refine Triple.bind (RI.pure Pure.candidates) fun cands => Triple.pre_and fun hc => ?_
    dsimp only
    refine Triple.bind (Triple.forIn (b := none) (fun _ _ => RI env T₀) ?_ fun _ _ h => h)
      fun r => Triple.pure fun _ h => h
    intro c rest b hsuf
    obtain ⟨dir, shown⟩ := c
    have hr : Res env.view importer imp (.copy dir) := by
      simp only [Res, heq]; exact ⟨cands, hc, (dir, shown), hsuf.subset List.mem_cons_self, rfl⟩
    refine Triple.bind (RI.pure Pure.manifestOf) fun mo => Triple.pre_and fun _ => ?_
    split
    · rename_i m
      dsimp only
      split
      · exact Triple.bind_fail fun _ _ => True.intro
      have tail : ∀ {Q : ForInStep (Option Nat) → St → Prop}, (∀ b' s, RI env T₀ s → Q (.yield b') s) →
          Triple env (RI env T₀) (do
            let r ← loadFn (Target.copy dir)
            if b.isNone = true then do
                checkNames imp r.types name
                pure (ForInStep.yield r.cls)
              else do
                checkNames imp r.types name
                pure (ForInStep.yield b)) Q (fun _ => True) := by
        intro Q hQ
        refine Triple.bind (hload _ (hres _ hr)) fun r => ?_
        split
        · exact Triple.bind (RI.pure Pure.checkNames) fun _ => Triple.pure fun s hs => hQ _ s hs.1
        · exact Triple.bind (RI.pure Pure.checkNames) fun _ => Triple.pure fun s hs => hQ _ s hs.1
      cases major with
      | none => dsimp only; exact tail fun _ _ h => h
      | some n =>
        dsimp only
        split
        · exact Triple.bind_fail fun _ _ => True.intro
        · exact tail fun _ _ h => h
    · exact Triple.bind_fail fun _ _ => True.intro

theorem RI.finish {T : Target} (hT : Reach env.view T₀ T) {g : St → St}
    (hg : ∀ s, Tr env.view s → Tr env.view (g s)) (hf : ∀ s, (g s).finished = addNew s.finished T) :
    Triple env (RI env T₀) (modify g >>= fun _ => (Pure.pure () : M Unit)) (fun _ => RI env T₀) (fun _ => True) := by
  refine Triple.bind_modify (RI env T₀) (fun s h => ⟨hg s h.1, fun T' hT' => ?_⟩) (Triple.pure fun _ h => h)
  change T' ∈ (g s).finished at hT'
  rw [hf] at hT'
  rcases mem_addNew_iff.mp hT' with h' | rfl
  · exact h.2 T' h'
  · exact hT

theorem load_reach {w : Walk} : ∀ n T, Reach env.view T₀ T →
    Triple env (RI env T₀) (load w n T) (fun _ => RI env T₀) (fun _ => True)
  | 0, _, _ => by unfold load; exact Triple.fail fun _ _ => True.intro
  | n + 1, .file p, hT => by
    unfold load
    apply Triple.bind_get'; intro s₀ _
    dsimp only
    split
    · exact Triple.pure fun _ h => h
    · exact Triple.fail fun _ _ => True.intro
    refine Triple.bind_modify' (fun s h => ⟨⟨h.1.manifests, h.1.npm⟩, h.2⟩) ?_
    apply Triple.bind_cfg
    refine Triple.bind (RI.pure Pure.openFile) fun bytes => Triple.pre_and fun hb => ?_
    refine Triple.bind RI.countFile fun _ => ?_
    refine Triple.bind (RI.pure Pure.decodeScan) fun sc => Triple.pre_and fun hsc => ?_
    refine Triple.bind (RI.pure Pure.noteImports) fun _ => Triple.pre_and fun _ => ?_
    refine Triple.bind (Triple.forIn (b := PUnit.unit) (fun _ _ => RI env T₀) ?_ fun _ _ h => h) fun _ => ?_
    · intro imp rest b hsuf
      have hmem : imp ∈ sc.imports := (w.perm _).mem_iff.mp (hsuf.subset List.mem_cons_self)
      exact Triple.bind (resolveImport_reach (fun T h => load_reach n T h)
        fun T' hres => Reach.tail hT ⟨.app p, sc.imports, ⟨bytes, sc, hb, hsc, rfl, rfl⟩, imp, hmem, hres⟩)
        fun _ => Triple.pure fun _ h => h
    · exact RI.finish hT (fun s h => ⟨h.manifests, h.npm⟩) fun _ => rfl
  | n + 1, .copy dir, hT => by
    unfold load
    apply Triple.bind_get'; intro s₀ _
    split
    · apply Triple.bind_get'; intro s₁ _
      exact Triple.pure fun _ h => h
    · exact Triple.fail fun _ _ => True.intro
    refine Triple.bind_modify' (fun s h => ⟨⟨h.1.manifests, h.1.npm⟩, h.2⟩) ?_
    apply Triple.bind_cfg
    refine Triple.bind (RI.pure Pure.manifestOf) fun mo => Triple.pre_and fun hm => ?_
    cases mo with
    | none => exact Triple.fail fun _ _ => True.intro
    | some m =>
    dsimp only
    refine Triple.bind (RI.pure Pure.copyNpm) fun npm => Triple.pre_and fun hnpm => ?_
    refine Triple.bind RI.checkVersion fun _ => ?_
    refine Triple.bind (RI.pure Pure.openPackageFile) fun bo => Triple.pre_and fun hbo => ?_
    cases bo with
    | none => exact Triple.fail fun _ _ => True.intro
    | some bytes =>
    dsimp only
    refine Triple.bind RI.countFile fun _ => ?_
    refine Triple.bind (RI.pure Pure.decodeScan) fun sc => Triple.pre_and fun hsc => ?_
    refine Triple.bind (RI.pure Pure.noteImports) fun _ => Triple.pre_and fun _ => ?_
    refine Triple.bind RI.checkNoFiles fun _ => ?_
    refine Triple.bind (Triple.forIn (b := []) (fun _ _ => RI env T₀) ?_ fun _ _ h => h) fun targets => ?_
    · intro imp rest b hsuf
      have hmem : imp ∈ sc.imports := (w.perm _).mem_iff.mp (hsuf.subset List.mem_cons_self)
      refine Triple.bind (resolveImport_reach (fun T h => load_reach n T h)
        fun T' hres => Reach.tail hT ⟨.pkg dir m.name npm, sc.imports,
          ⟨m, npm, bytes, sc, hm, hnpm, hbo, hsc, rfl, rfl⟩, imp, hmem, hres⟩) fun r => ?_
      split
      · exact Triple.pure fun _ h => h
      · exact Triple.pure fun _ h => h
    · refine Triple.bind RI.classify fun i => ?_
      refine Triple.bind_modify (RI env T₀) (fun s h => ⟨⟨h.1.manifests, h.1.npm⟩, fun T' hT' => ?_⟩)
        (Triple.pure fun _ h => h)
      rcases mem_addNew_iff.mp hT' with h' | rfl
      · exact h.2 T' h'
      · exact hT

end Reach

/-! ## What a target's checks say of the targets it loads -/

theorem Local.imports {V : View} {P : Target → Prop} {T : Target} {importer : Importer} {imps : List Import}
    (hl : Local V P T) (hs : Scan V T importer imps) : ∀ imp ∈ imps, ImpOk V P importer imp := by
  cases T with
  | file p =>
    obtain ⟨bs, sc, h1, h2, h3⟩ := hl
    obtain ⟨bs', sc', h1', h2', rfl, rfl⟩ := hs
    rw [h1] at h1'; cases h1'
    rw [h2] at h2'; cases h2'
    exact h3
  | copy d =>
    obtain ⟨m, npm, bs, sc, h1, h2, -, h4, h5, -, h7⟩ := hl
    obtain ⟨m', npm', bs', sc', h1', h2', h4', h5', rfl, rfl⟩ := hs
    rw [h1] at h1'; cases h1'
    rw [h2] at h2'; cases h2'
    rw [h4] at h4'; cases h4'
    rw [h5] at h5'; cases h5'
    exact h7

theorem ImpOk.res {V : View} {P : Target → Prop} {importer : Importer} {imp : Import} {T : Target}
    (h : ImpOk V P importer imp) (hr : Res V importer imp T) : P T := by
  unfold ImpOk at h
  unfold Res at hr
  split at h
  · rename_i heq; rw [heq] at hr; exact hr.elim
  · rename_i path heq
    rw [heq] at hr
    split at h
    · exact h.elim
    · obtain ⟨real, h1, -, -, -, h5, -⟩ := h
      obtain ⟨real', h1', rfl⟩ := hr
      rw [h1] at h1'; cases h1'
      exact h5
  · rename_i name major heq
    rw [heq] at hr
    obtain ⟨cands, hc, h⟩ := h
    obtain ⟨cands', hc', c, hcm, rfl⟩ := hr
    rw [hc] at hc'; cases hc'
    obtain ⟨-, -, -, -, hP, -⟩ := h c hcm
    exact hP

/-- The last state of a successful run is closed: what a finished target loads is finished. -/
theorem Good.loads {V : View} {κ : Core} (h : Good V 0 κ) {T T' : Target} (hT : T ∈ κ.finished)
    (hl : Loads V T T') : T' ∈ κ.finished := by
  obtain ⟨importer, imps, hs, imp, hi, hr⟩ := hl
  exact (((h.local_ T hT).imports hs imp hi).res hr).1

/-! ## A run with more packages in folders -/

/--
`V'` is `V` with more packages in folders: the same files and settings, and
the same packages given by their directory.
-/
structure Wider (V V' : View) : Prop where
  tree : V'.tree = V.tree
  limits : V'.limits = V.limits
  npm : V'.mode.npm = V.mode.npm
  worldWritable : V'.worldWritable = V.worldWritable
  checkVersions : V'.checkVersions = V.checkVersions
  given : ∀ g ∈ V.given, g ∈ V'.given
  byDir : ∀ g ∈ V'.given, g.byDir = true → g ∈ V.given

section Wider
variable {V V' : View}

theorem Wider.manifestV (hw : Wider V V') (d : Path) : manifestV V' d = manifestV V d := by
  unfold Haus.Packages.manifestV; rw [hw.tree, hw.limits]

theorem Wider.npmOf (hw : Wider V V') (d : Path) : npmOf V' d = npmOf V d := by
  unfold Haus.Packages.npmOf packageJsonV; rw [hw.tree, hw.limits, hw.npm, hw.checkVersions]

theorem Wider.scan (hw : Wider V V') {T : Target} {importer : Importer} {imps : List Import} :
    Scan V' T importer imps ↔ Scan V T importer imps := by
  cases T <;> simp only [Scan, hw.manifestV, hw.npmOf, hw.tree, hw.limits]

theorem Wider.corr (hw : Wider V V') {d : Path} {c : Class} : Corr V' d c ↔ Corr V d c := by
  unfold Corr; rw [hw.manifestV, hw.tree, hw.limits]

theorem Wider.declaredV (hw : Wider V V') (importer : Importer) :
    Haus.Packages.declaredV V' importer = Haus.Packages.declaredV V importer := by
  cases importer <;> simp only [Haus.Packages.declaredV, projectV, projectStep, hw.tree, hw.limits]

/-- Every candidate without the folders is one with them (by its directory). -/
theorem Wider.cand (hw : Wider V V') {importer : Importer} {name : String} {cands cands' : List (Path × String)}
    (hc : candV V importer name = some cands) (hc' : candV V' importer name = some cands') :
    ∀ c ∈ cands, ∃ c' ∈ cands', c'.1 = c.1 := by
  intro c hcm
  unfold candV at hc hc'
  dsimp only at hc hc'
  by_cases hb : (V.given.filter fun g => g.byDir && g.name == name).isEmpty = true
  · have hb' : (V'.given.filter fun g => g.byDir && g.name == name).isEmpty = true := by
      rw [List.isEmpty_iff, List.filter_eq_nil_iff]
      intro g hg hgb
      simp only [Bool.and_eq_true, beq_iff_eq] at hgb
      have : g ∈ V.given.filter fun g => g.byDir && g.name == name :=
        List.mem_filter.mpr ⟨hw.byDir g hg hgb.1, by simp [hgb]⟩
      rw [List.isEmpty_iff.mp hb] at this
      simp at this
    rw [if_neg' (by simp [hb])] at hc
    rw [if_neg' (by simp [hb'])] at hc'
    obtain ⟨f, hF, hc⟩ := Option.bind_eq_some_iff.mp hc
    obtain ⟨f', hF', hc'⟩ := Option.bind_eq_some_iff.mp hc'
    split at hc
    · cases hc
    cases hc
    split at hc'
    · cases hc'
    cases hc'
    rcases List.mem_append.mp hcm with h1 | h1
    · obtain ⟨g, hg, rfl⟩ := List.mem_map.mp h1
      obtain ⟨hg, hgb⟩ := List.mem_filter.mp hg
      exact ⟨(g.dir, g.shown), List.mem_append_left _
        (List.mem_map.mpr ⟨g, List.mem_filter.mpr ⟨hw.given g hg, hgb⟩, rfl⟩), rfl⟩
    · have hcf : c ∈ f := (List.mem_filter.mp h1).1
      have key : c ∈ f' := by
        rw [hw.npm, hw.declaredV, hw.tree, hw.worldWritable] at hF'
        split at hF
        · cases hF; simp at hcf
        rename_i hnpm
        rw [if_neg' hnpm] at hF'
        obtain ⟨x, hx, hF⟩ := Option.bind_eq_some_iff.mp hF
        obtain ⟨x', hx', hF'⟩ := Option.bind_eq_some_iff.mp hF'
        rw [hx] at hx'; cases hx'
        split at hF
        · rename_i hin
          rw [if_pos' hin, hF] at hF'
          cases hF'
          exact hcf
        · split at hF
          · cases hF
          · cases hF; simp at hcf
      by_cases hin : ((V'.given.filter fun g => !g.byDir && g.name == name).map fun g => (g.dir, g.shown)).any
          (·.1 == c.1) = true
      · obtain ⟨c', hc', e⟩ := List.any_eq_true.mp hin
        exact ⟨c', List.mem_append_left _ hc', by simpa using e⟩
      · exact ⟨c, List.mem_append_right _ (List.mem_filter.mpr ⟨key, by simpa using hin⟩), rfl⟩
  · rw [if_pos' (by simpa using hb)] at hc
    cases hc
    have hne : (V'.given.filter fun g => g.byDir && g.name == name).isEmpty = false := by
      obtain ⟨g, hg, rfl⟩ := List.mem_map.mp hcm
      obtain ⟨hg, hgb⟩ := List.mem_filter.mp hg
      cases e : (V'.given.filter fun g => g.byDir && g.name == name).isEmpty
      · rfl
      · have : g ∈ V'.given.filter fun g => g.byDir && g.name == name :=
          List.mem_filter.mpr ⟨hw.given g hg, hgb⟩
        rw [List.isEmpty_iff.mp e] at this
        simp at this
    rw [if_pos' (by simp [hne])] at hc'
    cases hc'
    obtain ⟨g, hg, rfl⟩ := List.mem_map.mp hcm
    obtain ⟨hg, hgb⟩ := List.mem_filter.mp hg
    exact ⟨(g.dir, g.shown), List.mem_map.mpr ⟨g, List.mem_filter.mpr ⟨hw.given g hg, hgb⟩, rfl⟩, rfl⟩

/--
What a target loads without the folders, a successful run with them loads
too, once it has finished the target (the candidates only grow).
-/
theorem Good.loads_wider (hw : Wider V V') {κ : Core} (h : Good V' 0 κ) {T T' : Target} (hT : T ∈ κ.finished)
    (hl : Loads V T T') : T' ∈ κ.finished := by
  obtain ⟨importer, imps, hs, imp, hi, hr⟩ := hl
  have himp := (h.local_ T hT).imports (hw.scan.mpr hs) imp hi
  unfold ImpOk at himp
  unfold Res at hr
  split at himp
  · rename_i heq; rw [heq] at hr; exact hr.elim
  · rename_i path heq
    rw [heq] at hr
    split at himp
    · exact himp.elim
    · obtain ⟨real, h1, -, -, -, h5, -⟩ := himp
      obtain ⟨real', h1', rfl⟩ := hr
      rw [hw.tree] at h1; rw [h1] at h1'; cases h1'
      exact h5.1
  · rename_i name major heq
    rw [heq] at hr
    obtain ⟨cands', hc', hall⟩ := himp
    obtain ⟨cands, hc, c, hcm, rfl⟩ := hr
    obtain ⟨c', hc'm, e⟩ := hw.cand hc hc' c hcm
    obtain ⟨-, -, -, -, hP, -⟩ := hall c' hc'm
    rw [e] at hP; exact hP.1

end Wider

/-! ## Two whole runs -/

theorem Local.scan {V : View} {P : Target → Prop} {T : Target} (h : Local V P T) :
    ∃ importer imps, Scan V T importer imps := by
  cases T with
  | file p => obtain ⟨bs, sc, h1, h2, -⟩ := h; exact ⟨_, _, bs, sc, h1, h2, rfl, rfl⟩
  | copy d =>
    obtain ⟨m, npm, bs, sc, h1, h2, -, h4, h5, -⟩ := h
    exact ⟨_, _, m, npm, bs, sc, h1, h2, h4, h5, rfl, rfl⟩

/-- An import of a package that resolves names a finished copy of a package with that name. -/
theorem ImpOk.found {V : View} {P : Target → Prop} {importer : Importer} {imp : Import} {name : String}
    {major : Option String} (h : ImpOk V P importer imp) (hm : imp.module = .pkg name major) :
    ∃ d m, P (.copy d) ∧ manifestV V d = some (some m) ∧ m.name = name := by
  unfold ImpOk at h
  rw [hm] at h
  obtain ⟨cands, hc, hall⟩ := h
  cases cands with
  | nil => exact absurd rfl (candV_ne_nil hc)
  | cons c _ =>
    obtain ⟨m, h1, h2, -, h4, -⟩ := hall c List.mem_cons_self
    exact ⟨c.1, m, h4, h1, h2⟩

/-- Two copies with packages of the same name. -/
def SameName (V : View) (d e : Path) : Prop :=
  ∃ m m', manifestV V d = some (some m) ∧ manifestV V e = some (some m') ∧ m.name = m'.name

/-- What a target that a run with more folders reaches is, in the run without them. -/
def InWithout (V : View) (fin : List Target) : Target → Prop
  | .file p => .file p ∈ fin
  | .copy d => ∃ e, .copy e ∈ fin ∧ SameName V d e

/-- Two copies with packages of the same name have the same class in a successful run, so the same schema. -/
theorem Good.same_scan {V : View} {κ : Core} (h : Good V 0 κ) {d e : Path} (hd : .copy d ∈ κ.finished)
    (he : .copy e ∈ κ.finished) (hn : SameName V d e) {importer : Importer} {imps : List Import}
    (hs : Scan V (.copy d) importer imps) : ∃ importer', Scan V (.copy e) importer' imps := by
  obtain ⟨cd, hcd, hcorrd⟩ := h.finCls d hd
  obtain ⟨ce, hce, hcorre⟩ := h.finCls e he
  obtain ⟨m, m', hm, hm', hmn⟩ := hn
  obtain ⟨md, bsd, scd, h1, h2, h3, h4, -, -, h7, -⟩ := hcorrd
  obtain ⟨me, bse, sce, h1', h2', h3', h4', -, -, h7', -⟩ := hcorre
  rw [hm] at h1; cases h1
  rw [hm'] at h1'; cases h1'
  have : cd = ce := eq_of_nodup_map κ.classes.distinct hcd hce (by rw [h4, h4', hmn])
  subst this
  have hb : bse = bsd := h7'.symm.trans h7
  subst hb
  rw [h3] at h3'; cases h3'
  obtain ⟨m₁, npm₁, bs₁, sc₁, e1, -, e3, e4, -, rfl⟩ := hs
  rw [hm] at e1; cases e1
  rw [h2] at e3; cases e3
  rw [h3] at e4; cases e4
  obtain ⟨-, npme, -, -, -, hnpme, -⟩ := h.local_ (.copy e) he
  exact ⟨_, m', npme, _, _, hm', hnpme, h2', h3, rfl, rfl⟩

/--
**Folders are conservative, for `load`** (R6): two successful loads of `T₀`
from a state with no targets and no classes, the second with more packages
in folders (`Wider`), make the same packages, with the same versions.
-/
theorem load_wider {env env' : Env} {w w' : Walk} {T₀ : Target} {n n' : Nat} {s₁ s₁' S S' : St} {r r' : Loaded}
    (hw : Wider env.view env'.view)
    (htr : Tr env.view s₁) (hcore : s₁.core = Core.empty) (htr' : Tr env'.view s₁') (hcore' : s₁'.core = Core.empty)
    (hA : go (load w n T₀) env s₁ = (.ok r, S)) (hB : go (load w' n' T₀) env' s₁' = (.ok r', S')) :
    ClassesIn S S' ∧ ClassesIn S' S := by
  have gA := load_good (w := w) n T₀ s₁.core s₁ ⟨htr, hcore ▸ Good.empty, Grows.refl _⟩
  rw [hA] at gA
  obtain ⟨⟨-, hg, -⟩, hret⟩ := gA
  have gB := load_good (w := w') n' T₀ s₁'.core s₁' ⟨htr', hcore' ▸ Good.empty, Grows.refl _⟩
  rw [hB] at gB
  obtain ⟨⟨-, hg', -⟩, hret'⟩ := gB
  have rA := load_reach (T₀ := T₀) (w := w) n T₀ Reach.refl s₁
    ⟨htr, fun T h => by rw [hcore] at h; simp [Core.empty] at h⟩
  rw [hA] at rA
  have rB := load_reach (T₀ := T₀) (w := w') n' T₀ Reach.refl s₁'
    ⟨htr', fun T h => by rw [hcore'] at h; simp [Core.empty] at h⟩
  rw [hB] at rB
  -- Without ⊆ with: what the run without the folders reaches, the run with them finishes.
  have hfin : ∀ T, Reach env.view T₀ T → T ∈ S'.finished := by
    intro T h
    induction h with
    | refl => exact hret'.1
    | tail _ hl ih => exact hg'.loads_wider hw ih hl
  have hsub : ∀ T ∈ S.finished, T ∈ S'.finished := fun T hT => hfin T (rA.2 T hT)
  -- With ⊆ without: a file the run with the folders reaches, the run without them finishes; a copy
  -- has a package of the same name as a copy it finishes.
  have hback : ∀ T, Reach env'.view T₀ T → T ∈ S'.finished ∧ InWithout env.view S.finished T := by
    intro T h
    induction h with
    | refl =>
      refine ⟨hret'.1, ?_⟩
      cases T₀ with
      | file p => exact hret.1
      | copy d =>
        obtain ⟨m, -, -, -, h1, -⟩ := hg.local_ _ hret.1
        exact ⟨d, hret.1, m, m, h1, h1, rfl⟩
    | @tail T T' _ hl ih =>
      obtain ⟨hT', hQ⟩ := ih
      refine ⟨hg'.loads hT' hl, ?_⟩
      obtain ⟨importer, imps, hs, imp, hi, hr⟩ := hl
      obtain ⟨E, hE, importerE, hsE, hfile⟩ : ∃ E ∈ S.finished, ∃ importerE, Scan env.view E importerE imps ∧
          ∀ p, importer = .app p → E = .file p ∧ importerE = .app p := by
        cases T with
        | file p =>
          refine ⟨.file p, hQ, importer, hw.scan.mp hs, fun q hq => ?_⟩
          obtain ⟨-, -, -, -, rfl, -⟩ := hs
          cases hq; exact ⟨rfl, rfl⟩
        | copy D =>
          obtain ⟨e, he, hn⟩ := hQ
          have hn' : SameName env'.view D e := by
            obtain ⟨m, m', h1, h2, h3⟩ := hn
            exact ⟨m, m', by rw [hw.manifestV]; exact h1, by rw [hw.manifestV]; exact h2, h3⟩
          obtain ⟨importer', hs'⟩ := hg'.same_scan hT' (hsub _ he) hn' hs
          refine ⟨.copy e, he, importer', hw.scan.mp hs', fun p hp => absurd hp ?_⟩
          obtain ⟨-, -, -, -, -, -, -, -, rfl, -⟩ := hs
          exact fun h => nomatch h
      have himpE := (hg.local_ E hE).imports hsE imp hi
      have himp' := (hg'.local_ T hT').imports hs imp hi
      unfold Res at hr
      rcases hmod : imp.module with nm | ⟨y, mj⟩ | path
      · rw [hmod] at hr; exact hr.elim
      · rw [hmod] at hr
        obtain ⟨cands, hc, c, hcm, rfl⟩ := hr
        obtain ⟨d0, m0, hP0, hm0, hn0⟩ := himpE.found hmod
        unfold ImpOk at himp'
        rw [hmod] at himp'
        obtain ⟨cands', hc', hall⟩ := himp'
        rw [hc] at hc'; cases hc'
        obtain ⟨m, hm, hmn, -⟩ := hall c hcm
        exact ⟨d0, hP0.1, m, m0, by rw [← hw.manifestV]; exact hm, hm0, hmn.trans hn0.symm⟩
      · rw [hmod] at hr
        cases importer with
        | pkg => exact hr.elim
        | app p =>
          obtain ⟨real, hreal, rfl⟩ := hr
          obtain ⟨rfl, rfl⟩ := hfile p rfl
          unfold ImpOk at himpE
          rw [hmod] at himpE
          obtain ⟨real', h1, -, -, -, h5, -⟩ := himpE
          rw [hw.tree] at hreal; rw [hreal] at h1; cases h1
          exact h5.1
  refine ⟨fun c hc => ?_, fun c hc => ?_⟩
  · obtain ⟨d, hd, hcd⟩ := hg.clsFin c hc
    obtain ⟨c', hc', hcd'⟩ := hg'.finCls d (hsub _ hd)
    obtain ⟨n1, v1, -⟩ := Corr.unique hcd (hw.corr.mp hcd')
    exact ⟨c', hc', n1.symm, v1.symm⟩
  · obtain ⟨d, hd, hcd⟩ := hg'.clsFin c hc
    obtain ⟨-, e, he, m, m', hm, hm', hmn⟩ := hback _ (rB.2 _ hd)
    obtain ⟨ce, hce, hcorre⟩ := hg'.finCls e (hsub _ he)
    obtain ⟨cS, hcS, hcorrS⟩ := hg.finCls e he
    have hcn : c.name = m.name := by
      obtain ⟨m1, -, -, h1, -, -, h4, -⟩ := hcd
      rw [hw.manifestV, hm] at h1; cases h1; exact h4
    have hcen : ce.name = m'.name := by
      obtain ⟨m1, -, -, h1, -, -, h4, -⟩ := hcorre
      rw [hw.manifestV, hm'] at h1; cases h1; exact h4
    have : ce = c := eq_of_nodup_map S'.classes.distinct hce hc (by rw [hcn, hcen, hmn])
    subst this
    obtain ⟨n1, v1, -⟩ := Corr.unique hcorrS (hw.corr.mp hcorre)
    exact ⟨cS, hcS, n1, v1⟩

/-! ## The packages given -/

/-- The package given by its directory `d`. -/
def PkgEntry (V : View) (d : Path) (g : Given) : Prop :=
  ∃ real m, V.tree.realPath d = .ok real ∧ manifestV V real = some (some m) ∧
    g = { dir := real, shown := showPath d, name := m.name, byDir := true }

/-- The package of the entry `n` of the folder `f`, whose real path is `real`. -/
def FolderAt (V : View) (f real : Path) (n : String) (g : Given) : Prop :=
  ∃ sub m, V.tree.realPath (real ++ [n]) = .ok sub ∧ V.tree.isDir sub = true ∧
    (V.tree.childKind? sub "package.haus").isSome = true ∧ manifestV V sub = some (some m) ∧
    g = { dir := sub, shown := showPath (f ++ [n]), name := m.name, byDir := false }

/-- A package in the folder `f`. -/
def FolderEntry (V : View) (f : Path) (g : Given) : Prop :=
  ∃ real n, V.tree.realPath f = .ok real ∧ n ∈ V.tree.list real ∧ FolderAt V f real n g

/-- The packages given in a successful run: each given by a directory or in a folder, and all of them. -/
structure GivenOk (V : View) (md : Mode) (gs : List Given) : Prop where
  sound : ∀ g ∈ gs, (g.byDir = true ∧ ∃ d ∈ md.packages, PkgEntry V d g) ∨
    (g.byDir = false ∧ ∃ f ∈ md.folders, FolderEntry V f g)
  pkgs : ∀ d ∈ md.packages, ∀ g, PkgEntry V d g → g ∈ gs
  folders : ∀ f ∈ md.folders, ∀ g, FolderEntry V f g → g ∈ gs

theorem PkgEntry.unique {V : View} {d : Path} {g g' : Given} (h : PkgEntry V d g) (h' : PkgEntry V d g') : g' = g := by
  obtain ⟨r, m, h1, h2, rfl⟩ := h
  obtain ⟨r', m', h1', h2', rfl⟩ := h'
  rw [h1] at h1'; cases h1'
  rw [h2] at h2'; cases h2'
  rfl

theorem FolderAt.unique {V : View} {f real : Path} {n : String} {g g' : Given} (h : FolderAt V f real n g)
    (h' : FolderAt V f real n g') : g' = g := by
  obtain ⟨r, m, h1, -, -, h2, rfl⟩ := h
  obtain ⟨r', m', h1', -, -, h2', rfl⟩ := h'
  rw [h1] at h1'; cases h1'
  rw [h2] at h2'; cases h2'
  rfl

theorem givenPackages_ok {env : Env} {κ : Core} :
    Triple env (At env κ) givenPackages (fun r s => At env κ s ∧ GivenOk env.view env.config.mode r.1)
      (fun _ => True) := by
  unfold givenPackages
  apply Triple.bind_cfg
  refine Triple.bind (Triple.mono (Triple.forIn (E := fun _ => True) (b := ([] : List Given))
      (fun rest b s => At env κ s ∧
      ((∀ g ∈ b, g.byDir = true ∧ ∃ d ∈ env.config.mode.packages, PkgEntry env.view d g) ∧
        ∃ pre, pre ++ rest = env.config.mode.packages ∧ ∀ d ∈ pre, ∀ g, PkgEntry env.view d g → g ∈ b)) ?_
      fun _ _ h => h) (fun s hs => ⟨hs, (fun _ h => nomatch h), [], rfl, (fun _ h => nomatch h)⟩)
      (fun _ _ h => h) (fun _ h => h)) fun given => ?_
  · intro d rest b hsuf
    apply Triple.pre_and
    rintro ⟨hsound, pre, hpre, hcomp⟩
    have hd : d ∈ env.config.mode.packages := hsuf.subset List.mem_cons_self
    dsimp only
    apply Triple.bind_look
    split
    · rename_i r hr
      apply Triple.bind_look
      split
      · apply Triple.bind_pure
        refine Triple.bind (Pure.atA Pure.manifestOf) fun mo => Triple.pre_and fun hm => ?_
        split
        · rename_i m
          have hent : PkgEntry env.view d { dir := r, shown := showPath d, name := m.name, byDir := true } :=
            ⟨r, m, hr, hm, rfl⟩
          refine Triple.pure fun s hs => ⟨hs, fun g hg => ?_, pre ++ [d], by rw [← hpre]; simp, fun d' hd' g hg => ?_⟩
          · rcases List.mem_append.mp hg with hg | hg
            · exact hsound g hg
            · simp only [List.mem_singleton] at hg; subst hg; exact ⟨rfl, d, hd, hent⟩
          · rcases List.mem_append.mp hd' with hd' | hd'
            · exact List.mem_append_left _ (hcomp d' hd' g hg)
            · simp only [List.mem_singleton] at hd'; subst hd'
              rw [hent.unique hg]; simp
        · exact Triple.bind_fail fun _ _ => True.intro
      · exact Triple.bind_fail fun _ _ => True.intro
    · exact Triple.bind_fail fun _ _ => True.intro
  · apply Triple.pre_and
    rintro ⟨hsound, pre, hpre, hcomp⟩
    rw [List.append_nil] at hpre
    subst hpre
    dsimp only
    refine Triple.bind (Triple.mono (Triple.forIn (E := fun _ => True) (fun rest b s => At env κ s ∧
        ((∀ g ∈ b.1, (g.byDir = true ∧ ∃ d ∈ env.config.mode.packages, PkgEntry env.view d g) ∨
          (g.byDir = false ∧ ∃ f ∈ env.config.mode.folders, FolderEntry env.view f g)) ∧
        (∀ d ∈ env.config.mode.packages, ∀ g, PkgEntry env.view d g → g ∈ b.1) ∧
        ∃ pre, pre ++ rest = env.config.mode.folders ∧ ∀ f ∈ pre, ∀ g, FolderEntry env.view f g → g ∈ b.1)) ?_
        fun _ _ h => h) ?_ (fun _ _ h => h) (fun _ h => h)) fun gb => ?_
    · intro f rest b hsuf
      apply Triple.pre_and
      rintro ⟨i1, i2, pre, hpre, i3⟩
      have hf : f ∈ env.config.mode.folders := hsuf.subset List.mem_cons_self
      apply Triple.bind_look
      split
      · rename_i r hr
        apply Triple.bind_look
        split
        · apply Triple.bind_pure
          apply Triple.bind_look
          split
          · exact Triple.bind_fail fun _ _ => True.intro
          refine Triple.bind (Triple.mono (Triple.forIn (E := fun _ => True) (fun restN bn s => At env κ s ∧
              ((∀ g ∈ bn.1, (g.byDir = true ∧ ∃ d ∈ env.config.mode.packages, PkgEntry env.view d g) ∨
                (g.byDir = false ∧ ∃ f ∈ env.config.mode.folders, FolderEntry env.view f g)) ∧
              (∀ d ∈ env.config.mode.packages, ∀ g, PkgEntry env.view d g → g ∈ bn.1) ∧
              (∀ f ∈ pre, ∀ g, FolderEntry env.view f g → g ∈ bn.1) ∧
              ∃ preN, preN ++ restN = (env.tree.list r).mergeSort (fun x1 x2 => decide (x1 ≤ x2)) ∧
                ∀ n ∈ preN, ∀ g, FolderAt env.view f r n g → g ∈ bn.1)) ?_
              fun _ _ h => h) ?_ (fun _ _ h => h) (fun _ h => h)) fun gb => ?_
          · intro n restN bn hsufN
            apply Triple.pre_and
            rintro ⟨j1, j2, j3, preN, hpreN, j4⟩
            have hn : n ∈ env.tree.list r :=
              (List.mergeSort_perm _ _).mem_iff.mp (hpreN ▸ List.mem_append_right _ List.mem_cons_self)
            -- The entries before `n`, with `n` itself, given `n`'s own result.
            have step : ∀ (gs : List Given), (∀ g, FolderAt env.view f r n g → g ∈ gs) → bn.1 ⊆ gs →
                (∀ g ∈ gs, g ∉ bn.1 → g.byDir = false ∧ ∃ f ∈ env.config.mode.folders, FolderEntry env.view f g) →
                ((∀ g ∈ gs, (g.byDir = true ∧ ∃ d ∈ env.config.mode.packages, PkgEntry env.view d g) ∨
                  (g.byDir = false ∧ ∃ f ∈ env.config.mode.folders, FolderEntry env.view f g)) ∧
                (∀ d ∈ env.config.mode.packages, ∀ g, PkgEntry env.view d g → g ∈ gs) ∧
                (∀ f ∈ pre, ∀ g, FolderEntry env.view f g → g ∈ gs) ∧
                ∃ preN, preN ++ restN = (env.tree.list r).mergeSort (fun x1 x2 => decide (x1 ≤ x2)) ∧
                  ∀ n ∈ preN, ∀ g, FolderAt env.view f r n g → g ∈ gs) := by
              intro gs hown hsub hnew
              refine ⟨fun g hg => ?_, fun d hd g hg => hsub (j2 d hd g hg), fun f' hf' g hg => hsub (j3 f' hf' g hg),
                preN ++ [n], by rw [← hpreN]; simp, fun n' hn' g hg => ?_⟩
              · by_cases hgb : g ∈ bn.1
                · exact j1 g hgb
                · exact Or.inr (hnew g hg hgb)
              · rcases List.mem_append.mp hn' with hn' | hn'
                · exact hsub (j4 n' hn' g hg)
                · simp only [List.mem_singleton] at hn'; subst hn'; exact hown g hg
            apply Triple.bind_look
            split
            · rename_i sub hsub
              apply Triple.bind_look
              apply Triple.bind_look
              split
              · rename_i hskip
                refine Triple.pure fun s hs =>
                  ⟨hs, step bn.1 (fun g hg => ?_) (fun _ h => h) (fun g _ h => absurd ‹_› h)⟩
                obtain ⟨sub', m, hsub', hdir, hk, -⟩ := hg
                rw [Env.view_tree, hsub] at hsub'
                cases hsub'
                change env.tree.isDir sub = true at hdir
                change (env.tree.childKind? sub "package.haus").isSome = true at hk
                rw [hdir] at hskip
                cases h : env.tree.childKind? sub "package.haus" <;> simp_all
              · rename_i hkeep
                refine Triple.bind (Triple.tryCatch (R := fun s => At env κ s ∧ manifestV env.view sub = none)
                  (Q := fun p s => At env κ s ∧ ((∀ g ∈ p.2.1, (g.byDir = true ∧ ∃ d ∈ env.config.mode.packages,
                      PkgEntry env.view d g) ∨ (g.byDir = false ∧ ∃ f ∈ env.config.mode.folders, FolderEntry env.view f g)) ∧
                    (∀ d ∈ env.config.mode.packages, ∀ g, PkgEntry env.view d g → g ∈ p.2.1) ∧
                    (∀ f ∈ pre, ∀ g, FolderEntry env.view f g → g ∈ p.2.1) ∧
                    ∃ preN, preN ++ restN = (env.tree.list r).mergeSort (fun x1 x2 => decide (x1 ≤ x2)) ∧
                      ∀ n ∈ preN, ∀ g, FolderAt env.view f r n g → g ∈ p.2.1)) ?_ fun _ => ?_)
                  fun p => Triple.pure fun s hs => hs
                · have hdir : env.tree.isDir sub = true := by
                    cases h : env.tree.isDir sub <;> simp_all
                  have hk : (env.tree.childKind? sub "package.haus").isSome = true := by
                    cases h : env.tree.childKind? sub "package.haus" <;> simp_all
                  refine Triple.bind (Triple.mono (Pure.manifestOf (env := env) (dir := sub)
                    (shown := showPath (f ++ [n])) κ) (fun _ h => h) (fun _ _ h => h) (fun _ h => h))
                    fun mo => Triple.pre_and fun hm => ?_
                  split
                  · rename_i m
                    have hown : FolderAt env.view f r n ⟨sub, showPath (f ++ [n]), m.name, false⟩ :=
                      ⟨sub, m, hsub, hdir, hk, hm, rfl⟩
                    refine Triple.pure fun s hs => ⟨hs, step _ (fun g hg => by rw [hown.unique hg]; simp)
                      (fun _ h => List.mem_append_left _ h) (fun g hg hgb => ?_)⟩
                    rcases List.mem_append.mp hg with hg | hg
                    · exact absurd hg hgb
                    · simp only [List.mem_singleton] at hg
                      subst hg
                      exact ⟨rfl, f, hf, r, n, hr, hn, hown⟩
                  · rename_i hnone
                    refine Triple.pure fun s hs => ⟨hs, step bn.1 (fun g hg => ?_) (fun _ h => h)
                      (fun g _ h => absurd ‹_› h)⟩
                    obtain ⟨sub', m, hsub', -, -, hm', -⟩ := hg
                    rw [Env.view_tree, hsub] at hsub'
                    cases hsub'
                    rw [hm] at hm'
                    cases hm'
                    exact absurd rfl (hnone m)
                · refine Triple.pure fun s hs => ⟨hs.1, step bn.1 (fun g hg => ?_) (fun _ h => h)
                    (fun g _ h => absurd ‹_› h)⟩
                  obtain ⟨sub', m, hsub', -, -, hm', -⟩ := hg
                  rw [Env.view_tree, hsub] at hsub'
                  cases hsub'
                  rw [hs.2] at hm'
                  cases hm'
            · refine Triple.pure fun s hs =>
                  ⟨hs, step bn.1 (fun g hg => ?_) (fun _ h => h) (fun g _ h => absurd ‹_› h)⟩
              obtain ⟨sub', m, hsub', -⟩ := hg
              rename_i hne
              exact absurd hsub' (hne sub')
          · intro s hs
            exact ⟨hs, i1, i2, i3, [], rfl, fun _ h => nomatch h⟩
          · apply Triple.pre_and
            rintro ⟨j1, j2, j3, preN, hpreN, j4⟩
            rw [List.append_nil] at hpreN
            subst hpreN
            refine Triple.pure fun s hs => ⟨hs, j1, j2, pre ++ [f], by rw [← hpre]; simp, fun f' hf' g hg => ?_⟩
            rcases List.mem_append.mp hf' with hf' | hf'
            · exact j3 f' hf' g hg
            · simp only [List.mem_singleton] at hf'
              subst hf'
              obtain ⟨r', n, hr', hn, hat⟩ := hg
              rw [Env.view_tree, hr] at hr'
              cases hr'
              exact j4 n ((List.mergeSort_perm _ _).mem_iff.mpr hn) g hat
        · exact Triple.bind_fail fun _ _ => True.intro
      · exact Triple.bind_fail fun _ _ => True.intro
    · intro s hs
      exact ⟨hs, fun g hg => Or.inl (hsound g hg), hcomp, [], rfl, fun _ h => nomatch h⟩
    · apply Triple.pre_and
      rintro ⟨h1, h2, pre, hpre, h3⟩
      rw [List.append_nil] at hpre
      subst hpre
      exact Triple.pure fun s hs => ⟨hs, ⟨h1, h2, h3⟩⟩

theorem manifestV_congr {V V' : View} (ht : V'.tree = V.tree) (hl : V'.limits = V.limits) (d : Path) :
    manifestV V' d = manifestV V d := by
  unfold manifestV; rw [ht, hl]

theorem PkgEntry.congr {V V' : View} (ht : V'.tree = V.tree) (hl : V'.limits = V.limits) {d : Path} {g : Given}
    (h : PkgEntry V d g) : PkgEntry V' d g := by
  obtain ⟨r, m, h1, h2, h3⟩ := h
  exact ⟨r, m, by rw [ht]; exact h1, by rw [manifestV_congr ht hl]; exact h2, h3⟩

theorem FolderEntry.congr {V V' : View} (ht : V'.tree = V.tree) (hl : V'.limits = V.limits) {f : Path} {g : Given}
    (h : FolderEntry V f g) : FolderEntry V' f g := by
  obtain ⟨r, n, h1, h2, sub, m, h3, h4, h5, h6, h7⟩ := h
  exact ⟨r, n, by rw [ht]; exact h1, by rw [ht]; exact h2, sub, m, by rw [ht]; exact h3, by rw [ht]; exact h4,
    by rw [ht]; exact h5, by rw [manifestV_congr ht hl]; exact h6, h7⟩

/-! ## Two whole runs -/

/-- What a successful run does: it reads the packages given, then loads the root's real path. -/
theorem runIn_load {t : Tree} {c : Config} {root : Path} {w : Walk} {S : St} (h : runIn t c root w = (.ok (), S)) :
    ∃ g b s₁ real r, go givenPackages { tree := t, config := c } {} = (.ok (g, b), s₁) ∧
      t.realPath root = .ok real ∧
      go (load w (c.limits.files + 1) (.file real)) { tree := t, config := c, given := g, broken := b } s₁ =
        (.ok r, S) := by
  unfold runIn main at h
  simp only [go_bind] at h
  rcases hg : go givenPackages { tree := t, config := c } {} with ⟨rg, s₁⟩
  rw [hg] at h
  cases rg with
  | error e => simp at h
  | ok gb =>
    obtain ⟨g, b⟩ := gb
    simp only [go_withReader, go_bind, go_look] at h
    rcases hreal : t.realPath root with e | real
    · simp [hreal, go_bind, go_fail] at h
    simp only [hreal, go_pure, go_bind, go_look] at h
    by_cases hk : (t.kindAt? real != some Kind.file) = true
    · simp [hk, go_bind, go_fail] at h
    simp only [hk, Bool.false_eq_true, ↓reduceIte, go_bind, go_cfg] at h
    rcases hl : go (load w (c.limits.files + 1) (.file real)) { tree := t, config := c, given := g, broken := b } s₁
      with ⟨rl, S'⟩
    rw [hl] at h
    cases rl with
    | error e => simp at h
    | ok r =>
      simp only [go_pure, Prod.mk.injEq] at h
      exact ⟨g, b, s₁, real, r, rfl, rfl, by rw [hl, h.2]⟩

/-- `c'` is `c` with more folders of packages: everything else the same, every folder of `c` one of `c'`. -/
structure MoreFolders (c c' : Config) : Prop where
  npm : c'.mode.npm = c.mode.npm
  packages : c'.mode.packages = c.mode.packages
  folders : ∀ f ∈ c.mode.folders, f ∈ c'.mode.folders
  limits : c'.limits = c.limits
  worldWritable : c'.worldWritable = c.worldWritable
  checkVersions : c'.checkVersions = c.checkVersions

/-- Two successful runs, the second with more folders, make the same packages, with the same versions. -/
theorem runIn_folders {t : Tree} {c c' : Config} {root : Path} {w w' : Walk} (hm : MoreFolders c c')
    (h : (runIn t c root w).1 = .ok ()) (h' : (runIn t c' root w').1 = .ok ()) :
    ClassesIn (runIn t c root w).2 (runIn t c' root w').2 ∧ ClassesIn (runIn t c' root w').2 (runIn t c root w).2 := by
  obtain ⟨g, b, s₁, real, r, hg, hr, hl⟩ := runIn_load (S := (runIn t c root w).2)
    (by rw [← h])
  obtain ⟨g', b', s₁', real', r', hg', hr', hl'⟩ := runIn_load (S := (runIn t c' root w').2)
    (by rw [← h'])
  rw [hr] at hr'; cases hr'
  have gA := givenPackages_ok (env := { tree := t, config := c }) (κ := ({} : St).core) {} ⟨Tr.empty, rfl⟩
  rw [hg] at gA
  obtain ⟨⟨htr, hcore⟩, hok⟩ := gA
  have gB := givenPackages_ok (env := { tree := t, config := c' }) (κ := ({} : St).core) {} ⟨Tr.empty, rfl⟩
  rw [hg'] at gB
  obtain ⟨⟨htr', hcore'⟩, hok'⟩ := gB
  have p1 : ∀ d x, PkgEntry ({ tree := t, config := c } : Env).view d x →
      PkgEntry ({ tree := t, config := c' } : Env).view d x := fun _ _ he => he.congr (by rfl) hm.limits
  have p2 : ∀ d x, PkgEntry ({ tree := t, config := c' } : Env).view d x →
      PkgEntry ({ tree := t, config := c } : Env).view d x := fun _ _ he => he.congr (by rfl) hm.limits.symm
  have f1 : ∀ f x, FolderEntry ({ tree := t, config := c } : Env).view f x →
      FolderEntry ({ tree := t, config := c' } : Env).view f x := fun _ _ he => he.congr (by rfl) hm.limits
  have hw : Wider { tree := t, config := c, given := g, broken := b : Env }.view
      { tree := t, config := c', given := g', broken := b' : Env }.view :=
    { tree := rfl, limits := hm.limits, npm := hm.npm, worldWritable := hm.worldWritable,
      checkVersions := hm.checkVersions,
      given := fun x hx => by
        rcases hok.sound x hx with ⟨-, d, hd, he⟩ | ⟨-, f, hf, he⟩
        · exact hok'.pkgs d (by rw [hm.packages]; exact hd) x (p1 d x he)
        · exact hok'.folders f (hm.folders f hf) x (f1 f x he)
      byDir := fun x hx hb => by
        rcases hok'.sound x hx with ⟨-, d, hd, he⟩ | ⟨hb', -⟩
        · exact hok.pkgs d (by rw [← hm.packages]; exact hd) x (p2 d x he)
        · rw [hb] at hb'; cases hb' }
  exact load_wider hw (Tr.of_view htr rfl rfl) hcore (Tr.of_view htr' rfl rfl) hcore' hl hl'

/--
**Folders are conservative** (R6, security review F2): two successful runs,
the second with more folders of packages and everything else the same,
give the same packages, whatever order each walks the imports in.
-/
theorem resolveIn_folders {t : Tree} {c c' : Config} {root : Path} {w w' : Walk} {ps ps' : List String}
    (hm : MoreFolders c c') (h : (resolveIn t c root w).result = .ok ps)
    (h' : (resolveIn t c' root w').result = .ok ps') : ps' = ps := by
  obtain ⟨h1, rfl⟩ := runIn_ok_of h
  obtain ⟨h2, rfl⟩ := runIn_ok_of h'
  obtain ⟨h12, h21⟩ := runIn_folders hm h1 h2
  exact packagesOf_eq (runIn t c' root w').2.classes.distinct (runIn t c root w).2.classes.distinct h21 h12

/-- The settings `c` with the folders of packages `fs` added. -/
def Config.addFolders (c : Config) (fs : List Path) : Config :=
  { c with mode := { c.mode with folders := c.mode.folders ++ fs } }

theorem moreFolders_add (c : Config) (fs : List Path) : MoreFolders c (c.addFolders fs) :=
  ⟨rfl, rfl, fun _ h => List.mem_append_left _ h, rfl, rfl, rfl⟩

/--
**Adding folders never changes a successful result** (R6, F2): with the
folders `fs` added, a run that succeeded gives the same packages, or an error.
-/
theorem resolveIn_addFolders {t : Tree} {c : Config} {root : Path} {w : Walk} {ps : List String} (fs : List Path)
    (h : (resolveIn t c root w).result = .ok ps) :
    (resolveIn t (c.addFolders fs) root w).result = .ok ps ∨
      ∃ e, (resolveIn t (c.addFolders fs) root w).result = .error e := by
  cases h' : (resolveIn t (c.addFolders fs) root w).result with
  | error e => exact Or.inr ⟨e, rfl⟩
  | ok ps' => exact Or.inl (congrArg _ (resolveIn_folders (moreFolders_add c fs) h h'))

end Haus.Packages
