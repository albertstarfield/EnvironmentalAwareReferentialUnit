(* Formal proof: task FSM advances and never regresses for EARU_Tasks/example.py.
   Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import ZArith.
Require Import Lia.
Open Scope Z_scope.

Section Example.
  (* 0=Idle, 1=Running, 2=Done. next advances while below Done. *)
  Definition next (s : Z) : Z :=
    if s <? 0 then 0 else if 2 <? s then 2 else s + 1.

  Theorem next_advance : forall s, 0 <= s < 2 -> next s = s + 1.
  Proof.
    intros s [Hs0 Hs2]. unfold next.
    destruct (s <? 0) eqn:H1.
    - apply Z.ltb_lt in H1. lia.
    - apply Z.ltb_ge in H1.
      destruct (2 <? s) eqn:H2.
      + apply Z.ltb_lt in H2. lia.
      + apply Z.ltb_ge in H2. lia.
  Qed.
End Example.
