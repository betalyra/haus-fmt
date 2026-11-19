import Haus.SchemaFile.Finite

/-!
# Computing the instances

`Source.instances F ts`, rounds of `Source.grow` from the instances `ts`
names, is what `load` uses. `instances_reach`: what it returns is exactly
the instances reachable from `ts` (`Reach`). `instances_some`: for a file
that passes `check`, it returns, whenever `instBound` (`Source.reach_finite`)
is within the implementation limit `maxInstances`: each round adds an
instance until none is added, and they are all among at most `instBound`.
-/

namespace Haus.SchemaFile

theorem Source.mem_grow {F : Source} {S : List Inst} {i : Inst} :
    i ∈ F.grow S ↔ i ∈ S ∨ ∃ j ∈ S, i ∈ F.succs j := by
  simp [Source.grow, mem_addNew]

theorem Source.mem_rootInsts {F : Source} {ts : List Tm} {i : Inst} :
    i ∈ F.rootInsts ts ↔ i ∈ ts.flatMap Tm.refs ∧ F.defined i.1 = true := by
  simp [Source.rootInsts, mem_addNew]

/-- What `closure` returns contains `S` and every instance its instances mention. -/
theorem Source.closure_closed {F : Source} : ∀ (k : Nat) {S R : List Inst}, F.closure k S = some R →
    S ⊆ R ∧ ∀ i ∈ R, F.succs i ⊆ R
  | 0, _, _, h => by simp [Source.closure] at h
  | k + 1, S, R, h => by
    simp only [Source.closure] at h
    split at h
    · next hlen =>
      cases h
      refine ⟨List.Subset.refl _, fun i hi j hj => ?_⟩
      exact addNew_stable (by simpa [Source.grow] using hlen) j (List.mem_flatMap.2 ⟨i, hi, hj⟩)
    · split at h
      · cases h
      · obtain ⟨hS, hR⟩ := Source.closure_closed k h
        exact ⟨fun i hi => hS (Source.mem_grow.2 (Or.inl hi)), hR⟩

/-- Every instance `closure` returns is reachable, if those of `S` are. -/
theorem Source.closure_sound {F : Source} {ts : List Tm} : ∀ (k : Nat) {S R : List Inst},
    F.closure k S = some R → (∀ i ∈ S, Reach F ts i) → ∀ i ∈ R, Reach F ts i
  | 0, _, _, h, _ => by simp [Source.closure] at h
  | k + 1, S, R, h, hS => by
    simp only [Source.closure] at h
    split at h
    · cases h; exact hS
    · split at h
      · cases h
      · apply Source.closure_sound k h
        intro i hi
        rcases Source.mem_grow.1 hi with hi | ⟨j, hj, hij⟩
        · exact hS i hi
        · exact .step (hS j hj) hij

/-- **What `instances` computes**: exactly the instances reachable from `ts`. -/
theorem Source.instances_reach {F : Source} {ts : List Tm} {R : List Inst} (h : F.instances ts = some R) :
    ∀ i, i ∈ R ↔ Reach F ts i := by
  intro i
  constructor
  · intro hi
    exact Source.closure_sound _ h (fun j hj => .root (Source.mem_rootInsts.1 hj).1 (Source.mem_rootInsts.1 hj).2) i hi
  · intro hr
    obtain ⟨hS, hR⟩ := Source.closure_closed _ h
    induction hr with
    | root hi hdef => exact hS (Source.mem_rootInsts.2 ⟨hi, hdef⟩)
    | step _ hj ih => exact hR _ ih hj

theorem Source.reach_length_le {F : Source} {ts : List Tm} (hG : GrowthOk F) {S : List Inst}
    (hS : ∀ i ∈ S, Reach F ts i) (hn : S.Nodup) : S.length ≤ F.instBound ts :=
  Nat.le_trans (List.Nodup.length_le_of_subset hn fun i hi => Source.reach_universe hG (hS i hi))
    (F.length_universe ts)

theorem Source.closure_some {F : Source} {ts : List Tm} (hG : GrowthOk F) (hB : F.instBound ts ≤ maxInstances) :
    ∀ (fuel : Nat) (S : List Inst), (∀ i ∈ S, Reach F ts i) → S.Nodup → F.instBound ts < fuel + S.length →
    ∃ R, F.closure fuel S = some R
  | 0, S, hS, hn, hlt => by
    have := Source.reach_length_le hG hS hn
    omega
  | fuel + 1, S, hS, hn, hlt => by
    have hS' : ∀ i ∈ F.grow S, Reach F ts i := by
      intro i hi
      rcases Source.mem_grow.1 hi with hi | ⟨j, hj, hij⟩
      · exact hS i hi
      · exact .step (hS j hj) hij
    have hn' : (F.grow S).Nodup := nodup_addNew hn
    have hle' := Source.reach_length_le hG hS' hn'
    obtain ⟨zs, hz⟩ := addNew_prefix S (S.flatMap F.succs)
    simp only [Source.closure]
    split
    · exact ⟨S, rfl⟩
    · next hne =>
      have hgt : S.length < (F.grow S).length := by
        have : (F.grow S).length = S.length + zs.length := by simp [Source.grow, hz]
        have : zs.length ≠ 0 := by
          intro h0
          apply hne
          simp [this, h0]
        omega
      split
      · omega
      · exact Source.closure_some hG hB fuel _ hS' hn' (by omega)

/--
**`instances` returns** for every file that passes `check`, whenever
`instBound` is within `maxInstances`.
-/
theorem Source.instances_some {F : Source} (h : check F = .ok ()) {ts : List Tm}
    (hB : F.instBound ts ≤ maxInstances) : ∃ R, F.instances ts = some R := by
  apply Source.closure_some (checkGrowth_ok (check_growth h)) hB
  · intro i hi
    exact .root (Source.mem_rootInsts.1 hi).1 (Source.mem_rootInsts.1 hi).2
  · exact nodup_addNew List.nodup_nil
  · omega

end Haus.SchemaFile
