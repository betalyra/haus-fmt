import Haus.SchemaFile.Closure
import Haus.Json.Fuel

/-!
# What decoding needs, for every schema `load` accepts (PLAN I4)

`decode` recurses on the value, so it terminates for every environment; what
it can't do without the schema's help is follow names: `whnf` follows names
and secrets to a type that consumes input, and fails on a name that isn't
defined (`unknown-type`) or a cycle of names (`unguarded-recursion`, §9.9).
For an environment `load` returns, it never does:

* `load_closed`: every name its types mention is defined (`EnvClosed`), and
  following names from every one of its names reaches a type that consumes
  input (`guarded`);
* `whnf_ok`: so `whnf` succeeds on every closed type, within `env.fuel` steps;
* `decode_noSchemaFault`: so decoding with any closed type, a name of the
  environment for one, never fails with `unknown-type` or
  `unguarded-recursion`, whatever the value: every error is about the value.

Each step of decoding past `whnf` goes into a part of the value, so decoding
takes at most `env.fuel` steps of following names per part of the input.
-/

namespace Haus.SchemaFile
open Haus Haus.Schema

/-- Every name the type mentions is defined in `env`. -/
def TyClosed (env : Env) (t : Ty) : Prop := ∀ n ∈ tyNames t, (env.lookup n).isSome = true

/-- Every name every type of `env` mentions is defined in `env`. -/
def EnvClosed (env : Env) : Prop := ∀ p ∈ env.defs, TyClosed env p.2

/-- An error that is the schema's fault, not the value's. -/
def SchemaFault (e : Error) : Prop := e.code = some .unknownType ∨ e.code = some .unguardedRecursion

/-! ## The checks `load` makes -/

theorem closedEnv_ok {env : Env} (h : closedEnv env = .ok ()) : EnvClosed env := by
  unfold closedEnv at h
  split at h
  · next hf =>
    intro p hp n hn
    have := List.find?_eq_none.1 hf p hp
    simp only [List.any_eq_true, Option.isNone_iff_eq_none, not_exists, not_and] at this
    cases hl : env.lookup n with
    | none => exact absurd hl (by simpa using this n hn)
    | some _ => rfl
  · cases h

theorem guarded_ok {env : Env} (h : guarded env = .ok ()) :
    ∀ p ∈ env.defs, ∃ r, whnf env env.fuel (.ref p.1) = .ok r := by
  unfold guarded at h
  split at h
  · next hf =>
    intro p hp
    have := List.find?_eq_none.1 hf p hp
    cases hw : whnf env env.fuel (.ref p.1) with
    | ok r => exact ⟨r, rfl⟩
    | error e => simp [hw, Except.toBool] at this
  · next n _ hf =>
    have hn := List.find?_some hf
    split at h
    · cases h
    · next r hw => simp [hw, Except.toBool] at hn

/-- What `load` checks on the way, when it returns. -/
theorem load_spec {text : Text} {env : Env} (h : load text = .ok env) :
    ∃ p F S, parse text = .ok p ∧ declare p = .ok F ∧ check F = .ok () ∧ F.instances F.roots = some S ∧
      F.envOf S = .ok env ∧ closedEnv env = .ok () ∧ guarded env = .ok () := by
  have bind_ok : ∀ {α β : Type} {r : C α} {f : α → C β} {x : β}, r >>= f = .ok x → ∃ y, r = .ok y ∧ f y = .ok x := by
    intro α β r f x h
    cases r with
    | error e => simp [bind, Except.bind] at h
    | ok y => exact ⟨y, rfl, h⟩
  unfold load at h
  obtain ⟨p, hp, h⟩ := bind_ok h
  obtain ⟨F, hF, h⟩ := bind_ok h
  obtain ⟨u1, hc, h⟩ := bind_ok h
  obtain ⟨S, hS, h⟩ := bind_ok h
  obtain ⟨env', he, h⟩ := bind_ok h
  obtain ⟨u2, hcl, h⟩ := bind_ok h
  obtain ⟨u3, hg, h⟩ := bind_ok h
  obtain ⟨_, _, h⟩ := bind_ok h
  obtain ⟨_, _, h⟩ := bind_ok h
  obtain ⟨_, _, h⟩ := bind_ok h
  cases h
  refine ⟨p, F, S, ?_, hF, hc, ?_, he, hcl, hg⟩
  · unfold parseC at hp
    split at hp
    · next p' hp' => cases hp; exact hp'
    · cases hp
  · unfold Source.instancesC at hS
    split at hS
    · next S' hS' => cases hS; exact hS'
    · cases hS

/-- What `load` returns is closed and guarded. -/
theorem load_closed {text : Text} {env : Env} (h : load text = .ok env) :
    EnvClosed env ∧ guarded env = .ok () := by
  obtain ⟨_, _, _, _, _, _, _, _, hcl, hg⟩ := load_spec h
  exact ⟨closedEnv_ok hcl, hg⟩

/--
And its types are exactly those of the instances reachable from the
definitions without parameters, which are finitely many (I6).
-/
theorem load_instances {text : Text} {env : Env} (h : load text = .ok env) :
    ∃ F S, check F = .ok () ∧ (∀ i, i ∈ S ↔ Reach F F.roots i) ∧ F.envOf S = .ok env ∧
      ∃ L : List Inst, L.length ≤ F.instBound F.roots ∧ ∀ i, Reach F F.roots i → i ∈ L := by
  obtain ⟨_, F, S, _, _, hc, hS, he, _, _⟩ := load_spec h
  exact ⟨F, S, hc, Source.instances_reach hS, he, check_finite hc F.roots⟩

/-! ## Names and parts of closed types -/

theorem lookup_mem_list : ∀ (l : List (String × Ty)) {n : String} {d : Ty}, l.lookup n = some d → (n, d) ∈ l
  | [], _, _, h => by simp at h
  | (k, v) :: ps, n, d, h => by
    simp only [List.lookup_cons] at h
    split at h
    · next hk => cases h; simp at hk; subst hk; simp
    · exact List.mem_cons_of_mem _ (lookup_mem_list ps h)

theorem lookup_mem_defs {env : Env} {n : String} {d : Ty} (h : env.lookup n = some d) : (n, d) ∈ env.defs :=
  lookup_mem_list env.defs h

theorem peel_names : ∀ (t : Ty), ∀ n ∈ tyNames (peel t).2, n ∈ tyNames t
  | .secret t, n, h => by
    simp only [peel] at h
    simpa [tyNames] using peel_names t n h
  | .string, _, h | .bytes, _, h | .int _, _, h | .float _, _, h | .decimal, _, h | .any, _, h
  | .time _, _, h | .array _, _, h | .map _, _, h | .record _ _, _, h | .variant _ _, _, h
  | .ref _, _, h => by simpa [peel] using h

theorem whnf_closed {env : Env} (hE : EnvClosed env) : ∀ (f : Nat) (t : Ty) (r : Nat × Ty),
    TyClosed env t → whnf env f t = .ok r → TyClosed env r.2
  | f, t, r, ht, h => by
    rcases peel_cases t with hn | ⟨s, n, hp⟩
    · rw [whnf_notRef hn] at h
      cases h
      exact fun m hm => ht m (peel_names t m hm)
    · cases f with
      | zero => exact absurd h (whnf_ref_zero hp)
      | succ f =>
        obtain ⟨d, r', hd, hw, rfl⟩ := whnf_ref_ok hp h
        exact whnf_closed hE f d r' (hE (n, d) (lookup_mem_defs hd)) hw

/-- **`whnf` succeeds** on every closed type of a guarded environment. -/
theorem whnf_ok {env : Env} (hg : guarded env = .ok ()) {t : Ty} (ht : TyClosed env t) :
    ∃ r, whnf env env.fuel t = .ok r := by
  rcases peel_cases t with hn | ⟨s, n, hp⟩
  · exact ⟨_, whnf_notRef hn _⟩
  · have hnt : n ∈ tyNames t := peel_names t n (by simp [hp, tyNames])
    have hl := ht n hnt
    cases hd : env.lookup n with
    | none => simp [hd] at hl
    | some d =>
      obtain ⟨r, hr⟩ := guarded_ok hg (n, d) (lookup_mem_defs hd)
      have hfuel : env.fuel = env.defs.length + 1 := rfl
      rw [hfuel] at hr ⊢
      obtain ⟨d', r', hd', hw, _⟩ := whnf_ref_ok (t := .ref n) (s := 0) (n := n) rfl hr
      rw [hd] at hd'
      cases hd'
      refine ⟨(s + r'.1, r'.2), ?_⟩
      rw [whnf_ref hp, hd]
      simp only [hw, Except.map]

theorem fieldNames_sub {fs : List Field} {f : Field} (h : f ∈ fs) : ∀ n ∈ tyNames f.ty, n ∈ fieldNames fs := by
  induction fs with
  | nil => simp at h
  | cons g fs ih =>
    intro n hn
    obtain ⟨k, o, t⟩ := g
    simp only [fieldNames, List.mem_append]
    rcases List.mem_cons.1 h with rfl | h
    · exact Or.inl hn
    · exact Or.inr (ih h n hn)

theorem tyListNames_sub {ts : List Ty} {t : Ty} (h : t ∈ ts) : ∀ n ∈ tyNames t, n ∈ tyListNames ts := by
  induction ts with
  | nil => simp at h
  | cons u ts ih =>
    intro n hn
    simp only [tyListNames, List.mem_append]
    rcases List.mem_cons.1 h with rfl | h
    · exact Or.inl hn
    · exact Or.inr (ih h n hn)

theorem caseNames_sub {cs : List Case} {c : Case} (h : c ∈ cs) : ∀ n ∈ caseNames [c], n ∈ caseNames cs := by
  induction cs with
  | nil => simp at h
  | cons d cs ih =>
    intro n hn
    rcases List.mem_cons.1 h with rfl | h
    · cases c <;> simp_all [caseNames]
    · have := ih h n hn
      cases d <;> simp_all [caseNames]

/-- The record a closed type stands for has closed fields. -/
theorem recordOf?_closed {env : Env} (hE : EnvClosed env) : ∀ (f : Nat) (t : Ty) {cl : Bool} {fs : List Field},
    TyClosed env t → recordOf? env f t = some (cl, fs) → ∀ x ∈ fs, TyClosed env x.ty
  | _, .record cl' fs', cl, fs, ht, h => by
    simp only [recordOf?, Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    exact fun x hx n hn => ht n (by simpa [tyNames] using fieldNames_sub hx n hn)
  | f + 1, .ref n, cl, fs, ht, h => by
    simp only [recordOf?] at h
    split at h
    · next d hd => exact recordOf?_closed hE f d (hE (n, d) (lookup_mem_defs hd)) h
    · cases h
  | 0, .ref _, _, _, _, h => by simp [recordOf?] at h
  | _, .string, _, _, _, h | _, .bytes, _, _, _, h | _, .int _, _, _, _, h | _, .float _, _, _, _, h
  | _, .decimal, _, _, _, h | _, .any, _, _, _, h | _, .time _, _, _, _, h | _, .secret _, _, _, _, h
  | _, .array _, _, _, _, h | _, .map _, _, _, _, h | _, .variant _ _, _, _, _, h => by simp [recordOf?] at h

/-- The case a tag selects in a closed variant, resolved, has closed types. -/
theorem caseOf?_closed {env : Env} (hE : EnvClosed env) {cl : Bool} {cases : List Case} {tag : String} {c : Case}
    (ht : TyClosed env (.variant cl cases)) (h : caseOf? env cases tag = some c) :
    ∀ n ∈ caseNames [c], (env.lookup n).isSome = true := by
  unfold caseOf? at h
  obtain ⟨c0, hc0, rfl⟩ := Option.map_eq_some_iff.1 h
  have hmem := List.mem_of_find?_eq_some hc0
  have h0 : ∀ n ∈ caseNames [c0], (env.lookup n).isSome = true :=
    fun n hn => ht n (by simpa [tyNames] using caseNames_sub hmem n hn)
  cases c0 with
  | named tag' t =>
    simp only [Case.resolve]
    have htc : TyClosed env t := fun n hn => h0 n (by simp [caseNames, hn])
    split
    · next cl' fs hr =>
      intro n hn
      simp only [caseNames, List.append_nil] at hn
      exact (by
        obtain ⟨x, hx, hnx⟩ : ∃ x ∈ fs, n ∈ tyNames x.ty := by
          clear hr h0 htc hmem hc0 h
          induction fs with
          | nil => simp [fieldNames] at hn
          | cons g fs ih =>
            obtain ⟨k, o, u⟩ := g
            simp only [fieldNames, List.mem_append] at hn
            rcases hn with hn | hn
            · exact ⟨_, List.mem_cons_self .., hn⟩
            · obtain ⟨x, hx, h⟩ := ih hn
              exact ⟨x, List.mem_cons_of_mem _ hx, h⟩
        exact recordOf?_closed hE _ t htc hr x hx n hnx)
    · intro n hn
      simp only [caseNames, tyListNames, List.append_nil] at hn
      exact htc n hn
  | bare _ | record _ _ _ | positional _ _ => simpa [Case.resolve] using h0

/-! ## Errors -/

theorem hidden_error {s : Nat} {c : Ty} {r : Except Error Typed} {e : Error} (h : hidden s c r = .error e) :
    r = .error e ∨ e.code = some .invalidSecret := by
  unfold hidden at h
  split at h
  · exact Or.inl h
  · cases h
  · cases h; exact Or.inr rfl

theorem under_error {α : Type} {s : Seg} {r : Except Error α} {e : Error} (h : under s r = .error e) :
    ∃ e', r = .error e' ∧ e.code = e'.code := by
  cases r with
  | error e' => simp only [under, Except.error.injEq] at h; subst h; exact ⟨e', rfl, rfl⟩
  | ok _ => simp [under] at h

theorem map_error {α β : Type} {f : α → β} {r : Except Error α} {e : Error} (h : r.map f = .error e) :
    r = .error e := by
  cases r <;> simp_all [Except.map]

theorem bind_error {α β : Type} {r : Except Error α} {f : α → Except Error β} {e : Error} (h : r >>= f = .error e) :
    r = .error e ∨ ∃ y, r = .ok y ∧ f y = .error e := by
  cases r with
  | error e' => simp only [bind, Except.bind, Except.error.injEq] at h; subst h; exact Or.inl rfl
  | ok y => exact Or.inr ⟨y, rfl, h⟩

theorem reject_noFault {α : Type} {c : Code} {m : String} {e : Error} (h : (reject c m : Except Error α) = .error e)
    (hc : c ≠ .unknownType ∧ c ≠ .unguardedRecursion) : ¬ SchemaFault e := by
  simp only [reject, fail, Except.error.injEq] at h
  subst h
  simp [SchemaFault, hc.1, hc.2]

/-- `decodeFields`' error for a field a closed record doesn't list. -/
theorem unknownField_noFault {k : String} : ¬ SchemaFault { path := [.key k], reason := "not a field of this closed record", code := some .unknownField } := by
  simp [SchemaFault]

theorem fault_code {e e' : Error} (h : e.code = e'.code) (h' : ¬ SchemaFault e') : ¬ SchemaFault e := by
  unfold SchemaFault at *; rw [h]; exact h'

theorem closed_part {env : Env} {c u : Ty} (hc : TyClosed env c) (h : ∀ n ∈ tyNames u, n ∈ tyNames c) :
    TyClosed env u := fun n hn => hc n (h n hn)

/-! ## Decoding never fails because of the schema -/

theorem decode_noFault_all {env : Env} (hE : EnvClosed env) (hg : guarded env = .ok ()) :
    (∀ t v, TyClosed env t → ∀ e, decode env t v = .error e → ¬ SchemaFault e) ∧
    (∀ tag i ts xs, (∀ t ∈ ts, TyClosed env t) → ∀ e, decodeArgs env tag i ts xs = .error e → ¬ SchemaFault e) ∧
    (∀ closed fields fs, (∀ f ∈ fields, TyClosed env f.ty) → ∀ e,
      decodeFields env closed fields fs = .error e → ¬ SchemaFault e) ∧
    (∀ t fs, TyClosed env t → ∀ e, decodeEntries env t fs = .error e → ¬ SchemaFault e) ∧
    (∀ t i xs, TyClosed env t → ∀ e, decodeItems env t i xs = .error e → ¬ SchemaFault e) := by
  refine decode.mutual_induct env
    (fun t v => TyClosed env t → ∀ e, decode env t v = .error e → ¬ SchemaFault e)
    (fun tag i ts xs => (∀ t ∈ ts, TyClosed env t) → ∀ e, decodeArgs env tag i ts xs = .error e → ¬ SchemaFault e)
    (fun closed fields fs => (∀ f ∈ fields, TyClosed env f.ty) → ∀ e,
      decodeFields env closed fields fs = .error e → ¬ SchemaFault e)
    (fun t fs => TyClosed env t → ∀ e, decodeEntries env t fs = .error e → ¬ SchemaFault e)
    (fun t i xs => TyClosed env t → ∀ e, decodeItems env t i xs = .error e → ¬ SchemaFault e)
    ?whnfErr ?main ?argsCons ?argsEnd ?itemsNil ?itemsCons ?fieldsNil ?fieldsKeep ?fieldsClosed ?fieldsSkip
    ?entriesNil ?entriesCons
  case whnfErr =>
    intro v t r hw ht e _
    obtain ⟨r', hr'⟩ := whnf_ok hg ht
    rw [hw] at hr'; cases hr'
  case main =>
    intro v t s c hw ih ht e h
    have hc : TyClosed env c := whnf_closed hE _ t (s, c) ht hw
    rw [decode, hw] at h
    by_cases hsec : e.code = some .invalidSecret
    · simp [SchemaFault, hsec]
    have hy := (hidden_error h).resolve_right hsec
    clear h
    split at hy
    next => cases hy
    next => cases hy
    next =>
      split at hy
      next =>
        split at hy
        next => cases hy
        next => exact reject_noFault hy (by decide)
      next => exact reject_noFault hy (by decide)
    next =>
      split at hy
      next => cases hy
      next => exact reject_noFault hy (by decide)
    next =>
      split at hy
      next => cases hy
      next => exact reject_noFault hy (by decide)
    next => cases hy
    next => cases hy
    next =>
      split at hy
      next => cases hy
      next =>
        split at hy
        next =>
          obtain ⟨e', he', hcode⟩ := under_error hy
          exact fault_code hcode (reject_noFault he' (by decide))
        next => exact reject_noFault hy (by decide)
    next t' xs =>
      exact ih (closed_part hc (by simp [tyNames])) e (map_error hy)
    next t' fs =>
      exact ih (closed_part hc (by simp [tyNames])) e (map_error hy)
    next closed fields fs =>
      split at hy
      next => exact reject_noFault hy (by decide)
      next =>
        refine ih (fun f hf => closed_part hc ?_) e (map_error hy)
        intro n hn
        simpa [tyNames] using fieldNames_sub hf n hn
    next closed cases tag args =>
      split at hy
      next => cases hy
      next tag' cl fields fs hcase =>
        simp only [hcase] at ih
        have hcl := caseOf?_closed hE hc hcase
        refine ih (fun n hn => hcl n ?_) e (map_error hy)
        simpa [tyNames, caseNames] using hn
      next tag' ts hcase =>
        simp only [hcase] at ih
        have hcl := caseOf?_closed hE hc hcase
        split at hy
        next =>
          refine ih (fun t ht n hn => hcl n ?_) e (map_error hy)
          simpa [caseNames] using tyListNames_sub ht n hn
        next => exact reject_noFault hy (by decide)
      next => exact reject_noFault hy (by decide)
      next => exact reject_noFault hy (by decide)
      next => exact reject_noFault hy (by decide)
      next =>
        split at hy
        next => exact reject_noFault hy (by decide)
        next => cases hy
    next => exact reject_noFault hy (by decide)
  case argsCons =>
    intro tag i t ts x xs ihx ihs hts e h
    simp only [decodeArgs] at h
    rcases bind_error h with h | ⟨y, _, h⟩
    · obtain ⟨e', he', hcode⟩ := under_error h
      exact fault_code hcode (ihx (hts t (by simp)) e' he')
    · rcases bind_error h with h | ⟨ys, _, h⟩
      · exact ihs (fun u hu => hts u (List.mem_cons_of_mem _ hu)) e h
      · cases h
  case argsEnd =>
    intro xs tag i ts hne _ e h
    cases xs <;> cases ts <;> simp [decodeArgs] at h
    exact (hne _ _ _ _ rfl rfl).elim
  case itemsNil =>
    intro t i _ e h
    simp [decodeItems] at h
  case itemsCons =>
    intro t i x xs ihx ihs ht e h
    simp only [decodeItems] at h
    rcases bind_error h with h | ⟨y, _, h⟩
    · obtain ⟨e', he', hcode⟩ := under_error h
      exact fault_code hcode (ihx ht e' he')
    · rcases bind_error h with h | ⟨ys, _, h⟩
      · exact ihs ht e h
      · cases h
  case fieldsNil =>
    intro closed fields _ e h
    simp [decodeFields] at h
  case fieldsKeep =>
    intro closed fields k x fs f hf ihx ihs hfs e h
    simp only [decodeFields, hf] at h
    rcases bind_error h with h | ⟨y, _, h⟩
    · obtain ⟨e', he', hcode⟩ := under_error h
      have hmem : f ∈ fields := List.mem_of_find?_eq_some hf
      exact fault_code hcode (ihx (hfs f hmem) e' he')
    · rcases bind_error h with h | ⟨ys, _, h⟩
      · exact ihs hfs e h
      · cases h
  case fieldsClosed =>
    intro fields k x fs hf _ e h
    simp only [decodeFields, hf, ↓reduceIte, Except.error.injEq] at h
    subst h
    simp [SchemaFault]
  case fieldsSkip =>
    intro closed fields k x fs hf hc ihs hfs e h
    simp only [decodeFields, hf, hc, Bool.false_eq_true, ↓reduceIte] at h
    simp only [Bool.not_eq_true] at hc
    subst hc
    exact ihs hfs e h
  case entriesNil =>
    intro t _ e h
    simp [decodeEntries] at h
  case entriesCons =>
    intro t k x fs ihx ihs ht e h
    simp only [decodeEntries] at h
    rcases bind_error h with h | ⟨y, _, h⟩
    · obtain ⟨e', he', hcode⟩ := under_error h
      exact fault_code hcode (ihx ht e' he')
    · rcases bind_error h with h | ⟨ys, _, h⟩
      · exact ihs ht e h
      · cases h

/--
**I4.** Decoding with a closed type of a closed, guarded environment never
fails with `unknown-type` or `unguarded-recursion`: whatever the value, an
error is about the value.
-/
theorem decode_noFault {env : Env} (hE : EnvClosed env) (hg : guarded env = .ok ()) {t : Ty}
    (ht : TyClosed env t) (v : Value) {e : Error} (h : decode env t v = .error e) : ¬ SchemaFault e :=
  (decode_noFault_all hE hg).1 t v ht e h

/--
**I4 for schema files.** For every schema file `load` accepts (§14) and every
name it defines, decoding any value with it never fails because of the
schema; following names takes at most `env.fuel` steps per part of the input
(`whnf_ok`), and every other step goes into a part of the value.
-/
theorem load_decode {text : Text} {env : Env} (h : load text = .ok env) {n : String}
    (hn : (env.lookup n).isSome = true) (v : Value) {e : Error} (hd : decode env (.ref n) v = .error e) :
    ¬ SchemaFault e := by
  obtain ⟨hE, hg⟩ := load_closed h
  exact decode_noFault hE hg (fun m hm => by simp [tyNames] at hm; subst hm; exact hn) v hd

end Haus.SchemaFile
