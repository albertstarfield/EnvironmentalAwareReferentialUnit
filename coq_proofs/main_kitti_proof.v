(* Formal proof: epoch index bounded for main_kitti training driver.
   The current epoch is clamped to [0, total], so it never exceeds total.
   Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import ZArith.
Require Import Lia.
Open Scope Z_scope.

Section MainKitti.
  Definition clamp (x lo hi : Z) : Z :=
    if x <? lo then lo else if hi <? x then hi else x.

  Theorem epoch_bounded : forall e total, 0 <= total -> 0 <= clamp e 0 total <= total.
  Proof.
    intros e total H. unfold clamp.
    destruct (e <? 0) eqn:H1.
    - apply Z.ltb_lt in H1. lia.
    - apply Z.ltb_ge in H1.
      destruct (total <? e) eqn:H2.
      + apply Z.ltb_lt in H2. lia.
      + apply Z.ltb_ge in H2. lia.
  Qed.
End MainKitti.
