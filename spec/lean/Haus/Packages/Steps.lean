import Haus.Packages.Isolation

/-!
# The resolver's steps as functions of the tree (a step of R3)

Every step of the resolver but `load`, `classify` and `countFile` returns a
value that depends only on the tree and the run's settings without the walk
order (`View`), whatever state it starts from, as long as its caches tell
the truth (`Tr`): `Pure env x v`, `x` returns `a` exactly when `v = some a`,
and fails exactly when `v = none`, keeping the caches truthful and leaving
the files, copies, classes, count and the targets finished (`Core`) alone.
The caches (`St.manifests`, `St.npm`) hold what reading the file again
would give, so a hit and a miss return the same.

So two runs that walk the imports in different orders see the same at each
step, which is what the proofs of R3 (`Haus.Packages.Walk`) build on.
-/

namespace Haus.Packages

/-- The run's settings without the walk order: all that the steps other than `load` see. -/
structure View where
  tree : Tree
  mode : Mode
  limits : Limits
  worldWritable : Path → Bool
  checkVersions : Bool
  given : List Given
  broken : List String

def Env.view (e : Env) : View :=
  ⟨e.tree, e.config.mode, e.config.limits, e.config.worldWritable, e.config.checkVersions, e.given, e.broken⟩

section
variable (e : Env)
theorem Env.view_tree : e.view.tree = e.tree := rfl
theorem Env.view_mode : e.view.mode = e.config.mode := rfl
theorem Env.view_limits : e.view.limits = e.config.limits := rfl
theorem Env.view_worldWritable : e.view.worldWritable = e.config.worldWritable := rfl
theorem Env.view_checkVersions : e.view.checkVersions = e.config.checkVersions := rfl
theorem Env.view_given : e.view.given = e.given := rfl
theorem Env.view_broken : e.view.broken = e.broken := rfl
end

/-- Rewrites the parts of `env.view` to those of `env`. -/
macro "view" : tactic => `(tactic| simp only [Env.view_tree, Env.view_mode, Env.view_limits,
  Env.view_worldWritable, Env.view_checkVersions, Env.view_given, Env.view_broken])

/-! ## The values -/

/-- What `openFile p limit` reads: the bytes of a regular file within the limit. -/
def fileBytes (t : Tree) (p : Path) (limit : Nat) : Option (List UInt8) :=
  match t.at? p with
  | some (.file bs) => if bs.length > limit then none else some bs
  | _ => none

/-- What `openPackageFile dir name limit` gives: `some none` if there is no such entry. -/
def pkgFile (t : Tree) (dir : Path) (name : String) (limit : Nat) : Option (Option (List UInt8)) :=
  match t.childKind? dir name with
  | none => some none
  | some .file => (fileBytes t (dir ++ [name]) limit).map some
  | some _ => none

def parseManifest? (bytes : List UInt8) : Option Manifest :=
  match parseManifest bytes "" with
  | .ok m => some m
  | .error _ => none

/-- What `manifestOf dir` gives. -/
def manifestV (V : View) (dir : Path) : Option (Option Manifest) :=
  (pkgFile V.tree dir "package.haus" V.limits.manifest).bind fun
    | none => some none
    | some bytes => (parseManifest? bytes).map some

/-- What `packageJsonOf dir` gives. -/
def packageJsonV (V : View) (dir : Path) : Option (Option NpmInfo) :=
  (pkgFile V.tree dir "package.json" V.limits.packageJson).map fun
    | none => none
    | some bytes => parseNpm bytes

/-- What the body of `projectOf`'s loop gives for the directory `d`. -/
def projectStep (V : View) (d : Path) :
    Option (ForInStep (Option (Option (Path × Option (List String))) × Unit)) :=
  if (V.tree.childKind? d "package.json").isNone then some (.yield (none, ())) else
  match V.tree.realPath (d ++ ["package.json"]) with
  | .ok real =>
    if (V.tree.kindAt? real != some .file) = true then some (.done (some (some (d, none)), ())) else
    (fileBytes V.tree real V.limits.packageJson).bind fun bytes =>
      match parseNpm bytes with
      | none => some (.done (some (some (d, none)), ()))
      | some i => if i.project = true then some (.done (some (some (d, some (i.deps ++ i.dev))), ()))
        else some (.yield (none, ()))
  | .error _ => some (.done (some (some (d, none)), ()))

/-- A `for` loop's value, from the values of its body. -/
def forInV {γ β : Type} (fv : γ → β → Option (ForInStep β)) : List γ → β → Option β
  | [], b => some b
  | a :: as, b => (fv a b).bind fun
    | .done b' => some b'
    | .yield b' => forInV fv as b'

/-- What `projectOf p` gives. -/
def projectV (V : View) (p : Path) : Option (Option (Path × Option (List String))) :=
  (forInV (fun d _ => projectStep V d) (ancestors p.dropLast) (none, ())).map fun r =>
    match r.1 with
    | some r => r
    | none => none

/-- What `declared importer` gives. -/
def declaredV (V : View) : Importer → Option (List String × String)
  | .pkg _ _ (some i) => some (i.deps, "its package.json doesn't declare it")
  | .pkg _ _ none => some ([], "it has no package.json, so it declares nothing")
  | .app p => (projectV V p).map fun
    | some (d, some names) => (names, s!"{showPath (d ++ ["package.json"])} doesn't declare it")
    | some (d, none) => ([], s!"{showPath (d ++ ["package.json"])} can't be read as JSON, so it declares nothing")
    | none => ([], "there is no package.json above it, so it declares nothing")

/-- What `candidates importer name` gives. -/
def candV (V : View) (importer : Importer) (name : String) : Option (List (Path × String)) :=
  let byDir := V.given.filter fun g => g.byDir && g.name == name
  if (!byDir.isEmpty) = true then some (byDir.map fun g => (g.dir, g.shown)) else
  let inFolders := (V.given.filter fun g => !g.byDir && g.name == name).map fun g => (g.dir, g.shown)
  let fromNpm : Option (List (Path × String)) :=
    if (!V.mode.npm) = true then some [] else
    (declaredV V importer).bind fun (decl, _) =>
      if name ∈ decl then
        (npmFind V.tree name (walk V.worldWritable importer.dir name)).toOption.map fun r => r.toList.map fun d => (d, showPath d)
      else if inFolders.isEmpty = true then none else some []
  fromNpm.bind fun fromNpm =>
    let all := inFolders ++ fromNpm.filter fun (d, _) => !inFolders.any (·.1 == d)
    if all.isEmpty = true then none else some all

/-- What `decodeScan bytes` gives. -/
def decodeV (bytes : List UInt8) : Option Scanned :=
  (utf8 bytes).bind fun t =>
    match scan t with
    | .ok s => some s
    | .error _ => none

/-- Whether `checkNames imp types` passes. -/
def namesOk (imp : Import) (types : List String) : Prop := ∀ n ∈ imp.names, n ∈ types

instance (imp : Import) (types : List String) : Decidable (namesOk imp types) :=
  inferInstanceAs (Decidable (∀ n ∈ imp.names, n ∈ types))

/-! ## Truthful caches, and the core of a state -/

/-- The caches hold what reading the file again would give. -/
structure Tr (V : View) (s : St) : Prop where
  manifests : ∀ d m, (d, m) ∈ s.manifests → manifestV V d = some (some m)
  npm : ∀ p r, (p, r) ∈ s.npm → ∃ bs, fileBytes V.tree p V.limits.packageJson = some bs ∧ parseNpm bs = r

/-- What the steps other than `load`, `classify` and `countFile` leave alone. -/
structure Core where
  files : List (Path × Option (List String))
  copies : List (Path × Loading)
  classes : Classes
  count : Nat
  finished : List Target

def St.core (s : St) : Core := ⟨s.files, s.copies, s.classes, s.count, s.finished⟩

theorem Tr.empty {V : View} : Tr V ({} : St) := ⟨by simp, by simp⟩

/--
`x` returns `a` exactly when `v = some a`, and fails exactly when
`v = none`, from every state with truthful caches, keeping them truthful
and the core of the state as it was (also when it fails).
-/
def Pure {α} (env : Env) (x : M α) (v : Option α) : Prop :=
  ∀ κ, Triple env (fun s => Tr env.view s ∧ s.core = κ) x (fun r s => (Tr env.view s ∧ s.core = κ) ∧ v = some r)
    (fun s => (Tr env.view s ∧ s.core = κ) ∧ v = none)

namespace Pure
variable {α β γ δ : Type} {env : Env}

theorem ret {a : α} : Pure env (Pure.pure a : M α) (some a) := fun _ => Triple.pure fun _ h => ⟨h, rfl⟩

theorem bind {x : M α} {f : α → M β} {v : Option α} {w : α → Option β}
    (hx : Pure env x v) (hf : ∀ a, v = some a → Pure env (f a) (w a)) : Pure env (x >>= f) (v.bind w) := by
  intro κ s hs
  rw [go_bind]
  have := hx κ s hs
  revert this
  rcases go x env s with ⟨r, s'⟩
  cases r with
  | error e => intro ⟨h1, h2⟩; subst h2; exact ⟨h1, rfl⟩
  | ok a => intro ⟨h1, h2⟩; subst h2; exact hf a rfl κ s' h1

theorem ite {c : Prop} [Decidable c] {x y : M α} {v : Option α} (h1 : c → Pure env x v) (h2 : ¬c → Pure env y v) :
    Pure env (if c then x else y) v := by
  split
  · exact h1 ‹_›
  · exact h2 ‹_›

theorem ite2 {c : Prop} [Decidable c] {x y : M α} {v w : Option α} (h1 : c → Pure env x v)
    (h2 : ¬c → Pure env y w) : Pure env (if c then x else y) (if c then v else w) := by
  split
  · exact h1 ‹_›
  · exact h2 ‹_›

theorem ite2bind {c : Prop} [Decidable c] {x y : M α} {v w : Option β} {f : β → Option α}
    (h1 : c → Pure env x (v.bind f)) (h2 : ¬c → Pure env y (w.bind f)) :
    Pure env (if c then x else y) ((if c then v else w).bind f) := by
  split
  · exact h1 ‹_›
  · exact h2 ‹_›

theorem congr {x : M α} {v w : Option α} (h : Pure env x v) (e : v = w) : Pure env x w := e ▸ h

theorem fail {c : Code} {m : String} : Pure env (Haus.Packages.fail c m : M α) none :=
  fun _ => Triple.fail fun _ h => ⟨h, rfl⟩

theorem throw {e : Err} : Pure env (MonadExcept.throw e : M α) none := fun _ => Triple.throw fun _ h => ⟨h, rfl⟩

theorem bind_look {g : Tree → δ} {f : δ → M β} {w : Option β} (h : Pure env (f (g env.tree)) w) :
    Pure env (look g >>= f) w := fun κ => Triple.bind_look (h κ)

theorem bind_cfg {f : Config → M β} {w : Option β} (h : Pure env (f env.config) w) : Pure env (cfg >>= f) w :=
  fun κ => Triple.bind_cfg (h κ)

theorem bind_ask {g : Env → δ} {f : δ → M β} {w : Option β} (h : Pure env (f (g env)) w) :
    Pure env (ask g >>= f) w := fun κ => Triple.bind_ask (h κ)

theorem bind_get {f : St → M β} {w : Option β} (h : ∀ s, Tr env.view s → Pure env (f s) w) :
    Pure env (get >>= f) w := by
  intro κ s hs; rw [go_bind]; exact h s hs.1 κ s hs

theorem bind_modify {g : St → St} {f : Unit → M β} {w : Option β}
    (hg : ∀ s, Tr env.view s → Tr env.view (g s) ∧ (g s).core = s.core) (h : Pure env (f ()) w) :
    Pure env (modify g >>= f) w := by
  intro κ s hs; rw [go_bind]
  obtain ⟨h1, h2⟩ := hg s hs.1
  exact h κ (g s) ⟨h1, h2.trans hs.2⟩

theorem bind_pure {a : α} {f : α → M β} {w : Option β} (h : Pure env (f a) w) : Pure env (Pure.pure a >>= f) w := by
  intro κ s hs; rw [go_bind]; exact h κ s hs

theorem bind_throw' {e : Err} {f : α → M β} : Pure env (MonadExcept.throw e >>= f) none := by
  intro κ s hs; rw [go_bind]; exact ⟨hs, rfl⟩

theorem bind_fail {c : Code} {m : String} {f : α → M β} : Pure env (Haus.Packages.fail c m >>= f) none := by
  intro κ s hs; rw [go_bind]; exact ⟨hs, rfl⟩

theorem forIn {xs : List γ} {b : β} {f : γ → β → M (ForInStep β)} {fv : γ → β → Option (ForInStep β)}
    (h : ∀ a b, Pure env (f a b) (fv a b)) : Pure env (ForIn.forIn xs b f) (forInV fv xs b) := by
  induction xs generalizing b with
  | nil => rw [List.forIn_nil]; exact ret
  | cons a as ih =>
    rw [List.forIn_cons]
    refine bind (h a b) fun r _ => ?_
    cases r with
    | done b' => exact ret
    | yield b' => exact ih

/-- A pure step in a proof about a predicate of the core. -/
theorem triple {x : M α} {v : Option α} {I : Core → Prop} (h : Pure env x v) :
    Triple env (fun s => Tr env.view s ∧ I s.core) x (fun r s => (Tr env.view s ∧ I s.core) ∧ v = some r)
      (fun s => (Tr env.view s ∧ I s.core) ∧ v = none) := by
  intro s hs
  have := h s.core s ⟨hs.1, rfl⟩
  revert this
  rcases go x env s with ⟨r, s'⟩
  cases r with
  | error e => intro ⟨⟨h1, h2⟩, h3⟩; exact ⟨⟨h1, h2 ▸ hs.2⟩, h3⟩
  | ok a => intro ⟨⟨h1, h2⟩, h3⟩; exact ⟨⟨h1, h2 ▸ hs.2⟩, h3⟩

end Pure

/-! ## Each step -/

section
variable {env : Env}

theorem Tree.at?_append (t : Tree) (d : Path) (n : String) : t.at? (d ++ [n]) = t.child? d n := by
  simp [Tree.at?]

theorem Pure.openFile {p : Path} {limit : Nat} {tl : Nat → Err} :
    Pure env (openFile p limit tl) (fileBytes env.tree p limit) := by
  intro κ
  unfold Haus.Packages.openFile
  apply Triple.bind_read
  split
  · rename_i bs heq
    have hv : fileBytes env.tree p limit = if bs.length > limit then none else some bs := by simp [fileBytes, heq]
    rw [hv]
    apply Triple.bind_get'
    intro s₀ _
    have last : Triple env (fun s => Tr env.view s ∧ s.core = κ)
        (if bs.length > limit then (MonadExcept.throw (tl bs.length) : M Unit) >>= fun _ => pure bs else pure bs)
        (fun r s => (Tr env.view s ∧ s.core = κ) ∧ (if bs.length > limit then none else some bs) = some r)
        (fun s => (Tr env.view s ∧ s.core = κ) ∧ (if bs.length > limit then none else some bs) = none) := by
      split
      · rename_i hgt
        exact Triple.bind_throw fun _ h => ⟨h, by simp⟩
      · rename_i hgt
        exact Triple.pure fun _ h => ⟨h, by simp⟩
    dsimp only
    split
    · exact Triple.bind_modify _ (fun s h => ⟨⟨h.1.manifests, h.1.npm⟩, h.2⟩) last
    · exact last
  · rename_i hne
    exact Triple.fail fun _ hs => ⟨hs, by
      unfold fileBytes; split
      · rename_i bs h; exact absurd h (hne bs)
      · rfl⟩

theorem Pure.openPackageFile {dir : Path} {name : String} {limit : Nat} {code : Code} {owner : String} :
    Pure env (openPackageFile dir name limit code owner) (pkgFile env.tree dir name limit) := by
  unfold Haus.Packages.openPackageFile pkgFile
  apply Pure.bind_look
  rcases h : env.tree.childKind? dir name with _ | ⟨_ | _ | _ | _⟩ <;> dsimp only <;> first
    | exact Pure.ret
    | exact Pure.fail
    | exact Pure.congr (Pure.bind Pure.openFile fun _ _ => Pure.ret) (by cases fileBytes env.tree (dir ++ [name]) limit <;> rfl)

theorem parseManifest?_eq (bytes : List UInt8) (owner : String) :
    parseManifest? bytes = match parseManifest bytes owner with
      | .ok m => some m
      | .error _ => none := by
  unfold parseManifest? parseManifest
  rcases utf8 bytes with _ | t
  · rfl
  try dsimp only
  rcases Parser.parse {} t with e | vs
  · rfl
  try dsimp only
  rcases vs with _ | ⟨v, _ | ⟨w, rest⟩⟩
  · rfl
  · cases v <;> try rfl
    rename_i fs
    try dsimp only
    generalize List.lookup "name" fs = a
    generalize List.lookup "version" fs = b
    rcases a with _ | x <;> rcases b with _ | y <;> try rfl
    · cases x <;> rfl
    · cases x <;> cases y <;> try rfl
      rename_i n v
      by_cases h1 : isPackageName n <;> by_cases h2 : isSemver v <;> simp [h1, h2]
  · cases v <;> rfl

theorem Pure.manifestOf {dir : Path} {shown : String} : Pure env (manifestOf dir shown) (manifestV env.view dir) := by
  unfold Haus.Packages.manifestOf
  apply Pure.bind_get
  intro s htr
  split
  · rename_i m hm
    exact Pure.congr Pure.ret (htr.manifests dir m (lookup_mem hm)).symm
  · apply Pure.bind_cfg
    unfold manifestV
    refine Pure.bind Pure.openPackageFile fun r hr => ?_
    cases r with
    | none => exact Pure.ret
    | some bytes =>
      dsimp only
      rw [parseManifest?_eq bytes shown]
      cases hpm : parseManifest bytes shown with
      | error e => exact Pure.bind_throw' 
      | ok m =>
        refine Pure.bind_pure (Pure.bind_modify (fun s h => ⟨⟨fun d m' hd => ?_, h.npm⟩, rfl⟩) Pure.ret)
        rcases List.mem_cons.mp hd with e | hd
        · cases e
          simp [manifestV, hr, parseManifest?_eq bytes shown, hpm]
        · exact h.manifests d m' hd

theorem pkgFile_of_fileBytes {t : Tree} {d : Path} {n : String} {limit : Nat} {bs : List UInt8}
    (h : fileBytes t (d ++ [n]) limit = some bs) : pkgFile t d n limit = some (some bs) := by
  unfold fileBytes at h
  rw [Tree.at?_append] at h
  unfold pkgFile Tree.childKind?
  split at h
  · rename_i bs' he
    rw [he]
    simp only [Option.map_some, Entry.kind]
    unfold fileBytes
    rw [Tree.at?_append, he]
    simp only at h ⊢
    rw [h]; rfl
  · simp at h

theorem Pure.packageJsonOf {dir : Path} {owner : String} :
    Pure env (packageJsonOf dir owner) (packageJsonV env.view dir) := by
  unfold Haus.Packages.packageJsonOf
  apply Pure.bind_get
  intro s htr
  split
  · rename_i r hr
    obtain ⟨bs, hb, hp⟩ := htr.npm _ r (lookup_mem hr)
    refine Pure.congr Pure.ret ?_
    unfold packageJsonV
    rw [pkgFile_of_fileBytes hb]
    simp [hp]
  · apply Pure.bind_cfg
    unfold packageJsonV
    rw [Option.map_eq_bind]
    refine Pure.bind Pure.openPackageFile fun r hr => ?_
    cases r with
    | none => exact Pure.ret
    | some bytes =>
      dsimp only
      refine Pure.bind_modify (fun s h => ⟨⟨h.manifests, fun p r hp => ?_⟩, rfl⟩) Pure.ret
      rcases List.mem_cons.mp hp with e | hp
      · cases e
        refine ⟨bytes, ?_, rfl⟩
        unfold pkgFile at hr
        unfold fileBytes Tree.childKind? at *
        rw [Tree.at?_append]
        split at hr
        · simp at hr
        · rename_i hk
          simp only [Option.map_eq_some_iff] at hk
          obtain ⟨e, he, _⟩ := hk
          rw [he]
          rw [Tree.at?_append, he] at hr
          revert hr
          cases e <;> simp_all
          intro h1 h2; subst h2; exact h1
        · simp at hr
      · exact h.npm p r hp

theorem Pure.projectOf {p : Path} : Pure env (projectOf p) (projectV env.view p) := by
  unfold Haus.Packages.projectOf projectV
  simp only [Env.view]
  apply Pure.bind_cfg
  try dsimp only
  rw [Option.map_eq_bind]
  refine Pure.bind (Pure.forIn fun d _ => ?_) fun r _ => ?_
  · unfold projectStep
    apply Pure.bind_look
    try dsimp only
    by_cases h1 : (env.tree.childKind? d "package.json").isNone = true
    · simp only [h1, ↓reduceIte]; exact Pure.ret
    simp only [h1]
    apply Pure.bind_look
    try dsimp only
    rcases env.tree.realPath (d ++ ["package.json"]) with e | real
    · exact Pure.ret
    try dsimp only
    apply Pure.bind_look
    try dsimp only
    by_cases h2 : (env.tree.kindAt? real != some Kind.file) = true
    · simp only [h2, ↓reduceIte]; exact Pure.ret
    simp only [h2]
    have tail : ∀ info : Option NpmInfo, Pure env
        (match info with
          | none => pure (ForInStep.done (some (some (d, none)), ()))
          | some i =>
            if i.project = true then pure (ForInStep.done (some (some (d, some (i.deps ++ i.dev))), ()))
            else pure (ForInStep.yield (none, ())))
        (match info with
          | none => some (ForInStep.done (some (some (d, none)), ()))
          | some i => if i.project = true then some (ForInStep.done (some (some (d, some (i.deps ++ i.dev))), ()))
            else some (ForInStep.yield (none, ()))) := by
      intro info
      rcases info with _ | i
      · exact Pure.ret
      · dsimp only; split <;> exact Pure.ret
    apply Pure.bind_get
    intro s htr
    split
    · rename_i r hr
      obtain ⟨bs, hb, hp⟩ := htr.npm _ r (lookup_mem hr)
      refine Pure.bind_pure (Pure.congr (tail r) ?_)
      change fileBytes env.tree real env.config.limits.packageJson = some bs at hb
      rw [hb]; subst hp; rfl
    · refine Pure.bind Pure.openFile fun bytes hb => ?_
      refine Pure.bind_modify (fun s h => ⟨⟨h.manifests, fun q r hq => ?_⟩, rfl⟩) (Pure.bind_pure (tail _))
      rcases List.mem_cons.mp hq with e | hq
      · cases e; exact ⟨bytes, hb, rfl⟩
      · exact h.npm q r hq
  · rcases r with ⟨_ | r, _⟩ <;> exact Pure.ret

theorem Pure.declared {imp : Importer} : Pure env (declared imp) (declaredV env.view imp) := by
  rcases imp with p | ⟨dir, name, _ | i⟩
  · unfold Haus.Packages.declared declaredV
    dsimp only
    rw [Option.map_eq_bind]
    refine Pure.bind Pure.projectOf fun r _ => ?_
    rcases r with _ | ⟨d, _ | names⟩ <;> exact Pure.ret
  · exact Pure.ret
  · exact Pure.ret

theorem Pure.npmLookup {start : Path} {name : String} :
    Pure env (npmLookup start name) (npmFind env.tree name (walk env.config.worldWritable start name)).toOption := by
  intro κ s hs
  rw [npmLookup_eq]
  cases npmFind env.tree name (walk env.config.worldWritable start name) <;> first | exact ⟨hs, rfl⟩ | rfl

theorem Pure.decodeScan {bytes : List UInt8} {what : String} : Pure env (decodeScan bytes what) (decodeV bytes) := by
  unfold Haus.Packages.decodeScan decodeV
  split <;> rename_i h <;> rw [h]
  · exact Pure.fail
  · rename_i t
    show Pure env _ (match scan t with | .ok s => some s | .error _ => none)
    split <;> rename_i h <;> rw [h]
    · exact Pure.ret
    · exact Pure.fail

theorem Pure.checkNames {imp : Import} {types : List String} {what : String} :
    Pure env (checkNames imp types what) (if namesOk imp types then some () else none) := by
  unfold Haus.Packages.checkNames
  split
  · rename_i n hn
    have : ¬ namesOk imp types := fun h => by
      have := List.find?_some hn
      simp only [decide_eq_true_eq] at this
      exact this (h n (List.mem_of_find?_eq_some hn))
    rw [ite_eq_right_of_eq_false _ _ (eq_false this)]
    exact Pure.fail
  · rename_i hn
    have : namesOk imp types := fun n h => by
      have := List.find?_eq_none.mp (by
        cases e : imp.names.find? (· ∉ types) with
        | none => rfl
        | some x => exact absurd e (hn x)) n h
      simpa using this
    rw [ite_eq_left_of_eq_true _ _ (eq_true this)]
    exact Pure.ret

theorem Pure.noteImports {k : Nat} : Pure env (noteImports k) (some ()) :=
  fun _ => Triple.modify fun _ h => ⟨⟨⟨h.1.manifests, h.1.npm⟩, h.2⟩, rfl⟩

theorem if_pos' {c : Prop} {inst : Decidable c} (h : c) {α : Sort _} {a b : α} : @ite α c inst a b = a := by
  cases inst
  · contradiction
  · rfl
theorem if_neg' {c : Prop} {inst : Decidable c} (h : ¬c) {α : Sort _} {a b : α} : @ite α c inst a b = b := by
  cases inst
  · rfl
  · contradiction

theorem Pure.candidatesTail {imp : Importer} {name : String} {inF fromNpm : List (Path × String)} :
    Pure env
      (if (inF ++ fromNpm.filter fun x => !inF.any fun y => y.1 == x.1).isEmpty = true then
        (do let broken ← ask fun x => x.broken
            let _ ← Haus.Packages.fail (α := Unit) Code.importNotFound
              (toString imp.show ++ toString " imports " ++ toString name ++ toString ", which isn't found" ++
                toString (if broken.isEmpty = true then ""
                  else toString "; these entries of the folders given have no valid package.haus: " ++
                    toString (", ".intercalate broken)))
            pure (inF ++ fromNpm.filter fun x => !inF.any fun y => y.1 == x.1))
      else pure (inF ++ fromNpm.filter fun x => !inF.any fun y => y.1 == x.1))
      (if (inF ++ fromNpm.filter fun x => !inF.any fun y => y.1 == x.1).isEmpty = true then none
        else some (inF ++ fromNpm.filter fun x => !inF.any fun y => y.1 == x.1)) := by
  split
  · exact Pure.bind_ask Pure.bind_fail
  · exact Pure.ret

theorem Pure.candidates {imp : Importer} {name : String} :
    Pure env (candidates imp name) (candV env.view imp name) := by
  rcases imp with p | ⟨dir, pn, npm⟩
  all_goals
    unfold Haus.Packages.candidates candV
    refine Pure.bind_modify (fun s h => ⟨⟨h.manifests, h.npm⟩, rfl⟩) ?_
    apply Pure.bind_ask
    dsimp only
    view
    refine Pure.ite2 (fun _ => Pure.ret) (fun _ => ?_)
    apply Pure.bind_cfg
    refine Pure.ite2bind (fun _ => Pure.bind_pure Pure.candidatesTail) (fun _ => ?_)
    rw [Option.bind_assoc]
    refine Pure.bind Pure.declared fun x _ => ?_
    rcases x with ⟨decl, where_⟩
    dsimp only
    refine Pure.ite2bind (fun _ => ?_) (fun _ => ?_)
    · rw [Option.map_eq_bind, Option.bind_assoc]
      exact Pure.bind Pure.npmLookup fun r _ => Pure.bind_pure Pure.candidatesTail
    refine Pure.ite2bind (fun _ => Pure.bind_fail) (fun _ => Pure.bind_pure Pure.candidatesTail)

end

end Haus.Packages
