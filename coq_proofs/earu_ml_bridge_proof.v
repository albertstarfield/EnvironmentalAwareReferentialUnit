(* Coq proof for unit 'earu_ml_bridge'
 * Standard: DO-178C sec 5.2.2, ECSS-Q-ST-80C sec 6.3
 * Property: the sum of two non-negative quantities stays non-negative.
 * Murphy's Law: sensor/IO values may saturate at 0; the invariant holds.
 *)
Require Import ZArith.
Require Import Lia.
Open Scope Z_scope.

Theorem earu_ml_bridge_nonneg_add : forall (x y : Z),
    0 <= x -> 0 <= y -> 0 <= x + y.
Proof.
  intros.
  (* Sum of two non-negative integers is non-negative. *)
  lia.
Qed.
