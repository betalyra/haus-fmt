import Haus.Packages.Reads

/-!
# Non-interference (R7, P2)

Two trees that differ only in the bytes of files in a set `D` (`Same D t t'`:
the same paths in the same order, the same directories, links and other
files, and files where the other has a file) give the same run, result,
messages and files read included, as long as the run on one of them reads
no file of `D` (`resolveIn_same`). With the read set of `Haus.Packages.Reads`:
changing the bytes of any file that is not one the resolver may read
changes nothing (`resolveIn_other_files`).

The resolver sees the tree only through `look`, which tells kinds, names,
links and real paths, never bytes (`Same.look_*`), and `openFile`, which
records what it opens; so the proof goes a construct at a time (`NI`).
-/

namespace Haus.Packages

/-- Two lists of entries, pairwise the same but for the bytes of files at paths of `D`. -/
def SameEntries (D : Path → Prop) : List (Path × Entry) → List (Path × Entry) → Prop
  | [], [] => True
  | a :: as, b :: bs => (a.1 = b.1 ∧ (a.2 = b.2 ∨ (D a.1 ∧ a.2.kind = .file ∧ b.2.kind = .file))) ∧ SameEntries D as bs
  | _, _ => False

/-- `t'` is `t` with other bytes in some of the files of `D`. -/
def Same (D : Path → Prop) (t t' : Tree) : Prop := SameEntries D t.entries t'.entries

theorem SameEntries.induct' {D : Path → Prop} {motive : List (Path × Entry) → List (Path × Entry) → Prop}
    (nil : motive [] [])
    (cons : ∀ a b as bs, (a.1 = b.1 ∧ (a.2 = b.2 ∨ (D a.1 ∧ a.2.kind = .file ∧ b.2.kind = .file))) →
      SameEntries D as bs → motive as bs → motive (a :: as) (b :: bs)) :
    ∀ l l', SameEntries D l l' → motive l l'
  | [], [], _ => nil
  | a :: as, b :: bs, h => cons a b as bs h.1 h.2 (SameEntries.induct' nil cons as bs h.2)
  | [], _ :: _, h => absurd h id
  | _ :: _, [], h => absurd h id

namespace Same
variable {D : Path → Prop} {t t' : Tree}

theorem keys (h : Same D t t') : t.entries.map (·.1) = t'.entries.map (·.1) := by
  refine SameEntries.induct' (motive := fun l l' => l.map (·.1) = l'.map (·.1)) rfl ?_ _ _ h
  intro a b _ _ hab _ ih
  simp [hab.1, ih]

theorem length (h : Same D t t') : t.entries.length = t'.entries.length := by
  simpa using congrArg List.length h.keys

theorem list (h : Same D t t') (d : Path) : t.list d = t'.list d := by
  have e : ∀ u : Tree, u.list d = (u.entries.map (·.1)).filterMap
      (fun p => if p.dropLast == d && p.length == d.length + 1 then p.getLast? else none) := by
    intro u; simp only [Tree.list, List.filterMap_map]; rfl
  rw [e, e, h.keys]

/-- The entries at a path: the same, or files at a path of `D`. -/
theorem get? (h : Same D t t') (p : Path) :
    t.get? p = t'.get? p ∨ (D p ∧ (t.get? p).map Entry.kind = some .file ∧ (t'.get? p).map Entry.kind = some .file) := by
  unfold Tree.get?
  split
  · exact Or.inl rfl
  refine SameEntries.induct' (motive := fun l l' =>
    (l.find? (·.1 == p)).map (·.2) = (l'.find? (·.1 == p)).map (·.2) ∨
    (D p ∧ ((l.find? (·.1 == p)).map (·.2)).map Entry.kind = some .file ∧
      ((l'.find? (·.1 == p)).map (·.2)).map Entry.kind = some .file)) (Or.inl rfl) ?_ _ _ h
  intro a b _ _ hab _ ih
  · obtain ⟨hk, he⟩ := hab
    simp only [List.find?_cons, hk]
    split
    · rename_i hp
      rcases he with he | ⟨hd, ha, hb⟩
      · exact Or.inl (by simp [he])
      · right
        simp only [beq_iff_eq] at hp
        subst hp
        exact ⟨hk ▸ hd, by simpa using ha, by simpa using hb⟩
    · exact ih

theorem kind_get? (h : Same D t t') (p : Path) : (t.get? p).map Entry.kind = (t'.get? p).map Entry.kind := by
  rcases h.get? p with e | ⟨_, h1, h2⟩
  · rw [e]
  · rw [h1, h2]

theorem childKind (h : Same D t t') (d : Path) (n : String) : t.childKind? d n = t'.childKind? d n := by
  unfold Tree.childKind? Tree.child?
  rw [h.list]
  split
  · exact h.kind_get? _
  · rfl

theorem kindAt (h : Same D t t') (p : Path) : t.kindAt? p = t'.kindAt? p := by
  unfold Tree.kindAt? Tree.at?
  split
  · exact h.childKind _ _
  · rfl

theorem isDir (h : Same D t t') (p : Path) : t.isDir p = t'.isDir p := by
  have hk := h.kindAt p
  unfold Tree.kindAt? at hk
  unfold Tree.isDir
  cases ha : t.at? p with
  | none => cases hb : t'.at? p <;> simp_all
  | some e =>
    cases hb : t'.at? p with
    | none => simp_all
    | some e' =>
      rw [ha, hb] at hk
      simp only [Option.map_some, Option.some.injEq] at hk
      cases e <;> cases e' <;> simp_all [Entry.kind] <;> rfl

theorem resolve (h : Same D t t') (fuel : Nat) (cur : Path) (rest : List String) :
    Haus.Packages.resolve t fuel cur rest = Haus.Packages.resolve t' fuel cur rest := by
  have hk : ∀ cur c, (t'.child? cur c).map Entry.kind = (t.child? cur c).map Entry.kind :=
    fun cur c => (h.childKind cur c).symm
  induction fuel, cur, rest using Haus.Packages.resolve.induct t with
  | case1 fuel cur => simp [Haus.Packages.resolve]
  | case2 fuel cur c rest hc ih => rw [Haus.Packages.resolve, Haus.Packages.resolve]; simp [hc, ih]
  | case3 fuel cur c rest hc hd ih =>
    rw [Haus.Packages.resolve, Haus.Packages.resolve]; simp only [hc, hd]; simpa using ih
  | case4 fuel cur c rest hc hd hn =>
    have : t'.child? cur c = none := by simpa [hn] using hk cur c
    rw [Haus.Packages.resolve, Haus.Packages.resolve]; simp [hc, hd, hn, this]
  | case5 fuel cur c rest hc hd hn ih =>
    have : t'.child? cur c = some .dir := by
      have := hk cur c; rw [hn] at this
      cases e : t'.child? cur c with
      | none => rw [e] at this; simp at this
      | some v => rw [e] at this; cases v <;> simp_all [Entry.kind]
    rw [Haus.Packages.resolve, Haus.Packages.resolve]; simp [hc, hd, hn, this, ih]
  | case6 cur c rest hc hd target hn =>
    have : t'.child? cur c = some (.link target) := by
      have := hk cur c; rw [hn] at this
      cases e : t'.child? cur c with
      | none => rw [e] at this; simp at this
      | some v => rw [e] at this; cases v <;> simp_all [Entry.kind]
    rw [Haus.Packages.resolve, Haus.Packages.resolve]; simp [hc, hd, hn, this]
  | case7 cur c rest hc hd target hn fuel ih =>
    have : t'.child? cur c = some (.link target) := by
      have := hk cur c; rw [hn] at this
      cases e : t'.child? cur c with
      | none => rw [e] at this; simp at this
      | some v => rw [e] at this; cases v <;> simp_all [Entry.kind]
    rw [Haus.Packages.resolve, Haus.Packages.resolve]; simp [hc, hd, hn, this, ih]
  | case8 fuel cur c rest hc hd val hv1 hv2 hn hr | case9 fuel cur c rest hc hd val hv1 hv2 hn hr =>
    obtain ⟨v', hv', hkind⟩ : ∃ v', t'.child? cur c = some v' ∧ v'.kind = val.kind := by
      have := hk cur c; rw [hn] at this
      cases e : t'.child? cur c with
      | none => rw [e] at this; simp at this
      | some v => rw [e] at this; exact ⟨v, rfl, by simpa using this⟩
    have h1 : v' ≠ .dir := by rintro rfl; cases val <;> simp_all [Entry.kind]
    have h2 : ∀ target, v' ≠ .link target := by rintro target rfl; cases val <;> simp_all [Entry.kind]
    rw [Haus.Packages.resolve, Haus.Packages.resolve]
    simp only [hc, hd, hn, hv', Bool.false_eq_true, ↓reduceIte]
    try (split <;> split <;> (try simp_all))

theorem kind_file {e : Option Entry} (h : e.map Entry.kind = some .file) : ∃ bs, e = some (.file bs) := by
  rcases e with _ | (_ | bs | _ | _) <;> simp_all [Entry.kind]

theorem at? (h : Same D t t') (p : Path) :
    t.at? p = t'.at? p ∨ (D p ∧ (∃ bs, t.at? p = some (.file bs)) ∧ ∃ bs, t'.at? p = some (.file bs)) := by
  unfold Tree.at?
  rcases hp : p.getLast? with _ | n
  · exact Or.inl rfl
  · simp only
    unfold Tree.child?
    rw [h.list]
    split
    · have hpd : p.dropLast ++ [n] = p := by
        have hne : p ≠ [] := by rintro rfl; simp at hp
        rw [List.getLast?_eq_some_getLast hne] at hp
        cases hp
        exact List.dropLast_concat_getLast hne
      rcases h.get? (p.dropLast ++ [n]) with e | ⟨hd, h1, h2⟩
      · exact Or.inl e
      · exact Or.inr ⟨hpd ▸ hd, kind_file h1, kind_file h2⟩
    · exact Or.inl rfl

theorem realPath (h : Same D t t') (p : Path) : t.realPath p = t'.realPath p := h.resolve _ _ _

theorem inPackage (h : Same D t t') (p : Path) : Haus.Packages.inPackage t p = Haus.Packages.inPackage t' p := by
  unfold Haus.Packages.inPackage
  simp only [h.childKind]

end Same

end Haus.Packages

namespace Haus.Packages

/-!
## A construct at a time

`NI D x`: `x` only adds to the files read, and on a tree that is the same but
for the bytes of files of `D`, it does the same, if it reads no file of `D`.
-/

def NI {α} (D : Path → Prop) (x : M α) : Prop :=
  ∀ env t' s, Same D env.tree t' →
    (∀ p ∈ s.reads, p ∈ (go x env s).2.reads) ∧
    ((∀ p ∈ (go x env s).2.reads, ¬ D p) → go x { env with tree := t' } s = go x env s)

namespace NI
variable {α β γ : Type} {D : Path → Prop}

theorem pure {a : α} : NI D (Pure.pure a : M α) := fun _ _ _ _ => ⟨fun _ h => h, fun _ => rfl⟩

theorem bind {x : M α} {f : α → M β} (hx : NI D x) (hf : ∀ a, NI D (f a)) : NI D (x >>= f) := by
  intro env t' s h
  have ⟨mx, ex⟩ := hx env t' s h
  rw [go_bind, go_bind]
  revert mx ex
  rcases go x env s with ⟨r, s₁⟩
  intro mx ex
  cases r with
  | error e =>
    exact ⟨mx, fun hr => by rw [ex hr]⟩
  | ok a =>
    have ⟨mf, ef⟩ := hf a env t' s₁ h
    refine ⟨fun p hp => mf p (mx p hp), fun hr => ?_⟩
    rw [ex fun p hp => hr p (mf p hp)]
    exact ef hr

theorem get : NI D (MonadState.get : M St) := fun _ _ _ _ => ⟨fun _ h => h, fun _ => rfl⟩

theorem modify {g : St → St} (hg : ∀ s, (g s).reads = s.reads) : NI D (_root_.modify g : M Unit) :=
  fun _ _ s _ => ⟨fun p hp => by simp [hg, hp], fun _ => rfl⟩

theorem throw {e : Err} : NI D (MonadExcept.throw e : M α) := fun _ _ _ _ => ⟨fun _ h => h, fun _ => rfl⟩

theorem fail {c : Code} {m : String} : NI D (Haus.Packages.fail c m : M α) :=
  fun _ _ _ _ => ⟨fun _ h => h, fun _ => rfl⟩

theorem look {δ} {g : Tree → δ} (hg : ∀ t t', Same D t t' → g t = g t') : NI D (Haus.Packages.look g) :=
  fun env t' _ h => ⟨fun _ h => h, fun _ => by simp [hg _ _ h]⟩

theorem ask {δ} {f : Env → δ} (hf : ∀ env t', f { env with tree := t' } = f env) : NI D (Haus.Packages.ask f) :=
  fun env t' _ _ => ⟨fun _ h => h, fun _ => by simp [hf]⟩

theorem cfg : NI D Haus.Packages.cfg := ask fun _ _ => rfl

theorem tryCatch {x : M α} {h : Err → M α} (hx : NI D x) (hh : ∀ e, NI D (h e)) : NI D (tryCatch x h) := by
  intro env t' s hs
  have ⟨mx, ex⟩ := hx env t' s hs
  rw [go_tryCatch, go_tryCatch]
  revert mx ex
  rcases go x env s with ⟨r, s₁⟩
  intro mx ex
  cases r with
  | ok a => exact ⟨mx, fun hr => by rw [ex hr]⟩
  | error e =>
    have ⟨mf, ef⟩ := hh e env t' s₁ hs
    refine ⟨fun p hp => mf p (mx p hp), fun hr => ?_⟩
    rw [ex fun p hp => hr p (mf p hp)]
    exact ef hr

theorem withReader {x : M α} (hx : NI D x) (g : List Given) (b : List String) :
    NI D (MonadWithReader.withReader (fun (e : Env) => { e with given := g, broken := b }) x) := by
  intro env t' s h
  have := hx { env with given := g, broken := b } t' s h
  rw [go_withReader, go_withReader]
  exact this

theorem forIn {xs : List γ} {b : β} {f : γ → β → M (ForInStep β)} (h : ∀ a b, NI D (f a b)) :
    NI D (ForIn.forIn xs b f) := by
  induction xs generalizing b with
  | nil => rw [List.forIn_nil]; exact pure
  | cons a rest ih =>
    rw [List.forIn_cons]
    refine bind (h a b) fun r => ?_
    cases r with
    | done b' => exact pure
    | yield b' => exact ih

theorem map {x : M α} {f : α → β} (hx : NI D x) : NI D (f <$> x) := by
  rw [← bind_pure_comp]; exact bind hx fun _ => pure

end NI

theorem openFile_reads {env : Env} {s : St} {p : Path} {limit : Nat} {tl : Nat → Err} {bs : List UInt8}
    (h : env.tree.at? p = some (.file bs)) : p ∈ (go (openFile p limit tl) env s).2.reads := by
  unfold openFile
  simp only [go_bind, go_read, h, go_get]
  by_cases hp : p ∈ s.reads
  · simp only [hp, not_true_eq_false, ↓reduceIte]
    split <;> simp_all [go_map]
  · simp only [hp, not_false_eq_true, ↓reduceIte, go_bind, go_modify]
    split <;> simp_all [go_map]

theorem openFile_mono {env : Env} {s : St} {p : Path} {limit : Nat} {tl : Nat → Err} :
    ∀ q ∈ s.reads, q ∈ (go (openFile p limit tl) env s).2.reads := by
  intro q hq
  unfold openFile
  simp only [go_bind, go_read]
  split
  · simp only [go_bind, go_get]
    split
    · simp only [go_bind, go_modify]; split <;> simp_all [go_map]
    · split <;> simp_all [go_map]
  · simpa using hq

theorem NI.openFile {D : Path → Prop} {p : Path} {limit : Nat} {tl : Nat → Err} : NI D (openFile p limit tl) := by
  intro env t' s h
  refine ⟨openFile_mono, fun hr => ?_⟩
  rcases h.at? p with e | ⟨hd, ⟨bs, hbs⟩, -⟩
  · unfold Haus.Packages.openFile
    simp only [go_bind, go_read]
    rw [show ({ env with tree := t' } : Env).tree.at? p = env.tree.at? p from e.symm]
    split
    · simp only [go_bind, go_get]
      split
      · simp only [go_bind, go_modify]; split <;> simp [go_map]
      · split <;> simp [go_map]
    · rfl
  · exact absurd hd (hr p (openFile_reads hbs))

/-- What `look` asks is the same on both trees. -/
macro "look_ok" : tactic => `(tactic| first
  | exact fun _ _ h => h.childKind _ _
  | exact fun _ _ h => h.kindAt _
  | exact fun _ _ h => h.realPath _
  | exact fun _ _ h => h.isDir _
  | exact fun _ _ h => h.list _
  | exact fun _ _ h => h.resolve _ _ _
  | exact fun _ _ h => h.inPackage _
  | exact fun _ _ h => congrArg (· + 1) h.length)

macro "nistep" : tactic => `(tactic| first
  | with_reducible exact NI.pure
  | with_reducible exact NI.get
  | with_reducible exact NI.throw
  | with_reducible exact NI.fail
  | with_reducible exact NI.cfg
  | with_reducible exact NI.ask fun _ _ => rfl
  | with_reducible exact NI.openFile
  | (with_reducible apply NI.modify; intro _; rfl)
  | (with_reducible apply NI.look; look_ok)
  | with_reducible refine NI.bind ?_ fun _ => ?_
  | with_reducible refine NI.forIn fun _ _ => ?_
  | with_reducible refine NI.tryCatch ?_ fun _ => ?_
  | with_reducible refine NI.map ?_
  | with_reducible refine NI.withReader ?_ _ _
  | split
  | dsimp only
  | exact NI.pure
  | refine NI.bind ?_ fun _ => ?_)

macro "ni" : tactic => `(tactic| repeat nistep)

section
variable {D : Path → Prop}

theorem NI.openPackageFile {dir : Path} {name : String} {limit : Nat} {code : Code} {owner : String} :
    NI D (openPackageFile dir name limit code owner) := by unfold Haus.Packages.openPackageFile; ni

theorem NI.manifestOf {dir : Path} {shown : String} : NI D (manifestOf dir shown) := by
  unfold Haus.Packages.manifestOf
  repeat (first
    | with_reducible exact NI.openPackageFile
    | nistep)

theorem NI.packageJsonOf {dir : Path} {owner : String} : NI D (packageJsonOf dir owner) := by
  unfold Haus.Packages.packageJsonOf
  repeat (first
    | with_reducible exact NI.openPackageFile
    | nistep)

theorem NI.projectOf {p : Path} : NI D (projectOf p) := by unfold Haus.Packages.projectOf; ni

theorem NI.declared {imp : Importer} : NI D (declared imp) := by
  unfold Haus.Packages.declared
  repeat (first
    | with_reducible exact NI.projectOf
    | nistep)

theorem NI.npmLookup {start : Path} {name : String} : NI D (npmLookup start name) := by
  unfold Haus.Packages.npmLookup; ni

theorem NI.candidates {imp : Importer} {name : String} : NI D (candidates imp name) := by
  unfold Haus.Packages.candidates
  repeat (first
    | with_reducible exact NI.declared
    | with_reducible exact NI.npmLookup
    | nistep)

theorem NI.checkNames {imp : Import} {types : List String} {what : String} : NI D (checkNames imp types what) := by
  unfold Haus.Packages.checkNames; ni

theorem NI.decodeScan {bytes : List UInt8} {what : String} : NI D (decodeScan bytes what) := by
  unfold Haus.Packages.decodeScan; ni

theorem NI.countFile {what : String} : NI D (countFile what) := by unfold Haus.Packages.countFile; ni

theorem NI.noteImports {k : Nat} : NI D (noteImports k) := by unfold Haus.Packages.noteImports; ni

theorem NI.classify {c : Class} : NI D (classify c) := by unfold Haus.Packages.classify; ni

theorem NI.resolveImport {loadFn : Target → M Loaded} {importer : Importer} {imp : Import}
    (hload : ∀ T, NI D (loadFn T)) : NI D (resolveImport loadFn importer imp) := by
  unfold Haus.Packages.resolveImport
  repeat (first
    | with_reducible exact NI.candidates
    | with_reducible exact NI.manifestOf
    | with_reducible exact NI.checkNames
    | with_reducible exact hload _
    | nistep)

theorem NI.load : ∀ n T, NI D (load n T)
  | 0, _ => by unfold Haus.Packages.load; ni
  | n + 1, .file p => by
    unfold Haus.Packages.load
    repeat (first
      | with_reducible exact NI.resolveImport (NI.load n)
      | with_reducible exact NI.countFile
      | with_reducible exact NI.decodeScan
      | with_reducible exact NI.noteImports
      | nistep)
  | n + 1, .copy dir => by
    unfold Haus.Packages.load
    repeat (first
      | with_reducible exact NI.resolveImport (NI.load n)
      | with_reducible exact NI.countFile
      | with_reducible exact NI.decodeScan
      | with_reducible exact NI.noteImports
      | with_reducible exact NI.manifestOf
      | with_reducible exact NI.packageJsonOf
      | with_reducible exact NI.openPackageFile
      | with_reducible exact NI.classify
      | nistep)

theorem NI.givenPackages : NI D givenPackages := by
  unfold Haus.Packages.givenPackages
  repeat (first
    | with_reducible exact NI.manifestOf
    | nistep)

theorem NI.main {root : Path} : NI D (main root) := by
  unfold Haus.Packages.main
  repeat (first
    | with_reducible exact NI.givenPackages
    | with_reducible exact NI.load _ _
    | nistep)

end

end Haus.Packages

namespace Haus.Packages

/--
**Non-interference** (R7, P2): if a run on `t` reads no file of `D`, the run
on a tree that differs from `t` only in the bytes of files of `D` is the same
run: the same result, the same message, the same files read.
-/
theorem resolveIn_same {D : Path → Prop} {t t' : Tree} {c : Config} {root : Path} (h : Same D t t')
    (hr : ∀ p ∈ (resolveIn t c root).reads, ¬ D p) : resolveIn t' c root = resolveIn t c root := by
  rw [resolveIn_runIn, resolveIn_runIn]
  unfold runIn
  have := (NI.main (D := D) (root := root) { tree := t, config := c } t' {} h).2 hr
  exact congrArg Outcome.of this

/--
Changing the bytes of files the resolver may not read (R7's read set,
`Allowed`) changes neither the result nor any message (P1, P2).
-/
theorem resolveIn_other_files {D : Path → Prop} {t t' : Tree} {c : Config} {root : Path} (h : Same D t t')
    (hD : ∀ p, D p → ¬ Allowed t root p) : resolveIn t' c root = resolveIn t c root :=
  resolveIn_same h fun p hp hd => hD p hd (reads_allowed t c root p hp)

end Haus.Packages
