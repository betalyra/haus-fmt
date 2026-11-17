import Haus.Packages.Reads

/-!
# Name isolation (R5, P6, security review F1)

Resolving `@org/name` from an importer looks only at:

- the packages given explicitly with that name (`candidates_from`);
- the importer's declarations: its `package.json` (`declared`, R7);
- with `npm`, the places of `walk`: `D/node_modules/@org/name` for the
  directories `D` from the importer's directory up, except those `skipped`
  keeps out (named `node_modules`, a scope directory directly inside one,
  one everyone may write to): `walk_mem`. Of each place it uses only its
  real path and whether that has a `package.haus` (`npmLookup_eq`,
  `npmFind_congr`): two trees that agree on these find the same package.
  It reads no file and changes nothing of the run's state.

Node's own walk (`nodeWalk`) also tries `D/node_modules` for a scope
directory `D` (`node_modules/@acme/node_modules`), where a dependency can
place a package of another scope (F1): `nodeWalk_finds_planted`.
-/

namespace Haus.Packages

/-- What the walk finds among the places `ps`, nearest first (as `npmLookup`). -/
def npmFind (t : Tree) (name : String) : List Path → Except Err (Option Path)
  | [] => .ok none
  | p :: ps =>
    match t.realPath p with
    | .ok real =>
      if (t.childKind? real "package.haus").isSome then .ok (some real)
      else .error ⟨.importNotFound, s!"{name}: {showPath p} has no package.haus (not a schema package); the search stops there"⟩
    | .error _ => npmFind t name ps

/-- The npm walk is `npmFind` on `walk`: it reads no file and changes nothing of the state. -/
theorem npmLookup_eq (env : Env) (s : St) (start : Path) (name : String) :
    go (npmLookup start name) env s = (npmFind env.tree name (walk env.config.worldWritable start name), s) := by
  unfold npmLookup
  simp only [go_bind, go_cfg]
  generalize walk env.config.worldWritable start name = ps
  induction ps with
  | nil => simp [npmFind]
  | cons p ps ih =>
    rw [List.forIn_cons]
    simp only [go_bind, go_look, npmFind]
    rcases hr : env.tree.realPath p with f | real
    · simpa [go_bind] using ih
    · by_cases hk : (env.tree.childKind? real "package.haus").isSome
      · simp [hk, go_bind]
      · simp [hk, go_bind, go_map]

/-- What the walk finds depends only on the real path of each place and whether that has a `package.haus`. -/
theorem npmFind_congr {t t' : Tree} {name : String} {ps : List Path}
    (h : ∀ p ∈ ps, t.realPath p = t'.realPath p ∧
      ∀ r, t.realPath p = .ok r → (t.childKind? r "package.haus").isSome = (t'.childKind? r "package.haus").isSome) :
    npmFind t name ps = npmFind t' name ps := by
  induction ps with
  | nil => rfl
  | cons p ps ih =>
    obtain ⟨h1, h2⟩ := h p List.mem_cons_self
    simp only [npmFind, ← h1]
    split
    · rename_i r hr; rw [h2 r hr]
    · exact ih fun q hq => h q (List.mem_cons_of_mem _ hq)

/--
**Name isolation** (R5): the npm walk for `name` from `start` gives the same
on two trees that agree on the real paths of the places of `walk`, and on
whether those have a `package.haus`; it reads no file.
-/
theorem npmLookup_isolated {env env' : Env} {s : St} {start : Path} {name : String}
    (hc : env'.config.worldWritable = env.config.worldWritable)
    (h : ∀ p ∈ walk env.config.worldWritable start name, env.tree.realPath p = env'.tree.realPath p ∧
      ∀ r, env.tree.realPath p = .ok r →
        (env.tree.childKind? r "package.haus").isSome = (env'.tree.childKind? r "package.haus").isSome) :
    go (npmLookup start name) env' s = go (npmLookup start name) env s := by
  rw [npmLookup_eq, npmLookup_eq, hc, npmFind_congr h]

theorem mem_ancestors {d p : Path} : d ∈ ancestors p ↔ ∃ k ≤ p.length, d = p.take k := by
  simp only [ancestors, List.mem_map, List.mem_reverse, List.mem_range]
  constructor
  · rintro ⟨k, hk, rfl⟩; exact ⟨k, by omega, rfl⟩
  · rintro ⟨k, hk, rfl⟩; exact ⟨k, by omega, rfl⟩

/--
The places the walk tries (R5, P6): `D/node_modules/@org/name` for a
directory `D` that is `start` or above it, not named `node_modules`, not a
scope directory directly in a `node_modules` (F1), and not one everyone may
write to.
-/
theorem walk_mem {ww : Path → Bool} {start p : Path} {name : String} (h : p ∈ walk ww start name) :
    ∃ d, d <+: start ∧ p = d ++ "node_modules" :: splitPath name ∧
      d.getLast? ≠ some "node_modules" ∧
      ¬(d.dropLast.getLast? = some "node_modules" ∧ (d.getLast?.any (·.startsWith "@")) = true) ∧
      ww d = false := by
  simp only [walk, List.mem_map, List.mem_filter] at h
  obtain ⟨d, ⟨hd, hs⟩, rfl⟩ := h
  obtain ⟨k, -, rfl⟩ := mem_ancestors.mp hd
  refine ⟨_, List.take_prefix _ _, rfl, ?_, ?_, ?_⟩
  · intro e; simp [skipped, e] at hs
  · rintro ⟨e1, e2⟩; simp [skipped, e1, e2] at hs
  · cases hw : ww (List.take k start)
    · rfl
    · simp [skipped, hw] at hs

/-- The walk never tries a `node_modules` in a scope directory (F1). -/
theorem walk_skips_scope {ww : Path → Bool} {start : Path} {name : String} (pre : Path) (scope : String)
    (hs : scope.startsWith "@" = true) :
    pre ++ ["node_modules", scope] ++ "node_modules" :: splitPath name ∉ walk ww start name := by
  intro h
  obtain ⟨d, -, he, -, hscope, -⟩ := walk_mem h
  have : d = pre ++ ["node_modules", scope] := (List.append_cancel_right he).symm
  subst this
  apply hscope
  simp [hs]

/--
Node's walk (`require.resolve.paths`): `D/node_modules/@org/name` for every
directory `D` from `start` up that is not itself named `node_modules`.
-/
def nodeWalk (start : Path) (name : String) : List Path :=
  ((ancestors start).filter fun d => d.getLast? != some "node_modules").map (· ++ "node_modules" :: splitPath name)

/-- Node's walk tries the `node_modules` of a scope directory above any file in that scope (F1). -/
theorem nodeWalk_scope (pre rest : Path) (scope name : String) (hs : scope.startsWith "@" = true) :
    pre ++ ["node_modules", scope] ++ "node_modules" :: splitPath name ∈
      nodeWalk (pre ++ ["node_modules", scope] ++ rest) name := by
  simp only [nodeWalk, List.mem_map, List.mem_filter]
  refine ⟨pre ++ ["node_modules", scope], ⟨mem_ancestors.mpr ⟨(pre ++ ["node_modules", scope]).length, by simp,
    by rw [List.take_left' rfl]⟩, ?_⟩, rfl⟩
  have : scope ≠ "node_modules" := by rintro rfl; simp at hs
  simp [this]

theorem Triple.pre_const {α} {env : Env} {A : Prop} {x : M α} {Q : α → St → Prop} {E : St → Prop}
    (h : A → Triple env (fun _ => True) x Q E) : Triple env (fun _ => A) x Q E :=
  fun s hs => h hs s True.intro

/-- Where the npm walk starts for an importer: its file's directory, or its package's. -/
def Importer.dir : Importer → Path
  | .app p => p.dropLast
  | .pkg dir _ _ => dir

/-- No package with this name is given by its directory. -/
def NoneByDir (env : Env) (name : String) : Prop := ∀ g ∈ env.given, g.byDir = true → g.name ≠ name

theorem npmLookup_value {env : Env} {start : Path} {name : String} :
    Triple env (fun _ => True) (npmLookup start name)
      (fun r _ => npmFind env.tree name (walk env.config.worldWritable start name) = .ok r) (fun _ => True) := by
  intro s _
  rw [npmLookup_eq]
  cases npmFind env.tree name (walk env.config.worldWritable start name) <;> trivial

/--
**Where a package is found** (R5, §13.3 "Resolution"): every candidate for
`name` is a package given explicitly with that name (by its directory, or in
a folder when none is given by its directory), or, with `npm` and none given
by its directory, what the walk from the importer finds.
-/
theorem candidates_from {env : Env} {imp : Importer} {name : String} :
    Triple env (fun _ => True) (candidates imp name)
      (fun ds _ => ∀ d ∈ ds,
        (∃ g ∈ env.given, g.name = name ∧ g.dir = d.1 ∧ (g.byDir = true ∨ NoneByDir env name)) ∨
        (NoneByDir env name ∧ env.config.mode.npm = true ∧
          npmFind env.tree name (walk env.config.worldWritable imp.dir name) = .ok (some d.1)))
      (fun _ => True) := by
  unfold candidates
  refine Triple.bind_modify (fun _ => True) (fun _ _ => True.intro) ?_
  apply Triple.bind_ask
  dsimp only
  split
  · rename_i hne
    refine Triple.pure fun _ _ d hd => Or.inl ?_
    simp only [List.mem_map, List.mem_filter, Bool.and_eq_true, beq_iff_eq] at hd
    obtain ⟨g, ⟨hg, hb, hn⟩, rfl⟩ := hd
    exact ⟨g, hg, hn, rfl, Or.inl hb⟩
  rename_i hempty
  have hnone : NoneByDir env name := by
    intro g hg hb hn
    have he : (env.given.filter fun g => g.byDir && g.name == name).isEmpty = true := by simpa using hempty
    have : g ∈ env.given.filter fun g => g.byDir && g.name == name := List.mem_filter.mpr ⟨hg, by simp [hb, hn]⟩
    rw [List.isEmpty_iff.mp he] at this
    simp at this
  have hfold : ∀ d ∈ (env.given.filter fun g => !g.byDir && g.name == name).map fun g => (g.dir, g.shown),
      ∃ g ∈ env.given, g.name = name ∧ g.dir = d.1 ∧ (g.byDir = true ∨ NoneByDir env name) := by
    intro d hd
    simp only [List.mem_map, List.mem_filter, Bool.and_eq_true, beq_iff_eq] at hd
    obtain ⟨g, ⟨hg, -, hn⟩, rfl⟩ := hd
    exact ⟨g, hg, hn, rfl, Or.inr hnone⟩
  apply Triple.bind_cfg
  have tail : ∀ (fromNpm : List (Path × String)), (∀ d ∈ fromNpm, env.config.mode.npm = true ∧
      npmFind env.tree name (walk env.config.worldWritable imp.dir name) = .ok (some d.1)) →
      ∀ (all : List (Path × String)), all = (env.given.filter fun g => !g.byDir && g.name == name).map
        (fun g => (g.dir, g.shown)) ++ fromNpm.filter (fun x => !((env.given.filter fun g => !g.byDir && g.name == name).map
        (fun g => (g.dir, g.shown))).any fun y => y.1 == x.1) →
      ∀ d ∈ all, (∃ g ∈ env.given, g.name = name ∧ g.dir = d.1 ∧ (g.byDir = true ∨ NoneByDir env name)) ∨
        (NoneByDir env name ∧ env.config.mode.npm = true ∧
          npmFind env.tree name (walk env.config.worldWritable imp.dir name) = .ok (some d.1)) := by
    intro fromNpm hf all hall d hd
    subst hall
    rcases List.mem_append.mp hd with hd | hd
    · exact Or.inl (hfold d hd)
    · exact Or.inr ⟨hnone, hf d (List.mem_filter.mp hd).1⟩
  split
  · apply Triple.bind_pure
    try dsimp only
    split
    · apply Triple.bind_ask
      exact Triple.bind_fail fun _ _ => True.intro
    · exact Triple.pure fun _ _ => tail [] (fun _ h => absurd h List.not_mem_nil) _ rfl
  · rename_i hnpm
    refine Triple.bind Triple.trivial fun r => ?_
    split
    · refine Triple.bind (Triple.mono npmLookup_value (fun _ _ => True.intro) (fun _ _ h => h) (fun _ h => h))
        fun found => ?_
      apply Triple.pre_const; intro hf
      apply Triple.bind_pure
      have hfrom : ∀ d ∈ found.toList.map (fun d => (d, showPath d)), env.config.mode.npm = true ∧
          npmFind env.tree name (walk env.config.worldWritable imp.dir name) = .ok (some d.1) := by
        intro d hd
        simp only [List.mem_map, Option.mem_toList] at hd
        obtain ⟨d', hd', rfl⟩ := hd
        refine ⟨by simpa using hnpm, ?_⟩
        subst hd'
        cases imp <;> exact hf
      split
      · apply Triple.bind_ask
        exact Triple.bind_fail fun _ _ => True.intro
      · exact Triple.pure fun _ _ => tail _ hfrom _ rfl
    · split
      · exact Triple.bind_fail fun _ _ => True.intro
      · apply Triple.bind_pure
        try dsimp only
        split
        · apply Triple.bind_ask
          exact Triple.bind_fail fun _ _ => True.intro
        · exact Triple.pure fun _ _ => tail [] (fun _ h => absurd h List.not_mem_nil) _ rfl

section Example

/-- The tree of F1: an honest `@acme/common`, and one planted in `node_modules/@acme/node_modules`. -/
private def f1 : Tree := ⟨[
  (["app"], .dir), (["app", "node_modules"], .dir), (["app", "node_modules", "@acme"], .dir),
  (["app", "node_modules", "@acme", "orders"], .dir),
  (["app", "node_modules", "@acme", "orders", "package.haus"], .file []),
  (["app", "node_modules", "@acme", "common"], .dir),
  (["app", "node_modules", "@acme", "common", "package.haus"], .file []),
  (["app", "node_modules", "@acme", "node_modules"], .dir),
  (["app", "node_modules", "@acme", "node_modules", "@acme"], .dir),
  (["app", "node_modules", "@acme", "node_modules", "@acme", "common"], .dir),
  (["app", "node_modules", "@acme", "node_modules", "@acme", "common", "package.haus"], .file [])]⟩

private def found : Except Err (Option Path) → Option Path
  | .ok r => r
  | .error _ => none

-- From `@acme/orders`, Node's walk finds the planted package; the walk of §13.3 the honest one.
#guard found (npmFind f1 "@acme/common" (nodeWalk ["app", "node_modules", "@acme", "orders"] "@acme/common")) ==
  some ["app", "node_modules", "@acme", "node_modules", "@acme", "common"]
#guard found (npmFind f1 "@acme/common" (walk (fun _ => false) ["app", "node_modules", "@acme", "orders"] "@acme/common")) ==
  some ["app", "node_modules", "@acme", "common"]

end Example

end Haus.Packages
