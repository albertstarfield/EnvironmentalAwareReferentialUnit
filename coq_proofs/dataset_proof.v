(* Formal proof: batch count is positive for the AI-IMU-DR dataset loader.
   Given a positive batch size and a non-empty dataset, at least one batch exists.
   Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import ZArith.
Require Import Lia.
Open Scope Z_scope.

Section Dataset.
  Definition nbatches (n b : Z) : Z :=
    if Z.eqb n 0 then 0 else 1 + (n - 1) / b.

  Theorem nbatches_pos : forall n b, 0 < b -> 0 < n -> 0 < nbatches n b.
  Proof.
    intros n b Hb Hn. unfold nbatches.
    destruct (Z.eqb n 0) eqn:Heq.
    - apply Z.eqb_eq in Heq. lia.
    - assert (Hd : 0 <= (n - 1) / b) by (apply Z.div_pos; lia).
      lia.
  Qed.
End Dataset.
