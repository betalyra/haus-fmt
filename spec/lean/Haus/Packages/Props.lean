import Haus.Packages.Resolve

/-!
# One package per name, and ids (R2)

**One package per name** (§13.3, "Imports"). The classes a run makes have
distinct names (`Classes.distinct`, part of their type: `classify` adds a
class only when no class has its name). So on success:

- `resolveIn_ok`: the packages returned are those classes, as `name@version`;
- `one_package_per_name`: two of them with one name are the same class, so a
  name has one `package.haus`, one `schema.haus` and one list of packages its
  imports reach;
- `addClass_same`: a copy is given a class only if the class has the
  copy's name, its `package.haus` and `schema.haus` byte for byte, and the
  classes of its imports; and the classes only grow (the old ones are a
  prefix of the new). `classify`, which runs `addClass` on the state, is the
  only place that writes the classes; so every copy loaded has the files of
  its name's class. (That last step is by inspection of `Resolve.lean`: it
  is not proven as an invariant over `load`.)

**Ids** (§13.3, "Identity"). `typeId name major type` is
`@org/name@N#Type`; `typeId_injective`: for valid names and majors, the id
determines all three, because a name has no `#`, and a major has neither
`@` nor `#`. (The Roc module names of the security review's G22 are not
injective; they are outside this model.)
-/

namespace Haus.Packages

/-! ## One package per name -/

theorem eq_of_nodup_map {α β} {f : α → β} :
    ∀ {l : List α}, (l.map f).Nodup → ∀ {a b}, a ∈ l → b ∈ l → f a = f b → a = b
  | [], _, _, _, ha, _, _ => absurd ha List.not_mem_nil
  | x :: xs, h, a, b, ha, hb, e => by
    rw [List.map_cons, List.nodup_cons] at h
    obtain ⟨hx, hxs⟩ := h
    rcases List.mem_cons.mp ha with ha' | ha' <;> rcases List.mem_cons.mp hb with hb' | hb'
    · rw [ha', hb']
    · have : f x ∈ xs.map f := List.mem_map.mpr ⟨b, hb', by rw [← e, ha']⟩
      exact absurd this hx
    · have : f x ∈ xs.map f := List.mem_map.mpr ⟨a, ha', by rw [e, hb']⟩
      exact absurd this hx
    · exact eq_of_nodup_map hxs ha' hb' e

/-- Whatever the outcome, the packages made have distinct names. -/
theorem resolveIn_distinct (t : Tree) (cfg : Config) (root : Path) :
    ((resolveIn t cfg root).classes.list.map (·.name)).Nodup :=
  (resolveIn t cfg root).classes.distinct

theorem Outcome.of_ok {p : Except Err Unit × St} {ps : List String} (h : (Outcome.of p).result = .ok ps) :
    ps = packagesOf (Outcome.of p).classes.list := by
  obtain ⟨r, s⟩ := p
  cases r <;> simp [Outcome.of, Except.map] at h ⊢
  exact h.symm

/-- On success, the result lists the packages made. -/
theorem resolveIn_ok {t : Tree} {cfg : Config} {root : Path} {ps : List String}
    (h : (resolveIn t cfg root).result = .ok ps) :
    ps = packagesOf (resolveIn t cfg root).classes.list :=
  Outcome.of_ok h

/-- Two packages a run reaches with one name are one package: one `package.haus`, one `schema.haus`. -/
theorem one_package_per_name {t : Tree} {cfg : Config} {root : Path} {c d : Class}
    (hc : c ∈ (resolveIn t cfg root).classes.list) (hd : d ∈ (resolveIn t cfg root).classes.list)
    (e : c.name = d.name) : c = d :=
  eq_of_nodup_map (resolveIn_distinct t cfg root) hc hd e

theorem Class.same_iff {c d : Class} :
    Class.same c d = true ↔ d.name = c.name ∧ d.manifest = c.manifest ∧ d.schema = c.schema ∧ d.imports = c.imports := by
  simp [Class.same, and_assoc]

/--
`addClass c` gives a copy, described by `c`, the class `i` only if that
class has the copy's name, `package.haus` and `schema.haus` bytes, and the
classes of its imports; and it only appends to the classes.
-/
theorem addClass_same {c : Class} {cs cs' : Classes} {i : Nat} (h : addClass c cs = .ok (i, cs')) :
    cs.list <+: cs'.list ∧ ∃ d, cs'.list[i]? = some d ∧
      d.name = c.name ∧ d.manifest = c.manifest ∧ d.schema = c.schema ∧ d.imports = c.imports := by
  unfold addClass at h
  split at h
  · rename_i j hj
    simp only [Except.ok.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    obtain ⟨hlt, hsame, -⟩ := List.findIdx?_eq_some_iff_getElem.mp hj
    exact ⟨List.prefix_refl _, _, List.getElem?_eq_getElem hlt, Class.same_iff.mp hsame⟩
  · split at h
    · simp at h
    · simp only [Except.ok.injEq, Prod.mk.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      refine ⟨List.prefix_append _ _, c, ?_, rfl, rfl, rfl, rfl⟩
      simp [Classes.push]

/-! ## Ids -/

/-- A type's id (§13.3, "Identity"): `@haus-fmt/money@1#Money`. -/
def typeId (name major type : String) : String := name ++ "@" ++ major ++ "#" ++ type

/-- A list split at the first `x`: `a ++ x :: b` determines `a` and `b` when `x ∉ a`. -/
theorem append_cons_cancel {α} {x : α} :
    ∀ {a₁ a₂ b₁ b₂ : List α}, x ∉ a₁ → x ∉ a₂ → a₁ ++ x :: b₁ = a₂ ++ x :: b₂ → a₁ = a₂ ∧ b₁ = b₂
  | [], [], _, _, _, _, h => ⟨rfl, by simpa using h⟩
  | [], y :: a₂, _, _, _, h₂, h => by
    simp only [List.nil_append, List.cons_append, List.cons.injEq] at h
    exact absurd (h.1 ▸ List.mem_cons_self) h₂
  | y :: a₁, [], _, _, h₁, _, h => by
    simp only [List.nil_append, List.cons_append, List.cons.injEq] at h
    exact absurd (h.1 ▸ List.mem_cons_self) h₁
  | y :: a₁, z :: a₂, _, _, h₁, h₂, h => by
    simp only [List.cons_append, List.cons.injEq] at h
    have ⟨e, f⟩ := append_cons_cancel (fun m => h₁ (List.mem_cons_of_mem _ m))
      (fun m => h₂ (List.mem_cons_of_mem _ m)) h.2
    exact ⟨by rw [h.1, e], f⟩

theorem isSegment_chars {s : List Char} (h : isSegment s = true) : ∀ c ∈ s, isSegmentChar c = true := by
  match s, h with
  | c :: cs, h =>
    simp only [isSegment, Bool.and_eq_true, List.all_eq_true] at h
    intro d hd
    rcases List.mem_cons.mp hd with rfl | hd
    · simp [isSegmentChar, h.1.1]
    · exact h.1.2 d hd

/-- A package name has no `#`: its characters are `@`, `/` and those of its parts. -/
theorem isPackageName_no_hash {s : String} (h : isPackageName s = true) : '#' ∉ s.toList := by
  unfold isPackageName at h
  simp only [Bool.and_eq_true] at h
  obtain ⟨-, h⟩ := h
  split at h
  · rename_i rest e
    split at h
    · rename_i name e'
      simp only [Bool.and_eq_true] at h
      rw [e]
      have hrest := List.takeWhile_append_dropWhile (p := (· != '/')) (l := rest)
      rw [e'] at hrest
      rw [← hrest]
      intro m
      simp only [List.mem_cons, List.mem_append] at m
      rcases m with m | m | m | m
      · exact absurd m (by decide)
      · exact absurd (isSegment_chars h.1 _ m) (by decide)
      · exact absurd m (by decide)
      · exact absurd (isSegment_chars h.2 _ m) (by decide)
    · simp at h
  · simp at h

/-- A major version is digits only. -/
theorem isMajor_digits {s : String} (h : isMajor s = true) : ∀ c ∈ s.toList, isDigit c = true := by
  unfold isMajor isNumeric at h
  split at h
  · rename_i e; rw [e]; intro c hc; simp at hc; subst hc; decide
  · rename_i c cs _ e
    rw [e]
    simp only [Bool.and_eq_true, List.all_eq_true] at h
    intro d hd
    rcases List.mem_cons.mp hd with rfl | hd
    · have h1 : '1' ≤ d := of_decide_eq_true h.1.1
      have h9 : d ≤ '9' := of_decide_eq_true h.1.2
      simp only [isDigit, Bool.and_eq_true, decide_eq_true_eq]
      exact ⟨Char.le_trans (by decide) h1, h9⟩
    · exact h.2 d hd
  · simp at h

/--
Ids are injective (R2): for valid package names and major versions, the id
`@org/name@N#Type` determines the package name, the major version and the
type name.
-/
theorem typeId_injective {n₁ n₂ m₁ m₂ t₁ t₂ : String}
    (hn₁ : isPackageName n₁ = true) (hn₂ : isPackageName n₂ = true)
    (hm₁ : isMajor m₁ = true) (hm₂ : isMajor m₂ = true)
    (h : typeId n₁ m₁ t₁ = typeId n₂ m₂ t₂) : n₁ = n₂ ∧ m₁ = m₂ ∧ t₁ = t₂ := by
  have hl := congrArg String.toList h
  simp only [typeId, String.toList_append] at hl
  have shape : ∀ n m t : String, n.toList ++ "@".toList ++ m.toList ++ "#".toList ++ t.toList =
      (n.toList ++ '@' :: m.toList) ++ '#' :: t.toList := by
    intro n m t; simp
  rw [shape, shape] at hl
  have noHash : ∀ n m : String, isPackageName n = true → isMajor m = true → '#' ∉ n.toList ++ '@' :: m.toList := by
    intro n m hn hm mem
    simp only [List.mem_append, List.mem_cons] at mem
    rcases mem with mem | mem | mem
    · exact isPackageName_no_hash hn mem
    · exact absurd mem (by decide)
    · exact absurd (isMajor_digits hm _ mem) (by decide)
  have ⟨hpre, ht⟩ := append_cons_cancel (noHash _ _ hn₁ hm₁) (noHash _ _ hn₂ hm₂) hl
  have hrev := congrArg List.reverse hpre
  simp only [List.reverse_append, List.reverse_cons, List.append_assoc, List.singleton_append] at hrev
  have noAt : ∀ m : String, isMajor m = true → '@' ∉ m.toList.reverse := by
    intro m hm mem
    exact absurd (isMajor_digits hm _ (List.mem_reverse.mp mem)) (by decide)
  have ⟨hm, hn⟩ := append_cons_cancel (noAt _ hm₁) (noAt _ hm₂) hrev
  exact ⟨String.ext (List.reverse_inj.mp hn), String.ext (List.reverse_inj.mp hm), String.ext ht⟩

#guard typeId "@haus-fmt/money" "1" "Money" = "@haus-fmt/money@1#Money"

end Haus.Packages
