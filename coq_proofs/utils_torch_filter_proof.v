(* Formal proof: gradient-norm clamp bound for utils_torch_filter.
   Clamping a gradient norm to [lo, hi] keeps it within [lo, hi].
   Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import ZArith.
Require Import Lia.
Open Scope Z_scope.

Section UtilsTorchFilter.
  Definition clamp (x lo hi : Z) : Z :=
    if x <? lo then lo else if hi <? x then hi else x.

  Theorem gradnorm_bounded : forall g lo hi, lo <= hi -> lo <= clamp g lo hi <= hi.
  Proof.
    intros g lo hi H. unfold clamp.
    destruct (g <? lo) eqn:H1.
    - apply Z.ltb_lt in H1. lia.
    - apply Z.ltb_ge in H1.
      destruct (hi <? g) eqn:H2.
      + apply Z.ltb_lt in H2. lia.
      + apply Z.ltb_ge in H2. lia.
  Qed.
End UtilsTorchFilter.
