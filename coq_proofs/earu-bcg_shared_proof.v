(* Coq proof for unit 'earu-bcg_shared'
 * Standard: DO-178C sec 5.2.2, ECSS-Q-ST-80C sec 6.3
 * Property: for an ordered pair the difference is non-negative (in-bounds).
 * Murphy's Law: stored indices/offsets may be corrupt; order still implies >=0.
 *)
Require Import ZArith.
Require Import Lia.
Open Scope Z_scope.

Theorem earu_bcg_shared_ordered_diff : forall (a b : Z), a <= b -> 0 <= b - a.
Proof.
  intros.
  (* Difference of two ordered integers is non-negative. *)
  lia.
Qed.
