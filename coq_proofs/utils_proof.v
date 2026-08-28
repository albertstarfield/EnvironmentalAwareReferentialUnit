(* Formal proof: rigid-transform helper bound for ai-imu-dr utils.py.
   Normalization/clamping of a transform component keeps it within [lo, hi].
   Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import ZArith.
Require Import Lia.
Open Scope Z_scope.

Section Utils.
  Definition clamp (x lo hi : Z) : Z :=
    if x <? lo then lo else if hi <? x then hi else x.

  Theorem transform_bounded : forall x lo hi, lo <= hi -> lo <= clamp x lo hi <= hi.
  Proof.
    intros x lo hi H. unfold clamp.
    destruct (x <? lo) eqn:H1.
    - apply Z.ltb_lt in H1. lia.
    - apply Z.ltb_ge in H1.
      destruct (hi <? x) eqn:H2.
      + apply Z.ltb_lt in H2. lia.
      + apply Z.ltb_ge in H2. lia.
  Qed.
End Utils.
