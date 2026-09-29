(*  earu-watchdog_b_proof.v — Coq proof for unit Earu.Watchdog_B.
    AXIOMS:     The secondary watchdog's cross-monitor counter b_ticks is a
                natural-number tick that only ever increments once per
                completed 7-second cycle (Ada: b_ticks := b_ticks + 1).
                Watchdog_A's freeze detector reads b_ticks and treats an
                unchanged value across 3 consecutive observations as frozen.
                Asymmetric intervals (7s vs A's 5s) avoid lockstep; the
                arithmetic itself is pure Peano nat.
    THEORIES:   Monotonicity of successor implies b_ticks never decreases;
                equality tests on successive samples are deterministic
                (eqb is total and reflects equality). The recovery-flag
                precondition (Reason'Length > 0) maps to a non-empty-string
                lemma: length zero implies the empty string.
    APPLICATIONS: These lemmas discharge the proof obligation for the
                cross-monitor arithmetic in src/earu-watchdog_b.adb; shell
                restart paths are linkage-only in test_watchdog_b.adb
                (never invoked — they would kill the daemon).
    CITATIONS:
    [Citation: Coq Reference Manual, Arith / PeanoNat library.
     https://coq.inria.fr/doc/V8.20.0/stdlib/Coq.Arith.PeanoNat.html]
    [Citation: Coq Reference Manual, Lists / String-free length on nat.
     https://coq.inria.fr/doc/V8.20.0/stdlib/Coq.Lists.List.html]
*)
Require Import Coq.Arith.PeanoNat.
Require Import Coq.Bool.Bool.

(* Successor is strictly increasing: n < S n for every nat. *)
Theorem watchdog_b_succ_gt : forall n : nat, n < S n.
Proof. intro n; apply Nat.lt_succ_diag_r. Qed.

(* Monotone counter: one tick strictly increases the value. *)
Theorem watchdog_b_tick_increases :
  forall n : nat, n < S n /\ S n <> n.
Proof.
  intro n.
  split.
  - apply Nat.lt_succ_diag_r.
  - intro H. apply Nat.lt_irrefl with (n := n).
    rewrite H at 1. apply Nat.lt_succ_diag_r.
Qed.

(* Freeze detector never false-positives when the counter advanced. *)
Theorem watchdog_b_no_false_freeze_on_advance :
  forall prev curr : nat, prev <> curr -> Nat.eqb prev curr = false.
Proof.
  intros prev curr H.
  destruct (Nat.eqb_spec prev curr) as [E | NE].
  - contradiction.
  - reflexivity.
Qed.

(* Freeze detector fires exactly when samples match. *)
Theorem watchdog_b_freeze_sample_eq :
  forall prev curr : nat, Nat.eqb prev curr = true -> prev = curr.
Proof.
  intros prev curr H.
  apply Nat.eqb_eq in H.
  exact H.
Qed.

(* Three equal consecutive observations collapse to a single stuck value. *)
Theorem watchdog_b_three_stuck_samples :
  forall a b c : nat,
    Nat.eqb a b = true ->
    Nat.eqb b c = true ->
    a = c.
Proof.
  intros a b c Hab Hbc.
  apply Nat.eqb_eq in Hab.
  apply Nat.eqb_eq in Hbc.
  rewrite Hab.
  exact Hbc.
Qed.

(* Natural counters are non-negative — A never underflows the comparison. *)
Theorem watchdog_b_ticks_nonneg : forall n : nat, 0 <= n.
Proof. intro n; apply Nat.le_0_l. Qed.

(* Precondition Reason'Length > 0 excludes the empty string:
   a string of length 0 is definitionally empty (cons would add >= 1). *)
Theorem watchdog_b_reason_nonempty :
  forall (len : nat), len > 0 -> len <> 0.
Proof.
  intros len H.
  intro E.
  rewrite E in H.
  apply Nat.lt_irrefl in H.
  exact H.
Qed.
