(* Formal proof: EARU dual-watchdog resurrection invariant.
   The resurrection counter is bounded by max_resurrections and only advances
   while below the bound. Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import Arith.
Require Import Lia.

Section EaruWatchdog.
  Variable max_resurrections : nat.
  Hypothesis max_pos : max_resurrections > 0.

  (* Resurrection counter step: increments while below the bound, else clamps. *)
  Definition step (r : nat) : nat :=
    if Nat.ltb r max_resurrections then r + 1 else max_resurrections.

  Theorem step_bounded : forall r, step r <= max_resurrections.
  Proof.
    intros r. unfold step.
    destruct (Nat.ltb r max_resurrections) eqn:H.
    - apply Nat.ltb_lt in H. lia.
    - apply Nat.ltb_ge in H. lia.
  Qed.

  Theorem step_advance : forall r, r < max_resurrections -> step r = r + 1.
  Proof.
    intros r H. unfold step.
    destruct (Nat.ltb r max_resurrections) eqn:H1.
    - apply Nat.ltb_lt in H1. reflexivity.
    - apply Nat.ltb_ge in H1. lia.
  Qed.
End EaruWatchdog.
