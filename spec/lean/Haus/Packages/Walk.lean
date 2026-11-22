import Haus.Packages.Done

/-!
# Order independence (R3, security review F4)

A run in another walk order (`Walk`) is compared with the last state `S` of
a successful run (`Haus.Packages.Done`): every target `S` finished passes its
own checks, as a property of the tree alone, and imports only targets
finished before it (`Ref`). The run in another order, from a state `Below`
`S`, never fails and stays below it (`load_sim`): it loads only targets `S`
finished, so its files are within the limit of `S`; a target on its stack
was finished in `S` after every target it loads, so no cycle is met and its
fuel doesn't run out; and its classes are those of `S`'s packages, so
`duplicate-package` can't occur.
-/

namespace Haus.Packages

/-! ## Lists -/

theorem findIdx?_prefix {α : Type} {p : α → Bool} {l l' : List α} (h : l <+: l') {i : Nat}
    (hi : l.findIdx? p = some i) : l'.findIdx? p = some i := by
  obtain ⟨t, rfl⟩ := h
  rw [List.findIdx?_append, hi]; rfl

theorem findIdx?_name {l : List Class} (hd : (l.map (·.name)).Nodup) {j : Nat} {c : Class} (hj : l[j]? = some c) :
    l.findIdx? (·.name == c.name) = some j := by
  rw [List.findIdx?_eq_some_iff_getElem]
  obtain ⟨hlt, e⟩ := List.getElem?_eq_some_iff.mp hj
  refine ⟨hlt, by simp [e], fun k hk => ?_⟩
  intro h
  simp only [beq_iff_eq] at h
  have := List.pairwise_iff_getElem.mp hd k j (by simp; omega) (by simp; omega) hk
  simp only [List.getElem_map] at this
  exact this (h.trans (by rw [e]))

/-! ## The run in another order, and the state it is compared with -/

/-- `T` is being loaded. -/
def Loading' (κ : Core) : Target → Prop
  | .file p => κ.files.lookup p = some none
  | .copy d => κ.copies.lookup d = some .loading

/-- The class an import of a package reaches, in `cs`: the one with its name. -/
def clsOf (cs : Classes) (imp : Import) : Option Nat :=
  match imp.module with
  | .pkg n _ => cs.list.findIdx? (·.name == n)
  | _ => none

/-- Every package the imports name has a class in `cs`. -/
def Present (cs : Classes) (imps : List Import) : Prop :=
  ∀ imp ∈ imps, ∀ n mj, imp.module = .pkg n mj → ∃ c ∈ cs.list, c.name = n

/-- What the last state of a successful run gives: its finished targets, closed and checked. -/
structure Ref (V : View) (fin : List Target) : Prop where
  nodup : fin.Nodup
  local_ : ∀ T ∈ fin, Local V (Before fin T) T
  len : fin.length ≤ V.limits.files
  names : ∀ d d' c c', .copy d ∈ fin → .copy d' ∈ fin → Corr V d c → Corr V d' c' → c.name = c'.name →
    c.manifest = c'.manifest ∧ c.schema = c'.schema

/-- A state of the run in the order `w` below the reference `fin` (`δ`: started, not counted). -/
structure Below (V : View) (w : Walk) (fin : List Target) (δ : Nat) (κ : Core) : Prop where
  started : ∀ T ∈ startedOf κ, T ∈ fin
  nodup : (startedOf κ).Nodup
  count : κ.count + δ ≤ (startedOf κ).length
  files : ∀ p ts, κ.files.lookup p = some (some ts) → typesV V (.file p) = some ts
  copies : ∀ d k, κ.copies.lookup d = some (.done k) → ∃ c, κ.classes.list[k]? = some c ∧ Corr V d c
  classes : ∀ c ∈ κ.classes.list, ∃ d, .copy d ∈ fin ∧ Corr V d c ∧ ∃ sc, decodeV c.schema = some sc ∧
    c.imports = (w.order sc.imports).filterMap (clsOf κ.classes) ∧ Present κ.classes sc.imports

/-- What a call to `load` keeps: the classes grow, the targets started stay, none is left loading. -/
structure Frame (κ κ' : Core) : Prop where
  classes : κ.classes.list <+: κ'.classes.list
  started : ∀ T ∈ startedOf κ, T ∈ startedOf κ'
  loading : ∀ T, Loading' κ' T → Loading' κ T

theorem Frame.refl (κ : Core) : Frame κ κ := ⟨List.prefix_refl _, fun _ h => h, fun _ h => h⟩

theorem Frame.trans {κ₁ κ₂ κ₃ : Core} (h₁ : Frame κ₁ κ₂) (h₂ : Frame κ₂ κ₃) : Frame κ₁ κ₃ :=
  ⟨h₁.classes.trans h₂.classes, fun T h => h₂.started T (h₁.started T h), fun T h => h₁.loading T (h₂.loading T h)⟩

/-- What `load T` gives in the run in another order. -/
def RetB (V : View) (T : Target) (r : Loaded) (κ : Core) : Prop :=
  typesV V T = some r.types ∧ ∀ d, T = .copy d → ∃ k c, r.cls = some k ∧ κ.classes.list[k]? = some c ∧ Corr V d c

theorem Corr.unique {V : View} {d : Path} {c c' : Class} (h : Corr V d c) (h' : Corr V d c') :
    c.name = c'.name ∧ c.version = c'.version ∧ c.manifest = c'.manifest ∧ c.schema = c'.schema ∧
      c.types = c'.types := by
  obtain ⟨m, bs, sc, h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
  obtain ⟨m', bs', sc', h1', h2', h3', h4', h5', h6', h7', h8'⟩ := h'
  rw [h1] at h1'; cases h1'
  rw [h2] at h2'; cases h2'
  rw [h3] at h3'; cases h3'
  exact ⟨h4.trans h4'.symm, h5.trans h5'.symm, h6.trans h6'.symm, h7.trans h7'.symm, h8.trans h8'.symm⟩

theorem Present.mono {cs cs' : Classes} {imps : List Import} (h : Present cs imps) (hp : cs.list <+: cs'.list) :
    Present cs' imps := fun imp hi n mj hm => by
  obtain ⟨c, hc, e⟩ := h imp hi n mj hm
  exact ⟨c, hp.subset hc, e⟩

theorem clsOf_mono {cs cs' : Classes} {imps : List Import} (h : Present cs imps) (hp : cs.list <+: cs'.list) :
    ∀ imp ∈ imps, clsOf cs' imp = clsOf cs imp := by
  intro imp hi
  unfold clsOf
  split
  · rename_i n mj hm
    obtain ⟨c, hc, e⟩ := h imp hi n mj hm
    obtain ⟨j, hj⟩ : ∃ j, cs.list.findIdx? (·.name == n) = some j := by
      cases e' : cs.list.findIdx? (·.name == n) with
      | some j => exact ⟨j, rfl⟩
      | none =>
        have := List.findIdx?_eq_none_iff.mp e' c hc
        simp [e] at this
    rw [hj, findIdx?_prefix hp hj]
  · rfl

theorem filterMap_congr' {α β : Type} {f g : α → Option β} : ∀ {l : List α}, (∀ x ∈ l, f x = g x) →
    l.filterMap f = l.filterMap g
  | [], _ => rfl
  | x :: xs, h => by
    rw [List.filterMap_cons, List.filterMap_cons, h x List.mem_cons_self,
      filterMap_congr' fun y hy => h y (List.mem_cons_of_mem _ hy)]

theorem filterMap_clsOf_mono {cs cs' : Classes} {imps l : List Import} (h : Present cs imps)
    (hp : cs.list <+: cs'.list) (hl : ∀ x ∈ l, x ∈ imps) :
    l.filterMap (clsOf cs') = l.filterMap (clsOf cs) :=
  filterMap_congr' fun x hx => clsOf_mono h hp x (hl x hx)

/-! ## The state, step by step -/

theorem file_not_started {κ : Core} {p : Path} (h : κ.files.lookup p = none) : .file p ∉ startedOf κ := by
  intro hm
  simp only [startedOf, List.mem_append, List.mem_filterMap] at hm
  rcases hm with ⟨⟨p', o⟩, he, hx⟩ | ⟨⟨d, l⟩, _, hx⟩
  · dsimp only at hx
    split at hx
    · rename_i ho
      simp only [Option.some.injEq, Target.file.injEq] at hx
      subst hx
      cases o with
      | none => exact not_mem_of_lookup_none h he
      | some _ => simp at ho
    · cases hx
  · dsimp only at hx; split at hx <;> cases hx

theorem copy_not_started {κ : Core} {d : Path} (h : κ.copies.lookup d = none) : .copy d ∉ startedOf κ := by
  intro hm
  simp only [startedOf, List.mem_append, List.mem_filterMap] at hm
  rcases hm with ⟨⟨p, o⟩, _, hx⟩ | ⟨⟨d', l⟩, he, hx⟩
  · dsimp only at hx; split at hx <;> cases hx
  · dsimp only at hx
    split at hx
    · rename_i hl
      simp only [Option.some.injEq, Target.copy.injEq] at hx
      subst hx; subst hl
      exact not_mem_of_lookup_none h he
    · cases hx

section
variable {V : View} {w : Walk} {fin : List Target} {δ : Nat} {κ : Core}

theorem Below.markFile {p : Path} (h : Below V w fin δ κ) (hp : κ.files.lookup p = none) (hT : .file p ∈ fin) :
    Below V w fin (δ + 1) (κ.markFile p) ∧ (∀ T, Loading' (κ.markFile p) T → T = .file p ∨ Loading' κ T) := by
  refine ⟨⟨fun T hT' => ?_, ?_, ?_, fun p' ts hl => ?_, h.copies, h.classes⟩, fun T hT' => ?_⟩
  · rw [startedOf_markFile] at hT'
    rcases List.mem_cons.mp hT' with rfl | hT'
    · exact hT
    · exact h.started T hT'
  · rw [startedOf_markFile]; exact List.nodup_cons.mpr ⟨file_not_started hp, h.nodup⟩
  · rw [startedOf_markFile]; have := h.count; simp only [List.length_cons]; simp only [Core.markFile]; omega
  · by_cases e : p' = p
    · subst e; simp [Core.markFile] at hl
    · exact h.files p' ts (by simpa [Core.markFile, lookup_cons_of_ne _ _ e] using hl)
  · cases T with
    | file p' =>
      by_cases e : p' = p
      · left; rw [e]
      · right; simpa [Loading', Core.markFile, lookup_cons_of_ne _ _ e] using hT'
    | copy d => right; exact hT'

theorem Below.markCopy {d : Path} (h : Below V w fin δ κ) (hd : κ.copies.lookup d = none) (hT : .copy d ∈ fin) :
    Below V w fin (δ + 1) (κ.markCopy d) ∧ (∀ T, Loading' (κ.markCopy d) T → T = .copy d ∨ Loading' κ T) := by
  refine ⟨⟨fun T hT' => ?_, ?_, ?_, h.files, fun d' k hl => ?_, h.classes⟩, fun T hT' => ?_⟩
  · rcases mem_startedOf_markCopy.mp hT' with rfl | hT'
    · exact hT
    · exact h.started T hT'
  · exact (perm_startedOf_markCopy κ d).nodup_iff.mpr (List.nodup_cons.mpr ⟨copy_not_started hd, h.nodup⟩)
  · rw [length_startedOf_markCopy]; have := h.count; simp only [Core.markCopy]; omega
  · by_cases e : d' = d
    · subst e; simp [Core.markCopy] at hl
    · exact h.copies d' k (by simpa [Core.markCopy, lookup_cons_of_ne _ _ e] using hl)
  · cases T with
    | copy d' =>
      by_cases e : d' = d
      · left; rw [e]
      · right; simpa [Loading', Core.markCopy, lookup_cons_of_ne _ _ e] using hT'
    | file p => right; exact hT'

theorem Below.countUp (h : Below V w fin (δ + 1) κ) : Below V w fin δ κ.countUp :=
  ⟨h.started, h.nodup, by have := h.count; rw [startedOf_countUp]; simp only [Core.countUp]; omega,
    h.files, h.copies, h.classes⟩

theorem Below.finishFile {p : Path} {ts : List String} (h : Below V w fin 0 κ) (ht : typesV V (.file p) = some ts) :
    Below V w fin 0 (κ.finishFile p ts) ∧ (∀ T, Loading' (κ.finishFile p ts) T → T ≠ .file p ∧ Loading' κ T) := by
  refine ⟨⟨fun T hT => ?_, ?_, ?_, fun p' ts' hl => ?_, h.copies, h.classes⟩, fun T hT => ?_⟩
  · rw [startedOf_finishFile] at hT; exact h.started T hT
  · rw [startedOf_finishFile]; exact h.nodup
  · rw [startedOf_finishFile]; exact h.count
  · by_cases e : p' = p
    · subst e; simp only [Core.finishFile, lookup_cons_self, Option.some.injEq] at hl; subst hl; exact ht
    · exact h.files p' ts' (by simpa [Core.finishFile, lookup_cons_of_ne _ _ e] using hl)
  · cases T with
    | file p' =>
      by_cases e : p' = p
      · subst e; simp [Loading', Core.finishFile] at hT
      · exact ⟨fun h => e (Target.file.inj h), by simpa [Loading', Core.finishFile, lookup_cons_of_ne _ _ e] using hT⟩
    | copy d => exact ⟨(fun h => nomatch h), hT⟩

/-- What the description of a copy given to `classify` is, in the run in another order. -/
def DescOk (V : View) (w : Walk) (fin : List Target) (cs : Classes) (dir : Path) (desc : Class) : Prop :=
  .copy dir ∈ fin ∧ Corr V dir desc ∧ ∃ sc, decodeV desc.schema = some sc ∧
    desc.imports = (w.order sc.imports).filterMap (clsOf cs) ∧ Present cs sc.imports

theorem Below.addClass_ok {dir : Path} {desc : Class} (h : Below V w fin 0 κ) (hr : Ref V fin)
    (hd : DescOk V w fin κ.classes dir desc) : ∃ i cs, addClass desc κ.classes = .ok (i, cs) := by
  unfold addClass
  split
  · rename_i i _; exact ⟨i, _, rfl⟩
  · rename_i hnone
    split
    · rename_i d hfind
      exfalso
      have hd' := List.mem_of_find?_eq_some hfind
      have hdn : d.name = desc.name := by simpa using List.find?_some hfind
      obtain ⟨d', hd'fin, hcorr', sc', hsc', himp', hpres'⟩ := h.classes d hd'
      obtain ⟨hdfin, hcorr, sc, hsc, himp, hpres⟩ := hd
      obtain ⟨hm, hs⟩ := hr.names dir d' desc d hdfin hd'fin hcorr hcorr' hdn.symm
      rw [← hs, hsc] at hsc'
      cases hsc'
      have := List.findIdx?_eq_none_iff.mp hnone d hd'
      rw [Class.same_iff.mpr ⟨hdn, hm.symm, hs.symm, himp'.trans himp.symm⟩] at this
      exact absurd this (by simp)
    · exact ⟨_, _, rfl⟩

theorem Below.finishCopy {dir : Path} {desc : Class} {cs : Classes} {i : Nat} (h : Below V w fin 0 κ)
    (hd : DescOk V w fin κ.classes dir desc) (ha : addClass desc κ.classes = .ok (i, cs)) :
    Below V w fin 0 (κ.finishCopy dir cs i) ∧ (∀ T, Loading' (κ.finishCopy dir cs i) T → T ≠ .copy dir ∧ Loading' κ T) ∧
      κ.classes.list <+: cs.list ∧ ∃ c, cs.list[i]? = some c ∧ Corr V dir c := by
  obtain ⟨hcp, c, hci, hn, hm, hsch, himps⟩ := addClass_same ha
  obtain ⟨hdfin, hcorr, sc, hsc, himp, hpres⟩ := hd
  have hcc : Corr V dir c := by
    rcases addClass_cases ha with ⟨rfl, -⟩ | ⟨hl', rfl⟩
    · obtain ⟨d', -, hd', -⟩ := h.classes c (List.mem_of_getElem? hci)
      exact Corr.of_same hcorr hd' hn hm hsch
    · rw [hl'] at hci; simp at hci; subst hci; exact hcorr
  have hmem : ∀ c' ∈ cs.list, c' ∈ κ.classes.list ∨ c' = desc := by
    intro c' hc'
    rcases addClass_cases ha with ⟨rfl, -⟩ | ⟨hl', rfl⟩
    · exact Or.inl hc'
    · rw [hl'] at hc'
      rcases List.mem_append.mp hc' with h' | h'
      · exact Or.inl h'
      · simp at h'; exact Or.inr h'
  refine ⟨⟨fun T hT => ?_, ?_, ?_, h.files, fun d' k hk => ?_, fun c' hc' => ?_⟩, fun T hT => ?_, hcp, c, hci, hcc⟩
  · rw [startedOf_finishCopy] at hT; exact h.started T hT
  · rw [startedOf_finishCopy]; exact h.nodup
  · rw [startedOf_finishCopy]; exact h.count
  · by_cases e : d' = dir
    · subst e
      simp only [Core.finishCopy, lookup_cons_self, Option.some.injEq, Loading.done.injEq] at hk
      subst hk; exact ⟨c, hci, hcc⟩
    · obtain ⟨c', h2, h3⟩ := h.copies d' k (by simpa [Core.finishCopy, lookup_cons_of_ne _ _ e] using hk)
      exact ⟨c', prefix_getElem? hcp h2, h3⟩
  · show ∃ d, .copy d ∈ fin ∧ Corr V d c' ∧ ∃ sc, decodeV c'.schema = some sc ∧
      c'.imports = (w.order sc.imports).filterMap (clsOf cs) ∧ Present cs sc.imports
    rcases hmem c' hc' with h' | rfl
    · obtain ⟨d', h1, h2, sc', h3, h4, h5⟩ := h.classes c' h'
      exact ⟨d', h1, h2, sc', h3, h4.trans (filterMap_clsOf_mono h5 hcp fun x hx =>
        (w.perm _).mem_iff.mp hx).symm, h5.mono hcp⟩
    · exact ⟨dir, hdfin, hcorr, sc, hsc, himp.trans (filterMap_clsOf_mono hpres hcp fun x hx =>
        (w.perm _).mem_iff.mp hx).symm, hpres.mono hcp⟩
  · cases T with
    | copy d' =>
      by_cases e : d' = dir
      · subst e; simp [Loading', Core.finishCopy] at hT
      · exact ⟨fun h => e (Target.copy.inj h), by simpa [Loading', Core.finishCopy, lookup_cons_of_ne _ _ e] using hT⟩
    | file p => exact ⟨(fun h => nomatch h), hT⟩

end

section Sim
variable {env : Env} {w : Walk} {fin : List Target}

theorem Pure.atV {α : Type} {x : M α} {v : Option α} {a : α} {κ : Core} {E : St → Prop} (h : Pure env x v)
    (hv : v = some a) : Triple env (At env κ) x (fun r s => At env κ s ∧ r = a) E :=
  Pure.atB (hv ▸ h)

/-- What `resolveImport` gives in the run in another order: the class with the package's name. -/
def ImpRes (κ : Core) (imp : Import) (r : Option Nat) : Prop :=
  match imp.module with
  | .pkg n _ => ∃ j c, r = some j ∧ κ.classes.list[j]? = some c ∧ c.name = n
  | _ => r = none

/-- A `load` that simulates the reference below the rank `r0`. -/
def LoadSim (env : Env) (w : Walk) (fin : List Target) (r0 : Nat) (loadFn : Target → M Loaded) : Prop :=
  ∀ T κ, T ∈ fin → fin.idxOf T < r0 → Below env.view w fin 0 κ → (∀ T', Loading' κ T' → fin.idxOf T < fin.idxOf T') →
    Triple env (At env κ) (loadFn T)
      (fun r s => Tr env.view s ∧ Below env.view w fin 0 s.core ∧ Frame κ s.core ∧ RetB env.view T r s.core)
      (fun _ => False)

theorem candV_ne_nil {V : View} {importer : Importer} {name : String} {cands : List (Path × String)}
    (h : candV V importer name = some cands) : cands ≠ [] := by
  unfold candV at h
  dsimp only at h
  split at h
  · rename_i hne
    cases h
    intro e
    simp only [List.map_eq_nil_iff] at e
    simp [e] at hne
  · cases e : (if (!V.mode.npm) = true then some []
      else (declaredV V importer).bind fun x => if name ∈ x.1 then
        (npmFind V.tree name (walk V.worldWritable importer.dir name)).toOption.map fun r =>
          r.toList.map fun d => (d, showPath d)
      else if ((V.given.filter fun g => !g.byDir && g.name == name).map fun g => (g.dir, g.shown)).isEmpty = true
        then none else some []) with
    | none => rw [e] at h; cases h
    | some f =>
      rw [e] at h
      simp only [Option.bind_some] at h
      split at h
      · cases h
      · rename_i hne; cases h; intro e'; exact hne (by rw [e']; rfl)

theorem resolveImport_sim {loadFn : Target → M Loaded} {importer : Importer} {imp : Import} {r0 : Nat} {κ : Core}
    (hload : LoadSim env w fin r0 loadFn) (himp : ImpOk env.view (fun T' => T' ∈ fin ∧ fin.idxOf T' < r0) importer imp)
    (hb : Below env.view w fin 0 κ) (hl : ∀ T', Loading' κ T' → r0 ≤ fin.idxOf T') :
    Triple env (At env κ) (resolveImport loadFn importer imp)
      (fun r s => Tr env.view s ∧ Below env.view w fin 0 s.core ∧ Frame κ s.core ∧ ImpRes s.core imp r)
      (fun _ => False) := by
  unfold resolveImport
  unfold ImpOk at himp
  split
  · rename_i nm heq
    exact Triple.pure fun s hs => ⟨hs.1, hs.2 ▸ hb, hs.2 ▸ Frame.refl κ, by unfold ImpRes; rw [heq]⟩
  · rename_i path heq
    rw [heq] at himp
    split
    · exact himp.elim
    rename_i p
    obtain ⟨real, hres, hin, hend, hkind, hP, ts, hts, hn⟩ := himp
    apply Triple.bind_ask
    apply Triple.bind_look
    split
    · rename_i e he
      exact absurd (he.symm.trans hres) (fun h => by cases h)
    rename_i real' hreal
    have : real' = real := by have := hreal.symm.trans hres; cases this; rfl
    subst this
    apply Triple.bind_look
    dsimp only
    split
    · rename_i d hd
      exact absurd (hd.symm.trans hin) (fun h => by cases h)
    split
    · rename_i hend'; simp [hend] at hend'
    apply Triple.bind_look
    split
    · rename_i hk; simp only [Env.view_tree] at hkind; simp [hkind] at hk
    refine Triple.bind (hload _ κ hP.1 hP.2 hb fun T' h => Nat.lt_of_lt_of_le hP.2 (hl T' h)) fun r => ?_
    refine Triple.intro_core (fun s₀ hs₀ => ?_) (fun _ h => h.1)
    obtain ⟨-, hb', hf', hret⟩ := hs₀
    generalize s₀.core = κ' at *
    have ht : r.types = ts := by rw [hret.1] at hts; cases hts; rfl
    refine Triple.bind (Pure.atV Pure.checkNames (by rw [ht, if_pos' hn])) fun _ => ?_
    exact Triple.pure fun s hs => ⟨hs.1.1, hs.1.2 ▸ hb', hs.1.2 ▸ hf', by unfold ImpRes; rw [heq]⟩
  · rename_i name major heq
    rw [heq] at himp
    obtain ⟨cands, hc, hcands⟩ := himp
    refine Triple.bind (Pure.atV Pure.candidates hc) fun cands' => Triple.pre_and fun e => ?_
    subst cands'
    dsimp only
    refine Triple.bind (Triple.mono (Triple.forIn (b := none) (fun rest b s => Tr env.view s ∧
      (Below env.view w fin 0 s.core ∧ Frame κ s.core ∧ ∃ pre, pre ++ rest = cands ∧
        ((pre = [] ∧ b = none) ∨ ∃ j c, b = some j ∧ s.core.classes.list[j]? = some c ∧ c.name = name))) ?_
        fun _ _ h => h)
      (fun s hs => ⟨hs.1, by rw [hs.2]; exact ⟨hb, Frame.refl κ, [], rfl, Or.inl ⟨rfl, rfl⟩⟩⟩)
      (fun _ _ h => h) (fun _ h => h)) fun r => ?_
    · intro c rest b hsuf
      refine Triple.intro_core (fun s₀ hs₀ => ?_) (fun _ h => h.1)
      obtain ⟨-, hb', hf', pre, hpre, hcls⟩ := hs₀
      generalize s₀.core = κ' at *
      obtain ⟨dir, shown⟩ := c
      obtain ⟨m, hm, hmn, hmaj, hP, ts, hts, hn⟩ := hcands (dir, shown) (hpre ▸ by simp)
      dsimp only
      refine Triple.bind (Pure.atV Pure.manifestOf hm) fun mo => Triple.pre_and fun e => ?_
      subst e
      dsimp only
      split
      · rename_i hne; simp [hmn] at hne
      have tail : ∀ {Q : ForInStep (Option Nat) → St → Prop},
          (∀ b' s, (Tr env.view s ∧ (Below env.view w fin 0 s.core ∧ Frame κ s.core ∧ ∃ pre, pre ++ rest = cands ∧
            ((pre = [] ∧ b' = none) ∨ ∃ j c, b' = some j ∧ s.core.classes.list[j]? = some c ∧ c.name = name))) →
            Q (.yield b') s) →
          Triple env (At env κ') (do
            let r ← loadFn (Target.copy dir)
            if b.isNone = true then do
                checkNames imp r.types name
                pure (ForInStep.yield r.cls)
              else do
                checkNames imp r.types name
                pure (ForInStep.yield b)) Q (fun _ => False) := by
        intro Q hQ
        refine Triple.bind (hload _ κ' hP.1 hP.2 hb' fun T' h => Nat.lt_of_lt_of_le hP.2 (hl T' (hf'.loading T' h)))
          fun r => ?_
        refine Triple.intro_core (fun s₁ hs₁ => ?_) (fun _ h => h.1)
        obtain ⟨-, hb'', hf'', hret⟩ := hs₁
        generalize s₁.core = κ'' at *
        have ht : r.types = ts := by rw [hret.1] at hts; cases hts; rfl
        obtain ⟨k, cl, hk, hcl, hcorr⟩ := hret.2 dir rfl
        have hcln : cl.name = name := by obtain ⟨m', _, _, h1, _, _, h4, _⟩ := hcorr; rw [hm] at h1; cases h1; rw [h4, hmn]
        have post : ∀ (b' : Option Nat) s, At env κ'' s →
            ((pre ++ [(dir, shown)] = [] ∧ b' = none) ∨ ∃ j c, b' = some j ∧ κ''.classes.list[j]? = some c ∧
              c.name = name) → Q (.yield b') s := by
          intro b' s hs hb2
          refine hQ b' s ⟨hs.1, ?_⟩
          rw [hs.2]
          exact ⟨hb'', hf'.trans hf'', pre ++ [(dir, shown)], by rw [← hpre]; simp, hb2⟩
        split
        · exact Triple.bind (Pure.atV Pure.checkNames (by rw [ht, if_pos' hn])) fun _ =>
            Triple.pure fun s hs => post _ s hs.1 (Or.inr ⟨k, cl, hk, hcl, hcln⟩)
        · rename_i hbn
          refine Triple.bind (Pure.atV Pure.checkNames (by rw [ht, if_pos' hn])) fun _ =>
            Triple.pure fun s hs => post _ s hs.1 (Or.inr ?_)
          rcases hcls with ⟨-, rfl⟩ | ⟨j, c, rfl, hj, hjn⟩
          · simp at hbn
          · exact ⟨j, c, rfl, prefix_getElem? hf''.classes hj, hjn⟩
      cases major with
      | none => dsimp only; exact tail fun _ _ h => h
      | some n =>
        dsimp only
        split
        · rename_i hne; simp [hmaj n rfl] at hne
        · exact tail fun _ _ h => h
    · refine Triple.pure fun s ⟨h1, hb', hf', pre, hpre, hcls⟩ => ⟨h1, hb', hf', ?_⟩
      rw [List.append_nil] at hpre
      unfold ImpRes; rw [heq]
      rcases hcls with ⟨rfl, -⟩ | h
      · exact (candV_ne_nil hc hpre.symm).elim
      · exact h

theorem Below.count_lt {V : View} {κ : Core} (h : Below V w fin 1 κ) (hr : Ref V fin) :
    κ.count + 1 ≤ V.limits.files := by
  have h1 := h.count
  have h2 := h.nodup.length_le_of_subset fun T hT => h.started T hT
  have h3 := hr.len
  omega

theorem LoadSim.mono {r0 r1 : Nat} {loadFn : Target → M Loaded} (h : LoadSim env w fin r0 loadFn) (hle : r1 ≤ r0) :
    LoadSim env w fin r1 loadFn :=
  fun T κ hT hi hb hl => h T κ hT (Nat.lt_of_lt_of_le hi hle) hb hl

theorem clsOf_of_res {κ : Core} {imp : Import} {r : Option Nat} (h : ImpRes κ imp r) :
    (clsOf κ.classes imp).toList = r.toList ∧ Present κ.classes [imp] := by
  obtain ⟨mod, names⟩ := imp
  unfold ImpRes at h
  unfold clsOf Present
  cases mod with
  | pkg n mj =>
    obtain ⟨j, c, rfl, hj, hn⟩ := h
    refine ⟨?_, fun imp' hi n' mj' hm' => ?_⟩
    · dsimp only
      rw [← hn, findIdx?_name κ.classes.distinct hj]
    · simp at hi; subst hi; cases hm'; exact ⟨c, List.mem_of_getElem? hj, hn⟩
  | std nm =>
    subst h
    exact ⟨rfl, fun imp' hi n' mj' hm' => by simp at hi; subst hi; cases hm'⟩
  | file path =>
    subst h
    exact ⟨rfl, fun imp' hi n' mj' hm' => by simp at hi; subst hi; cases hm'⟩

theorem load_sim (hr : Ref env.view fin) : ∀ n, LoadSim env w fin n (load w n)
  | 0 => fun _ _ _ hi => absurd hi (Nat.not_lt_zero _)
  | n + 1 => fun T κ hT hi hb hl => by
    have hloc := hr.local_ T hT
    cases T with
    | file p =>
      obtain ⟨bs, sc, hbs, hsc, himps⟩ := hloc
      unfold load
      apply Triple.bind_getCore; intro s₀ hc _
      rw [show s₀.files = κ.files from congrArg Core.files hc]
      dsimp only
      split
      · rename_i ts hts
        exact Triple.pure fun s hs => ⟨hs.1, hs.2 ▸ hb, hs.2 ▸ Frame.refl κ, hs.2 ▸ ⟨hb.files p ts hts, (fun d h => nomatch h)⟩⟩
      · rename_i hts
        exact absurd (hl (.file p) hts) (Nat.lt_irrefl _)
      rename_i hnone
      obtain ⟨hb1, hl1⟩ := hb.markFile hnone hT
      refine modify_at (κ' := κ.markFile p) (fun s => ?_) (fun s => ⟨rfl, rfl⟩) ?_
      · by_cases e : s.core = κ
        · left; rw [← e]; rfl
        · right; exact e
      apply Triple.bind_cfg
      refine Triple.bind (Pure.atV Pure.openFile hbs) fun bytes => Triple.pre_and fun e => ?_
      subst bytes
      refine Triple.bind (countFile_atB (hb1.count_lt hr)) fun _ => ?_
      have hb2 := hb1.countUp
      refine Triple.bind (Pure.atV Pure.decodeScan hsc) fun sc' => Triple.pre_and fun e => ?_
      subst sc'
      refine Triple.bind (Pure.atV Pure.noteImports rfl) fun _ => Triple.pre_and fun _ => ?_
      refine Triple.bind (Triple.mono (Triple.forIn (b := PUnit.unit) (fun rest _ s => Tr env.view s ∧
        (Below env.view w fin 0 s.core ∧ Frame (κ.markFile p).countUp s.core)) ?_ fun _ _ h => h)
        (fun s hs => ⟨hs.1, by rw [hs.2]; exact ⟨hb2, Frame.refl _⟩⟩)
        (fun _ _ h => h) (fun _ h => h)) fun _ => ?_
      · intro imp rest b hsuf
        refine Triple.intro_core (fun s₀ hs₀ => ?_) (fun _ h => h.1)
        obtain ⟨-, hb', hf'⟩ := hs₀
        generalize s₀.core = κ' at *
        have hmem : imp ∈ sc.imports := (w.perm _).mem_iff.mp (hsuf.subset List.mem_cons_self)
        refine Triple.bind (resolveImport_sim (r0 := fin.idxOf (.file p))
          ((load_sim hr n).mono (by omega)) ((himps imp hmem).mono fun _ h => ⟨h.1, h.2⟩) hb' fun T' h => ?_) fun _ => ?_
        · rcases hl1 T' (hf'.loading T' h) with rfl | h'
          · exact Nat.le_refl _
          · exact Nat.le_of_lt (hl T' h')
        exact Triple.pure fun s h => ⟨h.1, h.2.1, hf'.trans h.2.2.1⟩
      · refine Triple.intro_core (fun s₀ hs₀ => ?_) (fun _ h => h.1)
        obtain ⟨-, hb', hf'⟩ := hs₀
        generalize s₀.core = κ' at *
        have hts := typesV_file (V := env.view) hbs hsc
        obtain ⟨hb3, hl3⟩ := hb'.finishFile hts
        refine modify_at (κ' := κ'.finishFile p sc.types) (fun s => ?_) (fun s => ⟨rfl, rfl⟩) ?_
        · by_cases e : s.core = κ'
          · left; rw [← e]; rfl
          · right; exact e
        refine Triple.pure fun s hs => ⟨hs.1, hs.2 ▸ hb3, hs.2 ▸ ⟨hf'.classes, fun T h => ?_, fun T h => ?_⟩,
          hs.2 ▸ ⟨hts, (fun d h => nomatch h)⟩⟩
        · rw [startedOf_finishFile]
          exact hf'.started T (by rw [startedOf_countUp, startedOf_markFile]; exact List.mem_cons_of_mem _ h)
        · obtain ⟨hne, h'⟩ := hl3 T h
          rcases hl1 T (hf'.loading T h') with rfl | h''
          · exact absurd rfl hne
          · exact h''
    | copy dir =>
      obtain ⟨m, npm, bytes, sc, hm, hnpm, hver, hbo, hsc, hnf, himps⟩ := hloc
      unfold load
      apply Triple.bind_getCore; intro s₀ hc _
      rw [show s₀.copies = κ.copies from congrArg Core.copies hc]
      split
      · rename_i k hk
        apply Triple.bind_getCore; intro s₁ hc1 _
        rw [show s₁.classes = κ.classes from congrArg Core.classes hc1]
        obtain ⟨cl, hcl, hcorr⟩ := hb.copies dir k hk
        refine Triple.pure fun s hs => ⟨hs.1, hs.2 ▸ hb, hs.2 ▸ Frame.refl κ, ?_⟩
        rw [hs.2]
        have hcl' : κ.classes.list[k]! = cl := getElem!_of_some hcl
        obtain ⟨m', bs', sc', h1, h2, h3, h4, h5, h6, h7, h8⟩ := hcorr
        refine ⟨?_, fun d hd => ?_⟩
        · show typesV env.view (.copy dir) = some κ.classes.list[k]!.types
          rw [hcl', h8]; simp [typesV, h2, h3]
        · cases hd; exact ⟨k, cl, rfl, hcl, m', bs', sc', h1, h2, h3, h4, h5, h6, h7, h8⟩
      · rename_i hk; exact absurd (hl (.copy dir) hk) (Nat.lt_irrefl _)
      rename_i hnone
      obtain ⟨hb1, hl1⟩ := hb.markCopy hnone hT
      refine modify_at (κ' := κ.markCopy dir) (fun s => ?_) (fun s => ⟨rfl, rfl⟩) ?_
      · by_cases e : s.core = κ
        · left; rw [← e]; rfl
        · right; exact e
      apply Triple.bind_cfg
      refine Triple.bind (Pure.atV Pure.manifestOf hm) fun mo => Triple.pre_and fun e => ?_
      subst e
      dsimp only
      refine Triple.bind (Pure.atV Pure.copyNpm hnpm) fun npm' => Triple.pre_and fun e => ?_
      subst npm'
      refine Triple.bind (checkVersion_atB hver) fun _ => ?_
      refine Triple.bind (Pure.atV Pure.openPackageFile hbo) fun bo => Triple.pre_and fun e => ?_
      subst e
      dsimp only
      refine Triple.bind (countFile_atB (hb1.count_lt hr)) fun _ => ?_
      have hb2 := hb1.countUp
      refine Triple.bind (Pure.atV Pure.decodeScan hsc) fun sc' => Triple.pre_and fun e => ?_
      subst sc'
      refine Triple.bind (Pure.atV Pure.noteImports rfl) fun _ => Triple.pre_and fun _ => ?_
      refine Triple.bind (checkNoFiles_atB hnf) fun _ => ?_
      refine Triple.bind (Triple.mono (Triple.forIn (b := []) (fun rest b s => Tr env.view s ∧
        (Below env.view w fin 0 s.core ∧ Frame (κ.markCopy dir).countUp s.core ∧
          ∃ pre, pre ++ rest = w.order sc.imports ∧ b = pre.filterMap (clsOf s.core.classes) ∧
            Present s.core.classes pre)) ?_ fun _ _ h => h)
        (fun s hs => ⟨hs.1, by rw [hs.2]; exact ⟨hb2, Frame.refl _, [], rfl, rfl, fun _ h => nomatch h⟩⟩)
        (fun _ _ h => h) (fun _ h => h)) fun targets => ?_
      · intro imp rest b hsuf
        refine Triple.intro_core (fun s₀ hs₀ => ?_) (fun _ h => h.1)
        obtain ⟨-, hb', hf', pre, hpre, hbe, hpres⟩ := hs₀
        generalize s₀.core = κ' at *
        have hmem : imp ∈ sc.imports := (w.perm _).mem_iff.mp (hsuf.subset List.mem_cons_self)
        refine Triple.bind (resolveImport_sim (r0 := fin.idxOf (.copy dir))
          ((load_sim hr n).mono (by omega)) ((himps imp hmem).mono fun _ h => ⟨h.1, h.2⟩) hb' fun T' h => ?_)
          fun r => ?_
        · rcases hl1 T' (hf'.loading T' h) with rfl | h'
          · exact Nat.le_refl _
          · exact Nat.le_of_lt (hl T' h')
        refine Triple.intro_core (fun s₁ hs₁ => ?_) (fun _ h => h.1)
        obtain ⟨-, hb'', hf'', hres⟩ := hs₁
        generalize s₁.core = κ'' at *
        obtain ⟨hcl, hpi⟩ := clsOf_of_res hres
        have hbe' : b = pre.filterMap (clsOf κ''.classes) :=
          hbe.trans (filterMap_clsOf_mono hpres hf''.classes fun _ h => h).symm
        have post : ∀ s, At env κ'' s → Tr env.view s ∧ (Below env.view w fin 0 s.core ∧
            Frame (κ.markCopy dir).countUp s.core ∧ ∃ pre', pre' ++ rest = w.order sc.imports ∧
              b ++ r.toList = pre'.filterMap (clsOf s.core.classes) ∧ Present s.core.classes pre') := by
          intro s hs
          refine ⟨hs.1, ?_⟩
          rw [hs.2]
          refine ⟨hb'', hf'.trans hf'', pre ++ [imp], by rw [← hpre]; simp, ?_, fun i hi => ?_⟩
          · rw [List.filterMap_append, ← hbe', ← hcl]
            simp only [List.filterMap_cons, List.filterMap_nil]
            cases clsOf κ''.classes imp <;> rfl
          · rcases List.mem_append.mp hi with hi | hi
            · exact (hpres.mono hf''.classes) i hi
            · exact hpi i hi
        split
        · exact Triple.pure fun s hs => post s hs
        · rename_i hr'
          refine Triple.pure fun s hs => ?_
          have := post s hs
          cases r with
          | none => simpa using this
          | some c => exact absurd rfl (hr' c)
      · refine Triple.intro_core (fun s₀ hs₀ => ?_) (fun _ h => h.1)
        obtain ⟨-, hb', hf', pre, hpre, hbe, hpres⟩ := hs₀
        generalize s₀.core = κ' at *
        rw [List.append_nil] at hpre
        subst hpre
        have hdesc : DescOk env.view w fin κ'.classes dir
            (Class.mk m.name m.version m.bytes bytes targets sc.types dir) :=
          ⟨hT, ⟨m, bytes, sc, hm, hbo, hsc, rfl, rfl, rfl, rfl, rfl⟩, sc, hsc, hbe,
            fun i hi => hpres i ((w.perm _).mem_iff.mpr hi)⟩
        obtain ⟨i, cs, ha⟩ := hb'.addClass_ok hr hdesc
        refine Triple.bind (Triple.mono classify_at (fun _ h => h) (fun _ _ h => h)
          (fun _ h => by rw [ha] at h; cases h)) fun i' => ?_
        refine Triple.bind_modify (fun s => Tr env.view s ∧ ∃ cs, addClass _ κ'.classes = .ok (i', cs) ∧
          s.core = κ'.finishCopy dir cs i') (fun s ⟨h1, cs, ha, h2⟩ => ⟨⟨h1.manifests, h1.npm⟩, cs, ha, ?_⟩) ?_
        · obtain ⟨e1, e2, e3, e4, e5⟩ := Core.mk.inj (h2 : (⟨s.files, s.copies, s.classes, s.count, s.finished⟩ : Core) =
            ⟨κ'.files, κ'.copies, cs, κ'.count, κ'.finished⟩)
          simp only [St.core, Core.finishCopy, e1, e2, e3, e4, e5]
        refine Triple.pure fun s ⟨h1, cs', ha', h2⟩ => ?_
        obtain ⟨hb3, hl3, hcp, c, hci, hcc⟩ := hb'.finishCopy hdesc ha'
        refine ⟨h1, h2 ▸ hb3, h2 ▸ ⟨hf'.classes.trans hcp, fun T h => ?_, fun T h => ?_⟩, h2 ▸ ?_⟩
        · rw [startedOf_finishCopy]
          exact hf'.started T (by rw [startedOf_countUp]; exact mem_startedOf_markCopy.mpr (Or.inr h))
        · obtain ⟨hne, h'⟩ := hl3 T h
          rcases hl1 T (hf'.loading T h') with rfl | h''
          · exact absurd rfl hne
          · exact h''
        · exact ⟨by simp [typesV, hbo, hsc], fun d hd => by cases hd; exact ⟨i', c, rfl, hci, hcc⟩⟩

end Sim

/-! ## Two whole runs -/

/-- The core of the state a run starts from. -/
def Core.empty : Core := ⟨[], [], .empty, 0, []⟩

theorem Good.empty {V : View} : Good V 0 Core.empty :=
  ⟨List.nodup_nil, (fun _ h => nomatch h), by simp [startedOf, Core.empty], (fun _ h => nomatch h),
    fun _ _ h => by simp [Core.empty] at h, fun _ _ h => by simp [Core.empty] at h, (fun _ h => nomatch h),
    fun _ h => by simp [Core.empty, Classes.empty] at h⟩

theorem Below.empty {V : View} {w : Walk} {fin : List Target} : Below V w fin 0 Core.empty :=
  ⟨fun _ h => by simp [startedOf, Core.empty] at h, by simp [startedOf, Core.empty], by simp [Core.empty],
    fun _ _ h => by simp [Core.empty] at h, fun _ _ h => by simp [Core.empty] at h,
    fun _ h => by simp [Core.empty, Classes.empty] at h⟩

theorem Tr.of_view {V V' : View} {s : St} (h : Tr V s) (ht : V'.tree = V.tree) (hl : V'.limits = V.limits) :
    Tr V' s :=
  ⟨fun d m hm => by unfold manifestV; rw [ht, hl]; exact h.manifests d m hm,
    fun p r hp => by rw [ht, hl]; exact h.npm p r hp⟩

/-- Every package of `S'` is one of `S`, with the same version. -/
def ClassesIn (S' S : St) : Prop :=
  ∀ c ∈ S'.classes.list, ∃ c' ∈ S.classes.list, c'.name = c.name ∧ c'.version = c.version

theorem Good.ref {V : View} {S : St} (h : Good V 0 S.core) (hc : S.count ≤ V.limits.files) : Ref V S.finished := by
  refine ⟨h.nodup, h.local_, ?_, fun d d' c c' hd hd' hcd hcd' hn => ?_⟩
  · have h1 := h.nodup.length_le_of_subset fun T hT => h.started T hT
    have h2 := h.count
    simp only [St.core] at h1 h2
    omega
  · obtain ⟨cS, hcS, hS⟩ := h.finCls d hd
    obtain ⟨cS', hcS', hS'⟩ := h.finCls d' hd'
    obtain ⟨n1, -, m1, s1, -⟩ := Corr.unique hcd hS
    obtain ⟨n2, -, m2, s2, -⟩ := Corr.unique hcd' hS'
    have : cS = cS' := eq_of_nodup_map S.classes.distinct hcS hcS' (n1.symm.trans (hn.trans n2))
    subst this
    exact ⟨m1.trans m2.symm, s1.trans s2.symm⟩

/--
**The simulation** (R3): if loading `T₀` in the order `w₁` succeeds from a
state with no targets and no classes, loading it in any order `w₂` from the
same state succeeds too, and every package it makes is one of the first
run's, with the same version.
-/
theorem load_walk {env : Env} {w₁ w₂ : Walk} {T₀ : Target} {s₁ : St} {r : Loaded} {S : St}
    (htr : Tr env.view s₁) (hcore : s₁.core = Core.empty) (hcount : S.count ≤ env.config.limits.files)
    (hA : go (load w₁ (env.config.limits.files + 1) T₀) env s₁ = (.ok r, S)) :
    ∃ r' S', go (load w₂ (env.config.limits.files + 1) T₀) env s₁ = (.ok r', S') ∧ ClassesIn S' S := by
  have hA' := load_good (w := w₁) (env.config.limits.files + 1) T₀ s₁.core s₁ ⟨htr, hcore ▸ Good.empty, Grows.refl _⟩
  rw [hA] at hA'
  obtain ⟨⟨-, hgS, -⟩, hret⟩ := hA'
  have hr := hgS.ref hcount
  have hidx : S.finished.idxOf T₀ < env.config.limits.files + 1 := by
    have := List.idxOf_lt_length_iff.mpr (show T₀ ∈ S.finished from hret.1)
    have := hr.len
    simp only [Env.view_limits] at this
    omega
  have hB := load_sim (w := w₂) hr (env.config.limits.files + 1) T₀ s₁.core hret.1 hidx (hcore ▸ Below.empty)
    (fun T' h => by rw [hcore] at h; cases T' <;> simp [Loading', Core.empty] at h) s₁ ⟨htr, rfl⟩
  revert hB
  rcases go (load w₂ (env.config.limits.files + 1) T₀) env s₁ with ⟨rb, S'⟩
  cases rb with
  | error e => exact False.elim
  | ok r' =>
    rintro ⟨-, hbS', -, -⟩
    refine ⟨r', S', rfl, fun c hc => ?_⟩
    obtain ⟨d, hd, hcd, -⟩ := hbS'.classes c hc
    obtain ⟨cS, hcS, hS⟩ := hgS.finCls d hd
    obtain ⟨n1, v1, -⟩ := Corr.unique hcd hS
    exact ⟨cS, hcS, n1.symm, v1.symm⟩

theorem count_le_walk (t : Tree) (c : Config) (root : Path) (w : Walk) :
    (runIn t c root w).2.count ≤ c.limits.files :=
  (Triple.final (main_spec (w := w)) (s := {}) (env := { tree := t, config := c })
    ⟨⟨List.nodup_nil, by simp, by simp, Nat.zero_le _, Nat.le_refl _, Nat.le_refl _⟩, Nat.le_refl _⟩).1.count

theorem runIn_walk {t : Tree} {c : Config} {root : Path} {w₁ w₂ : Walk} (h : (runIn t c root w₁).1 = .ok ()) :
    (runIn t c root w₂).1 = .ok () ∧ ClassesIn (runIn t c root w₂).2 (runIn t c root w₁).2 := by
  have hc1 := count_le_walk t c root w₁
  unfold runIn main at *
  simp only [go_bind] at h hc1 ⊢
  have hgiven := givenPackages_at (env := { tree := t, config := c }) (κ := ({} : St).core) {} ⟨Tr.empty, rfl⟩
  rcases hg : go givenPackages { tree := t, config := c } {} with ⟨rg, s₁⟩
  rw [hg] at hgiven
  try rw [hg] at h
  try rw [hg] at hc1
  try rw [hg]
  cases rg with
  | error e => simp at h
  | ok gb =>
    obtain ⟨g, b⟩ := gb
    simp only [go_withReader, go_bind, go_look] at h hc1 ⊢
    rcases hreal : t.realPath root with e | real
    · simp [hreal, go_bind, go_fail] at h
    simp only [hreal, go_pure, go_bind, go_look] at h hc1 ⊢
    by_cases hk : (t.kindAt? real != some Kind.file) = true
    · simp [hk, go_bind, go_fail] at h
    simp only [hk, Bool.false_eq_true, ↓reduceIte, go_bind, go_cfg] at h hc1 ⊢
    have hbs := baseOf_spec (env := { tree := t, config := c, given := g, broken := b }) (root := root) (real := real)
      (P := fun s => s = s₁) s₁ rfl
    rcases hbase : go (baseOf root real) { tree := t, config := c, given := g, broken := b } s₁ with ⟨rb, sb⟩
    rw [hbase] at hbs
    try rw [hbase] at h
    try rw [hbase] at hc1
    try rw [hbase]
    cases rb with
    | error e => simp at h
    | ok base =>
      simp only at hbs
      subst hbs
      simp only [go_withReader, go_pure] at h hc1 ⊢
      rcases hl : go (load w₁ (c.limits.files + 1) (.file real))
          { tree := t, config := c, given := g, broken := b, base } sb with ⟨rl, S⟩
      try rw [hl] at h
      try rw [hl] at hc1
      cases rl with
      | error e => simp at h
      | ok r =>
        try simp only at hc1
        obtain ⟨htr, hcore⟩ := hgiven
        obtain ⟨r', S', hB, hin⟩ := load_walk (env := { tree := t, config := c, given := g, broken := b, base })
          (w₂ := w₂) (Tr.of_view htr rfl rfl) hcore hc1 hl
        rw [hB]
        exact ⟨rfl, hin⟩

theorem nodup_pairs : ∀ {l : List Class}, (l.map (·.name)).Nodup → (l.map fun c => (c.name, c.version)).Nodup
  | [], _ => List.nodup_nil
  | x :: xs, h => by
    rw [List.map_cons, List.nodup_cons] at h ⊢
    refine ⟨fun hm => h.1 ?_, nodup_pairs h.2⟩
    obtain ⟨y, hy, e⟩ := List.mem_map.mp hm
    simp only [Prod.mk.injEq] at e
    exact List.mem_map.mpr ⟨y, hy, e.1⟩

/-- Two lists of classes with distinct names and the same packages give the same `packagesOf`. -/
theorem packagesOf_eq {l₁ l₂ : List Class} (h₁ : (l₁.map (·.name)).Nodup) (h₂ : (l₂.map (·.name)).Nodup)
    (h₁₂ : ∀ c ∈ l₁, ∃ c' ∈ l₂, c'.name = c.name ∧ c'.version = c.version)
    (h₂₁ : ∀ c ∈ l₂, ∃ c' ∈ l₁, c'.name = c.name ∧ c'.version = c.version) :
    packagesOf l₁ = packagesOf l₂ := by
  have hp : List.Perm (l₁.map fun c => (c.name, c.version)) (l₂.map fun c => (c.name, c.version)) := by
    refine (List.perm_ext_iff_of_nodup (nodup_pairs h₁) (nodup_pairs h₂)).mpr fun ⟨n, v⟩ => ?_
    simp only [List.mem_map, Prod.mk.injEq]
    constructor
    · rintro ⟨c, hc, rfl, rfl⟩
      obtain ⟨c', hc', e1, e2⟩ := h₁₂ c hc
      exact ⟨c', hc', e1, e2⟩
    · rintro ⟨c, hc, rfl, rfl⟩
      obtain ⟨c', hc', e1, e2⟩ := h₂₁ c hc
      exact ⟨c', hc', e1, e2⟩
  have e : ∀ l : List Class, l.map (fun c => c.name ++ "@" ++ c.version) =
      (l.map fun c => (c.name, c.version)).map fun p => p.1 ++ "@" ++ p.2 := by
    intro l; simp [List.map_map]
  unfold packagesOf
  rw [e, e]
  have hq := hp.map (fun p : String × String => p.1 ++ "@" ++ p.2)
  generalize ((l₁.map fun c => (c.name, c.version)).map fun p => p.1 ++ "@" ++ p.2) = A at hq
  generalize ((l₂.map fun c => (c.name, c.version)).map fun p => p.1 ++ "@" ++ p.2) = B at hq
  have trans : ∀ a b c : String, decide (a ≤ b) = true → decide (b ≤ c) = true → decide (a ≤ c) = true := by
    intro a b c h1 h2; simp only [decide_eq_true_eq] at *; exact String.le_trans h1 h2
  have total : ∀ a b : String, (decide (a ≤ b) || decide (b ≤ a)) = true := by
    intro a b; rcases String.le_total a b with h | h <;> simp [h]
  refine List.Perm.eq_of_pairwise (le := fun a b => decide (a ≤ b) = true) (fun a b _ _ h1 h2 => ?_)
    (List.pairwise_mergeSort trans total A) (List.pairwise_mergeSort trans total B)
    (((List.mergeSort_perm A _).trans hq).trans (List.mergeSort_perm B _).symm)
  simp only [decide_eq_true_eq] at h1 h2
  exact String.le_antisymm h1 h2

theorem resolveIn_runIn' (t : Tree) (c : Config) (root : Path) (w : Walk) :
    resolveIn t c root w = Outcome.of (runIn t c root w) := rfl

theorem runIn_ok_of {t : Tree} {c : Config} {root : Path} {w : Walk} {ps : List String}
    (h : (resolveIn t c root w).result = .ok ps) :
    (runIn t c root w).1 = .ok () ∧ ps = packagesOf (runIn t c root w).2.classes.list := by
  rw [resolveIn_runIn'] at h
  revert h
  unfold Outcome.of
  rcases runIn t c root w with ⟨r, S⟩
  cases r with
  | error e => intro h; cases h
  | ok u => intro h; cases u; simp [Except.map] at h; exact ⟨rfl, h.symm⟩

/--
**Order independence** (R3, security review F4): the result of a successful
run is the same whatever order the imports of each file are walked in.
With `resolveIn_walk_error`, success or failure doesn't depend on the order
either; which error is reported may (`Haus.Packages.Order`, `twoMistakes`).
-/
theorem resolveIn_walk {t : Tree} {c : Config} {root : Path} {w₁ w₂ : Walk} {ps : List String}
    (h : (resolveIn t c root w₁).result = .ok ps) : (resolveIn t c root w₂).result = .ok ps := by
  obtain ⟨h1, rfl⟩ := runIn_ok_of h
  obtain ⟨h2, h21⟩ := runIn_walk (w₂ := w₂) h1
  obtain ⟨-, h12⟩ := runIn_walk (w₂ := w₁) h2
  rw [resolveIn_runIn']
  unfold Outcome.of
  rw [h2]
  simp only [Except.map]
  rw [packagesOf_eq (runIn t c root w₂).2.classes.distinct (runIn t c root w₁).2.classes.distinct h21 h12]

theorem resolveIn_walk_error {t : Tree} {c : Config} {root : Path} {w₁ w₂ : Walk} {e : Err}
    (h : (resolveIn t c root w₁).result = .error e) : ∃ e', (resolveIn t c root w₂).result = .error e' := by
  cases h2 : (resolveIn t c root w₂).result with
  | error e' => exact ⟨e', rfl⟩
  | ok ps => rw [resolveIn_walk h2] at h; cases h

end Haus.Packages
