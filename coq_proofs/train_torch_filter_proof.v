(* Formal proof: gradient clipping bound for the AI-IMU-DR torch filter.
   Clipping a gradient g to [-c, c] yields a value within [-c, c].
   Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import ZArith.
Require Import Lia.
Open Scope Z_scope.

Section TrainTorchFilter.
  Definition clip (g c : Z) : Z :=
    if g <? (-c) then -c else if c <? g then c else g.

  Theorem clip_bounded : forall g c, 0 <= c -> -c <= clip g c <= c.
  Proof.
    intros g c H. unfold clip.
    destruct (g <? -c) eqn:H1.
    - apply Z.ltb_lt in H1. lia.
    - apply Z.ltb_ge in H1.
      destruct (c <? g) eqn:H2.
      + apply Z.ltb_lt in H2. lia.
      + apply Z.ltb_ge in H2. lia.
  Qed.
End TrainTorchFilter.
