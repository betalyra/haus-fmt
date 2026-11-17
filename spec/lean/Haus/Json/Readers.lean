import Haus.Json.Correct

/-!
# What the JSON readers return (spec §16)

The values the import (§16.1) and the self-describing reader (§16.2) return
have no duplicate keys (`UniqueKeys`, as `parse_uniqueKeys` says of the haus
parser's): the JSON text reader rejects duplicate member names
(`JSON.parse_sound`, `JSON.parseText_sound`), and both readers keep an
object's member names as the record's keys.

- `toValue_uniqueKeys`, `fromSelfDescribing_uniqueKeys`,
  `fromHausJson_uniqueKeys`: for well-formed JSON (`JSON.WellFormed`).
- `readImport_uniqueKeys`, `readHausJson_uniqueKeys`,
  `readHausJsonLines_uniqueKeys`: for every value read from text.
- `json_paths_agree`: a value read back from its self-describing JSON and
  decoded with a type is what reading its schema-based JSON with the type
  gives (§16.2, §16.3).
-/

namespace Haus
namespace JSON

theorem wellFormed_members {ms : List (String × JSON)} (h : WellFormed (.obj ms)) :
    (ms.map (·.1)).Nodup ∧ ∀ m ∈ ms, WellFormed m.2 := by
  cases h with
  | obj _ hn hm => exact ⟨hn, hm⟩

theorem wellFormed_items {xs : List JSON} (h : WellFormed (.arr xs)) : ∀ x ∈ xs, WellFormed x := by
  cases h with
  | arr _ hx => exact hx

/-! ## The import -/

mutual
/-- **The import has no duplicate keys**: a record's keys are an object's member names. -/
theorem toValue_uniqueKeys : ∀ (j : JSON) (v : Value), WellFormed j → toValue j = .ok v → UniqueKeys v
  | .null, v, _, h | .bool _, v, _, h => by
    simp only [toValue, Except.ok.injEq] at h; subst h; exact .variant _ _ (by simp)
  | .num t, v, _, h => by
    simp only [toValue] at h
    split at h
    · simp only [Except.ok.injEq] at h; subst h; exact .num _
    · cases h
  | .str s, v, _, h => by simp only [toValue, Except.ok.injEq] at h; subst h; exact .str _
  | .arr xs, v, hw, h => by
    simp only [toValue] at h
    obtain ⟨vs, hvs, rfl⟩ := map_ok.mp h
    exact .arr _ (toValueList_uniqueKeys xs vs (wellFormed_items hw) hvs)
  | .obj ms, v, hw, h => by
    simp only [toValue] at h
    obtain ⟨fs, hfs, rfl⟩ := map_ok.mp h
    obtain ⟨hn, hm⟩ := wellFormed_members hw
    obtain ⟨hk, hu⟩ := toValueMembers_uniqueKeys ms fs hm hfs
    exact .record _ (by rw [hk]; exact hn) hu

theorem toValueList_uniqueKeys : ∀ (xs : List JSON) (vs : List Value), (∀ x ∈ xs, WellFormed x) →
    toValueList xs = .ok vs → ∀ v ∈ vs, UniqueKeys v
  | [], vs, _, h => by simp only [toValueList, Except.ok.injEq] at h; subst h; simp
  | x :: xs, vs, hw, h => by
    simp only [toValueList, bind_ok, pure_ok] at h
    obtain ⟨w, hw', ws, hws, rfl⟩ := h
    intro v hv
    rcases List.mem_cons.mp hv with rfl | hv
    · exact toValue_uniqueKeys x v (hw x (List.mem_cons_self ..)) hw'
    · exact toValueList_uniqueKeys xs ws (fun y hy => hw y (List.mem_cons_of_mem _ hy)) hws v hv

theorem toValueMembers_uniqueKeys : ∀ (ms : List (String × JSON)) (fs : List (String × Value)),
    (∀ m ∈ ms, WellFormed m.2) → toValueMembers ms = .ok fs →
      fs.map (·.1) = ms.map (·.1) ∧ ∀ kv ∈ fs, UniqueKeys kv.2
  | [], fs, _, h => by simp only [toValueMembers, Except.ok.injEq] at h; subst h; simp
  | (k, x) :: ms, fs, hw, h => by
    simp only [toValueMembers, bind_ok, pure_ok] at h
    obtain ⟨w, hw', ws, hws, rfl⟩ := h
    obtain ⟨hk, hu⟩ := toValueMembers_uniqueKeys ms ws (fun m hm => hw m (List.mem_cons_of_mem _ hm)) hws
    refine ⟨by simp [hk], ?_⟩
    intro kv hkv
    rcases List.mem_cons.mp hkv with rfl | hkv
    · exact toValue_uniqueKeys x w (hw (k, x) (List.mem_cons_self ..)) hw'
    · exact hu kv hkv
end

/-! ## Self-describing JSON -/

mutual
/-- **The self-describing reader has no duplicate keys**: `_rec`'s member names are the record's keys. -/
theorem fromSelfDescribing_uniqueKeys : ∀ (j : JSON) (v : Value), WellFormed j → fromSelfDescribing j = .ok v →
    UniqueKeys v
  | .null, _, _, h | .bool _, _, _, h | .num _, _, _, h => by simp [fromSelfDescribing] at h
  | .str s, v, _, h => by
    simp only [fromSelfDescribing, Except.ok.injEq] at h; subst h; exact .str _
  | .arr xs, v, hw, h => by
    simp only [fromSelfDescribing] at h
    obtain ⟨vs, hvs, rfl⟩ := map_ok.mp h
    exact .arr _ (fromSelfDescribingList_uniqueKeys xs vs (wellFormed_items hw) hvs)
  | .obj ms, v, hw, h => by
    obtain ⟨-, hm⟩ := wellFormed_members hw
    rcases fromSelfDescribing_obj h with ⟨s, rfl, -, rfl⟩ | ⟨-, bs, rfl, -, rfl⟩ | ⟨ms', fs, rfl, hfs, rfl⟩ |
      ⟨t, rfl, -, rfl⟩ | ⟨t, y, ys, vs, hms, -, hvs, rfl⟩
    · exact .num _
    · exact .bytes _
    · obtain ⟨hn, hm'⟩ := wellFormed_members (hm ("_rec", .obj ms') (by simp))
      obtain ⟨hk, hu⟩ := fromSelfDescribingMembers_uniqueKeys ms' fs hm' hfs
      exact .record _ (by rw [hk]; exact hn) hu
    · exact .variant _ _ (by simp)
    · have ha : WellFormed (.arr (y :: ys)) := by
        rcases hms with rfl | rfl
        · exact hm ("_args", .arr (y :: ys)) (by simp)
        · exact hm ("_args", .arr (y :: ys)) (by simp)
      rcases hms with rfl | rfl
      · exact .variant _ _ (fromSelfDescribingList_uniqueKeys (y :: ys) vs (wellFormed_items ha) hvs)
      · exact .variant _ _ (fromSelfDescribingList_uniqueKeys (y :: ys) vs (wellFormed_items ha) hvs)
termination_by j => sizeOf j

theorem fromSelfDescribingList_uniqueKeys : ∀ (xs : List JSON) (vs : List Value), (∀ x ∈ xs, WellFormed x) →
    fromSelfDescribingList xs = .ok vs → ∀ v ∈ vs, UniqueKeys v
  | [], vs, _, h => by simp only [fromSelfDescribingList, Except.ok.injEq] at h; subst h; simp
  | x :: xs, vs, hw, h => by
    simp only [fromSelfDescribingList, bind_ok, pure_ok] at h
    obtain ⟨w, hw', ws, hws, rfl⟩ := h
    intro v hv
    rcases List.mem_cons.mp hv with rfl | hv
    · exact fromSelfDescribing_uniqueKeys x v (hw x (List.mem_cons_self ..)) hw'
    · exact fromSelfDescribingList_uniqueKeys xs ws (fun y hy => hw y (List.mem_cons_of_mem _ hy)) hws v hv
termination_by xs => sizeOf xs

theorem fromSelfDescribingMembers_uniqueKeys : ∀ (ms : List (String × JSON)) (fs : List (String × Value)),
    (∀ m ∈ ms, WellFormed m.2) → fromSelfDescribingMembers ms = .ok fs →
      fs.map (·.1) = ms.map (·.1) ∧ ∀ kv ∈ fs, UniqueKeys kv.2
  | [], fs, _, h => by simp only [fromSelfDescribingMembers, Except.ok.injEq] at h; subst h; simp
  | (k, x) :: ms, fs, hw, h => by
    simp only [fromSelfDescribingMembers, bind_ok, pure_ok] at h
    obtain ⟨w, hw', ws, hws, rfl⟩ := h
    obtain ⟨hk, hu⟩ := fromSelfDescribingMembers_uniqueKeys ms ws (fun m hm => hw m (List.mem_cons_of_mem _ hm)) hws
    refine ⟨by simp [hk], ?_⟩
    intro kv hkv
    rcases List.mem_cons.mp hkv with rfl | hkv
    · exact fromSelfDescribing_uniqueKeys x w (hw (k, x) (List.mem_cons_self ..)) hw'
    · exact hu kv hkv
termination_by ms => sizeOf ms
end

/-- The value in an envelope is well formed if the envelope is. -/
theorem unwrap_wellFormed {j j' : JSON} (hw : WellFormed j) (h : unwrap j = .ok j') : WellFormed j' := by
  unfold unwrap at h
  split at h
  · obtain ⟨-, hm⟩ := wellFormed_members hw
    split at h
    · cases h; exact hm ("_value", j') (by simp)
    · cases h
  · obtain ⟨-, hm⟩ := wellFormed_members hw
    split at h
    · cases h; exact hm ("_value", j') (by simp)
    · cases h
  · cases h

/-- With the envelope (§16.2). -/
theorem fromHausJson_uniqueKeys {j : JSON} {v : Value} (hw : WellFormed j) (h : fromHausJson j = .ok v) :
    UniqueKeys v := by
  simp only [fromHausJson, bind_ok] at h
  obtain ⟨j', hj', hv⟩ := h
  exact fromSelfDescribing_uniqueKeys j' v (unwrap_wellFormed hw hj') hv

/-! ## From text -/

theorem checkFits_ok {L : Limits} {v w : Value} (h : checkFits L v = .ok w) : w = v := by
  unfold checkFits at h
  split at h
  · cases h; rfl
  · cases h

/-- **The import of a JSON text** (§16.1) has no duplicate keys. -/
theorem readImport_uniqueKeys {L : Limits} {t : Text} {v : Value} (h : readImport L t = .ok v) : UniqueKeys v := by
  simp only [readImport, bind_ok] at h
  obtain ⟨j, hj, w, hw, hv⟩ := h
  rw [checkFits_ok hv]
  exact toValue_uniqueKeys j w (parseText_sound (by unfold parseDepth at hj; exact hj)).1 hw

theorem readHausJsonText_uniqueKeys {L : Limits} {t : Text} {v : Value} (h : readHausJsonText L t = .ok v) :
    UniqueKeys v := by
  simp only [readHausJsonText, bind_ok] at h
  obtain ⟨j, hj, w, hw, hv⟩ := h
  rw [checkFits_ok hv]
  exact fromHausJson_uniqueKeys (parseText_sound hj).1 hw

/-- **Self-describing JSON text** (§16.2) reads values without duplicate keys. -/
theorem readHausJson_uniqueKeys {L : Limits} {t : Text} {v : Value} (h : readHausJson L t = .ok v) : UniqueKeys v :=
  readHausJsonText_uniqueKeys h

/-- **Self-describing JSON Lines**: every value read has no duplicate keys. -/
theorem readHausJsonLines_uniqueKeys {L : Limits} {t : Text} {vs : List Value} (h : readHausJsonLines L t = .ok vs) :
    ∀ v ∈ vs, UniqueKeys v := by
  unfold readHausJsonLines at h
  generalize lines (dropBom t) = ls at h
  induction ls generalizing vs with
  | nil => simp only [List.mapM_nil, pure, Except.pure, Except.ok.injEq] at h; subst h; simp
  | cons l ls ih =>
    simp only [List.mapM_cons, bind_ok, pure_ok] at h
    obtain ⟨w, hw, ws, hws, rfl⟩ := h
    intro v hv
    rcases List.mem_cons.mp hv with rfl | hv
    · split at hw
      · cases hw
      · exact readHausJsonText_uniqueKeys hw
    · exact ih hws v hv

end JSON

/-! ## Both paths decode alike -/

/--
**Self-describing and schema-based JSON decode alike** (§16.2, §16.3): for a
well-formed value that the type `t` decodes, reading its self-describing
JSON back and decoding it gives what reading its schema-based JSON with `t`
gives.
-/
theorem json_paths_agree {env : Schema.Env} {t : Schema.Ty} {v : Value} {x : Schema.Typed} {j : JSON}
    (hx : Schema.decode env t v = .ok x) (hv : v.wf = true) (hj : Schema.toJson env t x = .ok j) :
    (JSON.fromHausJson (JSON.hausJson v)).mapError (fun e => ({ path := [], reason := e.reason, code := some e.code } :
      Schema.Error)) >>= Schema.decode env t = Schema.fromJson env t j := by
  rw [JSON.fromHausJson_hausJson v hv, Schema.schemaBased_round_trip hx hv hj]
  exact hx

end Haus
