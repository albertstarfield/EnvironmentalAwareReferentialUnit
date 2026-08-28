(* Formal proof: normalized plot value bounded for utils_plot.
   Normalization clamps the scaled value to [0, 1].
   Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import ZArith.
Require Import Lia.
Open Scope Z_scope.

Section UtilsPlot.
  Definition clamp (x lo hi : Z) : Z :=
    if x <? lo then lo else if hi <? x then hi else x.

  Theorem norm_bounded : forall x, 0 <= clamp x 0 1 <= 1.
  Proof.
    intros x. unfold clamp.
    destruct (x <? 0) eqn:H1.
    - apply Z.ltb_lt in H1. lia.
    - apply Z.ltb_ge in H1.
      destruct (1 <? x) eqn:H2.
      + apply Z.ltb_lt in H2. lia.
      + apply Z.ltb_ge in H2. lia.
  Qed.
End UtilsPlot.
