import Haus.Packages.Reads

/-!
# The classes a run makes are closed (a step of R3)

`runIn_closed`: in every state of every run, each class's imports are
classes made before it (`Closed.topo`), and every copy loaded names a class
that exists (`Closed.copies`). So the packages a run reaches, with their
imports, form a graph without cycles, in the order the run made them: a
successful run's last state is closed under imports, which is the first half
of the simulation R3 needs (`Haus.Packages.Order`).

Proven a construct at a time, like the read set (`Haus.Packages.Reads`):
`Keeps P x`, `x` keeps the predicate `P` of the state whatever it returns;
every step but `classify` and the `modify`s of `load` leaves the classes and
the copies alone.
-/

namespace Haus.Packages

/-- The number of classes made. -/
abbrev St.made (s : St) : Nat := s.classes.list.length

/-- What holds of the classes and copies of every state, with at least `L` classes made. -/
structure Closed (L : Nat) (s : St) : Prop where
  len : L ≤ s.made
  /-- A class imports only classes made before it. -/
  topo : ∀ (i : Nat) (c : Class), s.classes.list[i]? = some c → ∀ k ∈ c.imports, k < i
  /-- A copy loaded names a class that exists. -/
  copies : ∀ d k, (d, Loading.done k) ∈ s.copies → k < s.made

/-- `x` keeps `P`, whatever it returns and whether or not it fails. -/
abbrev Keeps {α} (P : St → Prop) (x : M α) : Prop := ∀ env, Triple env P x (fun _ => P) P

namespace Keeps
variable {α β γ : Type} {P : St → Prop}

theorem pure {a : α} : Keeps P (Pure.pure a : M α) := fun _ => Triple.pure fun _ h => h

theorem bind {x : M α} {f : α → M β} (hx : Keeps P x) (hf : ∀ a, Keeps P (f a)) : Keeps P (x >>= f) :=
  fun env => Triple.bind (hx env) fun a => hf a env

theorem get : Keeps P (MonadState.get : M St) := fun _ _ hs => hs

theorem read : Keeps P (MonadReader.read : M Env) := fun _ _ hs => hs

theorem modify {g : St → St} (hg : ∀ s, P s → P (g s)) : Keeps P (_root_.modify g : M Unit) :=
  fun _ => Triple.modify hg

theorem throw {e : Err} : Keeps P (MonadExcept.throw e : M α) := fun _ => Triple.throw fun _ h => h

theorem fail {c : Code} {m : String} : Keeps P (Haus.Packages.fail c m : M α) := fun _ => Triple.fail fun _ h => h

theorem look {δ} {g : Tree → δ} : Keeps P (Haus.Packages.look g) := fun _ _ hs => hs

theorem ask {δ} {f : Env → δ} : Keeps P (Haus.Packages.ask f) := fun _ _ hs => hs

theorem cfg : Keeps P Haus.Packages.cfg := fun _ _ hs => hs

theorem tryCatch {x : M α} {h : Err → M α} (hx : Keeps P x) (hh : ∀ e, Keeps P (h e)) : Keeps P (tryCatch x h) :=
  fun env => Triple.tryCatch (hx env) fun e => hh e env

theorem withReader {x : M α} {f : Env → Env} (hx : Keeps P x) : Keeps P (withReader f x) :=
  fun _ => Triple.withReader (hx _)

theorem forIn {xs : List γ} {b : β} {f : γ → β → M (ForInStep β)} (h : ∀ a b, Keeps P (f a b)) :
    Keeps P (ForIn.forIn xs b f) := fun env =>
  Triple.forIn (fun _ _ => P) (fun a _ b _ => Triple.mono (h a b env) (fun _ h => h)
    (fun r _ hs => by cases r <;> exact hs) (fun _ h => h)) fun _ _ h => h

theorem map {x : M α} {f : α → β} (hx : Keeps P x) : Keeps P (f <$> x) := fun env => Triple.map (hx env)

end Keeps

/-- A step that keeps `Closed L`: everything but the classes and the copies. -/
macro "kstep" : tactic => `(tactic| first
  | with_reducible exact Keeps.pure
  | with_reducible exact Keeps.get
  | with_reducible exact Keeps.read
  | with_reducible exact Keeps.throw
  | with_reducible exact Keeps.fail
  | with_reducible exact Keeps.cfg
  | with_reducible exact Keeps.ask
  | with_reducible exact Keeps.look
  | (with_reducible apply Keeps.modify; exact fun _ h => ⟨h.len, h.topo, h.copies⟩)
  | with_reducible refine Keeps.bind ?_ fun _ => ?_
  | with_reducible refine Keeps.forIn fun _ _ => ?_
  | with_reducible refine Keeps.tryCatch ?_ fun _ => ?_
  | with_reducible refine Keeps.map ?_
  | with_reducible refine Keeps.withReader ?_
  | split
  | dsimp only
  | exact Keeps.pure
  | refine Keeps.bind ?_ fun _ => ?_)

macro "keeps" : tactic => `(tactic| repeat kstep)

section
variable {L : Nat}

theorem Keeps.openFile {p : Path} {limit : Nat} {tl : Nat → Err} : Keeps (Closed L) (openFile p limit tl) := by
  unfold Haus.Packages.openFile; keeps

theorem Keeps.openPackageFile {dir : Path} {name : String} {limit : Nat} {code : Code} {owner : String} :
    Keeps (Closed L) (openPackageFile dir name limit code owner) := by
  unfold Haus.Packages.openPackageFile
  repeat (first | with_reducible exact Keeps.openFile | kstep)

theorem Keeps.manifestOf {dir : Path} {shown : String} : Keeps (Closed L) (manifestOf dir shown) := by
  unfold Haus.Packages.manifestOf
  repeat (first | with_reducible exact Keeps.openPackageFile | kstep)

theorem Keeps.packageJsonOf {dir : Path} {owner : String} : Keeps (Closed L) (packageJsonOf dir owner) := by
  unfold Haus.Packages.packageJsonOf
  repeat (first | with_reducible exact Keeps.openPackageFile | kstep)

theorem Keeps.copyNpm {config : Config} {dir : Path} {owner : String} : Keeps (Closed L) (copyNpm config dir owner) := by
  unfold Haus.Packages.copyNpm
  repeat (first | with_reducible exact Keeps.packageJsonOf | kstep)

theorem Keeps.checkVersion {config : Config} {m : Manifest} {npm : Option NpmInfo} {owner : String} :
    Keeps (Closed L) (checkVersion config m npm owner) := by
  unfold Haus.Packages.checkVersion; keeps

theorem Keeps.checkNoFiles {m : Manifest} {sc : Scanned} : Keeps (Closed L) (checkNoFiles m sc) := by
  unfold Haus.Packages.checkNoFiles; keeps

theorem Keeps.projectOf {p : Path} : Keeps (Closed L) (projectOf p) := by
  unfold Haus.Packages.projectOf
  repeat (first | with_reducible exact Keeps.openFile | kstep)

theorem Keeps.declared {imp : Importer} : Keeps (Closed L) (declared imp) := by
  unfold Haus.Packages.declared
  repeat (first | with_reducible exact Keeps.projectOf | kstep)

theorem Keeps.npmLookup {start : Path} {name : String} : Keeps (Closed L) (npmLookup start name) := by
  unfold Haus.Packages.npmLookup; keeps

theorem Keeps.candidates {imp : Importer} {name : String} : Keeps (Closed L) (candidates imp name) := by
  unfold Haus.Packages.candidates
  repeat (first | with_reducible exact Keeps.declared | with_reducible exact Keeps.npmLookup | kstep)

theorem Keeps.checkNames {imp : Import} {types : List String} {what : String} :
    Keeps (Closed L) (checkNames imp types what) := by
  unfold Haus.Packages.checkNames; keeps

theorem Keeps.decodeScan {bytes : List UInt8} {what : String} : Keeps (Closed L) (decodeScan bytes what) := by
  unfold Haus.Packages.decodeScan; keeps

theorem Keeps.countFile {what : String} : Keeps (Closed L) (countFile what) := by
  unfold Haus.Packages.countFile; keeps

theorem Keeps.noteImports {k : Nat} : Keeps (Closed L) (noteImports k) := by
  unfold Haus.Packages.noteImports; keeps

end

theorem Closed.lower {L N : Nat} {s : St} (h : Closed N s) (hle : L ≤ N) : Closed L s :=
  ⟨Nat.le_trans hle h.len, h.topo, h.copies⟩

theorem Closed.lift {L : Nat} {s : St} (h : Closed L s) : Closed s.made s := ⟨Nat.le_refl _, h.topo, h.copies⟩

theorem Triple.exists_pre {α δ : Type} {env : Env} {P : δ → St → Prop} {x : M α} {Q : α → St → Prop} {E : St → Prop}
    (h : ∀ a, Triple env (P a) x Q E) : Triple env (fun s => ∃ a, P a s) x Q E := by
  intro s ⟨a, hs⟩; exact h a s hs

theorem Triple.of_state {α : Type} {env : Env} {P : St → Prop} {x : M α} {Q : α → St → Prop} {E : St → Prop}
    (h : ∀ s₀, P s₀ → Triple env (fun s => s = s₀) x Q E) : Triple env P x Q E := by
  intro s hs; exact h s hs s rfl

/-- `addClass` keeps the classes, or appends the copy's own class. -/
theorem addClass_cases {c : Class} {cs cs' : Classes} {i : Nat} (h : addClass c cs = .ok (i, cs')) :
    (cs' = cs ∧ i < cs.list.length) ∨ (cs'.list = cs.list ++ [c] ∧ i = cs.list.length) := by
  unfold addClass at h
  split at h
  · rename_i j hj
    simp only [Except.ok.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    exact .inl ⟨rfl, (List.findIdx?_eq_some_iff_getElem.mp hj).1⟩
  · split at h
    · simp at h
    · simp only [Except.ok.injEq, Prod.mk.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      exact .inr ⟨rfl, rfl⟩

/-- **`classify`** gives a class that exists, and a new class imports only classes made before it. -/
theorem classify_closed {env : Env} {L : Nat} {c : Class} :
    Triple env (fun s => Closed L s ∧ ∀ k ∈ c.imports, k < s.made) (classify c)
      (fun i s => Closed L s ∧ i < s.made) (Closed L) := by
  intro s ⟨hs, hi⟩
  cases ha : addClass c s.classes with
  | error e =>
    have : go (classify c) env s = (.error e, s) := by simp only [classify, go_bind, go_get, ha, go_throw]
    rw [this]; exact hs
  | ok p =>
    obtain ⟨i, cs⟩ := p
    have : go (classify c) env s = (.ok i, { s with classes := cs }) := by
      simp only [classify, go_bind, go_get, ha, go_modify, go_pure]
    rw [this]
    rcases addClass_cases ha with ⟨rfl, hlt⟩ | ⟨hl, rfl⟩
    · exact ⟨⟨hs.len, hs.topo, hs.copies⟩, hlt⟩
    · refine ⟨⟨?_, ?_, ?_⟩, ?_⟩
      · show L ≤ cs.list.length; rw [hl]; simp; have := hs.len; simp only [St.made] at this; omega
      · intro j d hd k hk
        show k < j
        change cs.list[j]? = some d at hd
        rw [hl] at hd
        if hj : j < s.classes.list.length then
          rw [List.getElem?_append_left hj] at hd
          exact hs.topo j d hd k hk
        else
          rw [List.getElem?_append_right (by omega)] at hd
          cases e : j - s.classes.list.length with
          | zero =>
            rw [e] at hd; simp at hd; subst hd
            have := hi k hk; simp only [St.made] at this; omega
          | succ m => rw [e] at hd; simp at hd
      · intro d k hk
        have := hs.copies d k hk
        show k < cs.list.length; rw [hl]; simp; simp only [St.made] at this; omega
      · show s.classes.list.length < cs.list.length; rw [hl]; simp

/-- What `load` and `resolveImport` return: a class that exists, if any. -/
abbrev ClsOk (L : Nat) (r : Option Nat) (s : St) : Prop := Closed L s ∧ ∀ k, r = some k → k < s.made

/-- At least `L` classes, and the class `k` if `r` is `some k`. -/
def bound (L : Nat) : Option Nat → Nat
  | none => L
  | some k => max L (k + 1)

theorem le_bound (L : Nat) (r : Option Nat) : L ≤ bound L r := by
  cases r <;> simp only [bound] <;> omega

theorem Closed.of_bound {L : Nat} {r : Option Nat} {s : St} (h : Closed (bound L r) s) : ClsOk L r s := by
  cases r with
  | none => exact ⟨h, by simp⟩
  | some k =>
    refine ⟨h.lower (by simp only [bound]; omega), fun k' e => ?_⟩
    cases e; have := h.len; simp only [bound] at this; omega

theorem ClsOk.bound {L : Nat} {r : Option Nat} {s : St} (h : ClsOk L r s) : Closed (bound L r) s := by
  cases r with
  | none => exact h.1
  | some k =>
    have := h.2 k rfl; have := h.1.len
    exact ⟨by simp only [Haus.Packages.bound]; omega, h.1.topo, h.1.copies⟩

/-- A step that keeps `Closed N`, whose error state is also `Closed L` for `L ≤ N`. -/
theorem Keeps.weak {α : Type} {env : Env} {L N : Nat} {x : M α} (h : Keeps (Closed N) x) (hle : L ≤ N) :
    Triple env (Closed N) x (fun _ => Closed N) (Closed L) :=
  Triple.mono (h env) (fun _ h => h) (fun _ _ h => h) (fun _ h => h.lower hle)

theorem bound_step {L : Nat} {b r : Option Nat} {s : St} (h : ClsOk (bound L b) r s) :
    Closed (bound L (if b.isNone then r else b)) s := by
  cases b with
  | none => exact ClsOk.bound h
  | some k => exact h.1

/-- Steps of `resolveImport` and `load` that keep `Closed`. -/
macro "cstep" : tactic => `(tactic| first
  | with_reducible apply Triple.bind_pure
  | with_reducible apply Triple.bind_look
  | with_reducible apply Triple.bind_ask
  | with_reducible apply Triple.bind_cfg
  | with_reducible exact Triple.bind_fail fun _ h => h
  | with_reducible exact Triple.fail fun _ h => h
  | with_reducible exact Triple.bind_throw fun _ h => h
  | with_reducible exact Triple.throw fun _ h => h
  | with_reducible refine Triple.bind (Keeps.checkNames _) fun _ => ?_
  | with_reducible refine Triple.bind (Keeps.manifestOf _) fun _ => ?_
  | with_reducible refine Triple.bind (Keeps.candidates _) fun _ => ?_
  | with_reducible refine Triple.bind (Keeps.packageJsonOf _) fun _ => ?_
  | with_reducible refine Triple.bind (Keeps.copyNpm _) fun _ => ?_
  | with_reducible refine Triple.bind (Keeps.checkVersion _) fun _ => ?_
  | with_reducible refine Triple.bind (Keeps.checkNoFiles _) fun _ => ?_
  | with_reducible refine Triple.bind (Keeps.openPackageFile _) fun _ => ?_
  | with_reducible refine Triple.bind (Keeps.openFile _) fun _ => ?_
  | with_reducible refine Triple.bind (Keeps.countFile _) fun _ => ?_
  | with_reducible refine Triple.bind (Keeps.decodeScan _) fun _ => ?_
  | with_reducible refine Triple.bind (Keeps.noteImports _) fun _ => ?_
  | split
  | dsimp only)

theorem resolveImport_closed {env : Env} {loadFn : Target → M Loaded} {importer : Importer} {imp : Import}
    (hload : ∀ T L, Triple env (Closed L) (loadFn T) (fun r => ClsOk L r.cls) (Closed L)) (L : Nat) :
    Triple env (Closed L) (resolveImport loadFn importer imp) (ClsOk L) (Closed L) := by
  unfold resolveImport
  split
  · exact Triple.pure fun s hs => ⟨hs, by simp⟩
  · repeat (first
      | (with_reducible apply Triple.pure; exact fun _ h => ⟨h, fun _ e => nomatch e⟩)
      | refine Triple.bind (R := fun _ => Closed L) (Triple.mono (hload _ L) (fun _ h => h) (fun _ _ h => h.1)
          (fun _ h => h)) fun _ => ?_
      | cstep)
  · rename_i name major _
    refine Triple.bind (Keeps.candidates _) fun cands => ?_
    dsimp only
    refine Triple.bind (Triple.forIn (b := none) (fun _ b => Closed (bound L b)) ?_ fun _ _ h => h) fun r => ?_
    · intro c rest b _
      have hle : L ≤ bound L b := le_bound L b
      refine Triple.bind (Keeps.weak (Keeps.manifestOf (L := bound L b)) hle) fun m => ?_
      have hload' : Triple env (Closed (bound L b)) (loadFn (.copy c.1))
          (fun r s => Closed (bound L (if b.isNone then r.cls else b)) s) (Closed L) :=
        Triple.mono (hload _ (bound L b)) (fun _ h => h) (fun _ _ h => bound_step h) (fun _ h => h.lower hle)
      have hrest : ∀ r : Loaded, Triple env (fun s => Closed (bound L (if b.isNone then r.cls else b)) s)
          (if b.isNone = true then do checkNames imp r.types name; pure (ForInStep.yield r.cls)
            else do checkNames imp r.types name; pure (ForInStep.yield b))
          (fun x s => match x with
            | ForInStep.yield b' => Closed (bound L b') s
            | ForInStep.done b' => Closed (bound L b') s) (Closed L) := by
        intro r
        split
        · rename_i hb
          exact Triple.bind (Keeps.weak Keeps.checkNames (le_bound L _)) fun _ =>
            Triple.pure fun _ h => h
        · rename_i hb
          exact Triple.bind (Keeps.weak Keeps.checkNames (le_bound L _)) fun _ => Triple.pure fun _ h => h
      repeat (first
        | exact Triple.bind hload' hrest
        | exact Triple.bind_fail fun _ h => h.lower hle
        | exact Triple.fail fun _ h => h.lower hle
        | refine Triple.bind hload' fun _ => ?_
        | refine Triple.bind (Keeps.weak Keeps.checkNames (le_bound L _)) fun _ => ?_
        | (apply Triple.pure; intro _ h
           first | exact h | (rw [if_pos ‹_›] at h; exact h) | (rw [if_neg ‹_›] at h; exact h))
        | dsimp only
        | split)
    · exact Triple.pure fun _ h => h.of_bound

/-- At least `L` classes, and every class of `ts`. -/
def boundList (L : Nat) (ts : List Nat) : Nat := ts.foldl (fun a k => max a (k + 1)) L

theorem le_boundList (L : Nat) : ∀ ts : List Nat, L ≤ boundList L ts
  | [] => Nat.le_refl _
  | k :: ts => Nat.le_trans (Nat.le_max_left L (k + 1)) (le_boundList (max L (k + 1)) ts)

theorem lt_boundList (L : Nat) : ∀ ts : List Nat, ∀ k ∈ ts, k < boundList L ts
  | [], _, h => absurd h List.not_mem_nil
  | j :: ts, k, h => by
    rcases List.mem_cons.mp h with rfl | h
    · exact Nat.lt_of_lt_of_le (by omega) (le_boundList (max L (k + 1)) ts)
    · exact lt_boundList (max L (j + 1)) ts k h

theorem boundList_append (L : Nat) (ts : List Nat) (c : Nat) :
    boundList L (ts ++ [c]) = max (boundList L ts) (c + 1) := by
  simp [boundList, List.foldl_append]

theorem appendStep {L c : Nat} {ts : List Nat} {s : St} (h : ClsOk (boundList L ts) (some c) s) :
    Closed (boundList L (ts ++ [c])) s := by
  refine ⟨?_, h.1.topo, h.1.copies⟩
  rw [boundList_append]; have := h.1.len; have := h.2 c rfl; simp only [St.made] at *; omega

theorem markDone {L i : Nat} {dir : Path} {s : St} (h : Closed L s) (hi : i < s.made) :
    ClsOk L (some i) { s with copies := (dir, .done i) :: s.copies, finished := addNew s.finished (.copy dir) } := by
  refine ⟨⟨h.len, h.topo, fun d k hk => ?_⟩, fun k e => by cases e; exact hi⟩
  rcases List.mem_cons.mp hk with e | hk
  · cases e; exact hi
  · exact h.copies d k hk

-- The many branches of `load`'s copy case (each with the loop and `classify` after it) need more time.
set_option maxHeartbeats 800000 in
theorem load_closed {env : Env} {w : Walk} : ∀ (n : Nat) (T : Target) (L : Nat),
    Triple env (Closed L) (load w n T) (fun r => ClsOk L r.cls) (Closed L)
  | 0, _, L => by unfold load; exact Triple.fail fun _ h => h
  | n + 1, .file p, L => by
    unfold load
    have himp : ∀ (imp : Import), Triple env (Closed L) (resolveImport (load w n) (.app p) imp)
        (fun _ => Closed L) (Closed L) := fun imp =>
      Triple.mono (resolveImport_closed (fun T L => load_closed n T L) L) (fun _ h => h) (fun _ _ h => h.1)
        (fun _ h => h)
    repeat (first
      | (with_reducible apply Triple.pure; exact fun _ h => ⟨h, fun _ e => nomatch e⟩)
      | (with_reducible apply Triple.bind_get'; intro _ _)
      | (with_reducible apply Triple.bind_modify'; exact fun _ h => ⟨h.len, h.topo, h.copies⟩)
      | refine Triple.bind (Triple.forIn (fun _ _ => Closed L) (fun imp _ _ _ =>
          Triple.bind (himp imp) fun _ => Triple.pure fun _ h => h) fun _ _ h => h) fun _ => ?_
      | cstep)
  | n + 1, .copy dir, L => by
    unfold load
    apply Triple.bind_get
    intro s₀
    dsimp only
    split
    · rename_i c hc
      exact Triple.bind_get' fun _ _ => Triple.pure fun s ⟨h, e⟩ =>
        ⟨h, fun k hk => by cases hk; subst e; exact h.copies dir c (lookup_mem hc)⟩
    · exact Triple.fail fun _ h => h.1
    · refine Triple.bind_modify (Closed L) (fun s ⟨h, _⟩ => ⟨h.len, h.topo, fun d k hk => h.copies d k ?_⟩) ?_
      · exact (List.mem_cons.mp hk).resolve_left (by simp)
      repeat (first
        | with_reducible refine Triple.bind (Triple.forIn (b := []) (fun _ ts => Closed (boundList L ts))
            (fun _ _ _ _ => ?_) fun _ _ h => h) fun _ => ?_
        | with_reducible refine Triple.bind (Triple.mono (resolveImport_closed (fun T L => load_closed n T L) _)
            (fun _ h => h) (fun _ _ h => h) (fun _ h => h.lower (le_boundList L _))) fun _ => ?_
        | (with_reducible apply Triple.pure; exact fun _ h => appendStep h)
        | (with_reducible apply Triple.pure; exact fun _ h => h.1)
        | (with_reducible refine Triple.bind (Triple.mono (classify_closed (L := L))
            (fun s h => ⟨h.lower (le_boundList L _), fun k hk => Nat.lt_of_lt_of_le (lt_boundList L _ k hk) h.len⟩)
            (fun _ _ h => h) (fun _ h => h)) fun i => ?_
           exact Triple.bind_modify (fun s => ClsOk L (some i) s) (fun _ h => markDone h.1 h.2)
             (Triple.pure fun _ h => h))
        | cstep)

theorem Keeps.givenPackages {L : Nat} : Keeps (Closed L) givenPackages := by
  unfold Haus.Packages.givenPackages
  repeat (first | with_reducible exact Keeps.manifestOf | kstep)

theorem main_closed {env : Env} {root : Path} {w : Walk} : Triple env (Closed 0) (main root w) (fun _ => Closed 0) (Closed 0) := by
  unfold main
  refine Triple.bind (Keeps.givenPackages env) fun _ => ?_
  dsimp only
  refine Triple.withReader ?_
  repeat (first
    | exact Triple.bind (Triple.mono (load_closed _ _ 0) (fun _ h => h) (fun _ _ h => h.1) (fun _ h => h))
        fun _ => Triple.pure fun _ h => h
    | cstep)

/-- The state a run starts from has no classes and no copies. -/
theorem closed_empty : Closed 0 ({} : St) := ⟨Nat.le_refl _, by simp [Classes.empty], by simp⟩

/--
**The classes of every run are closed** (a step of R3): in the last state of
every run, whatever its outcome, each class imports only classes made before
it, and every copy loaded names a class made.
-/
theorem runIn_closed (t : Tree) (c : Config) (root : Path) : Closed 0 (runIn t c root).2 :=
  Triple.final main_closed closed_empty

/--
**The packages a run reaches import only packages made before them**: the
import graph of the packages has no cycles, and the run makes them in an
order where each package's imports come first.
-/
theorem classes_topo (t : Tree) (cfg : Config) (root : Path) {i : Nat} {c : Class}
    (h : (resolveIn t cfg root).classes.list[i]? = some c) : ∀ k ∈ c.imports, k < i :=
  (runIn_closed t cfg root).topo i c h

end Haus.Packages
