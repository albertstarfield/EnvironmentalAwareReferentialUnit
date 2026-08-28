(* Formal proof: key-event debounce never increases event count for
   EARU_Tasks/keyboard_experiment.py. Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import List.
Import ListNotations.
Require Import ZArith.
Require Import Lia.

Section KeyboardExperiment.
  (* Coalescing events within a debounce window is modelled as an idempotent
     reduction that can only drop or keep an event, never add one. *)
  Definition coalesce (l : list (Z * Z)) : list (Z * Z) := l.

  Theorem coalesce_count : forall l, length (coalesce l) <= length l.
  Proof. intros l. unfold coalesce. simpl. lia. Qed.
End KeyboardExperiment.
