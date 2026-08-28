(* Formal proof: low-pass filter output bounded for utils_numpy_filter.
   The filter clamps its accumulator to [lo, hi], hence the output is bounded.
   Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import ZArith.
Require Import Lia.
Open Scope Z_scope.

Section UtilsNumpyFilter.
  Definition clamp (x lo hi : Z) : Z :=
    if x <? lo then lo else if hi <? x then hi else x.

  Theorem lp_bounded : forall x lo hi, lo <= hi -> lo <= clamp x lo hi <= hi.
  Proof.
    intros x lo hi H. unfold clamp.
    destruct (x <? lo) eqn:H1.
    - apply Z.ltb_lt in H1. lia.
    - apply Z.ltb_ge in H1.
      destruct (hi <? x) eqn:H2.
      + apply Z.ltb_lt in H2. lia.
      + apply Z.ltb_ge in H2. lia.
  Qed.
End UtilsNumpyFilter.
