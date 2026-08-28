(* Coq proof for unit 'test_aws'
 * Standard: DO-178C sec 5.2.2, ECSS-Q-ST-80C sec 6.3
 * Property: clamping a value into [lo, hi] keeps it inside [lo, hi].
 * Murphy's Law: inputs may be corrupt; the bound must hold regardless.
 *)
Require Import ZArith.
Require Import Lia.
Open Scope Z_scope.

Definition clamp (x lo hi : Z) : Z :=
  if x <? lo then lo else if x >? hi then hi else x.

Theorem test_aws_clamp_bounded : forall (x lo hi : Z),
    lo <= hi -> lo <= clamp x lo hi <= hi.
Proof.
  intros.
  unfold clamp.
  (* Three cases from the boolean comparisons; linear arithmetic resolves each. *)
  destruct (x <? lo) eqn:?; destruct (x >? hi) eqn:?; lia.
Qed.
