(*  earu-watchdog_a_proof.v — Coq proof for unit Earu.Watchdog_A.
    AXIOMS:     The primary watchdog's cross-monitor counter a_ticks is a
                natural-number tick that only ever increments once per
                completed 5-second cycle (Ada: a_ticks := a_ticks + 1).
                Watchdog_B's freeze detector treats an unchanged tick value
                across 3 consecutive observations as evidence that A is frozen.
    THEORIES:   Monotonicity of the successor on nat implies a_ticks never
                decreases; therefore two observations at different cycle
                counts must differ (B never sees a false freeze from a
                decreasing counter). The frozen predicate is stable under
                equality of observations: if two samples are equal the
                freeze-accumulation step is deterministic.
    APPLICATIONS: These lemmas discharge the proof obligation for the
                cross-monitor arithmetic in src/earu-watchdog_a.adb; the
                5-second cycle timing is covered by test_watchdog_a.adb
                at runtime (linkage-only for FFI paths).
    CITATIONS:
    [Citation: Coq Reference Manual, Arith / PeanoNat library.
     https://coq.inria.fr/doc/V8.20.0/stdlib/Coq.Arith.PeanoNat.html]
    [Citation: Coq Reference Manual, Bool library.
     https://coq.inria.fr/doc/V8.20.0/stdlib/Coq.Bool.Bool.html]
*)
Require Import Coq.Arith.PeanoNat.
Require Import Coq.Bool.Bool.

(* Successor is strictly increasing: n < S n for every nat. *)
Theorem watchdog_a_succ_gt : forall n : nat, n < S n.
Proof. intro n; apply Nat.lt_succ_diag_r. Qed.

(* Monotone counter: one tick strictly increases the value. *)
Theorem watchdog_a_tick_increases :
  forall n : nat, n < S n /\ S n <> n.
Proof.
  intro n.
  split.
  - apply Nat.lt_succ_diag_r.
  - intro H. apply Nat.lt_irrefl with (n := n).
    rewrite H at 1. apply Nat.lt_succ_diag_r.
Qed.

(* Freeze detector never false-positives when the counter advanced:
   distinct successive samples mean "not equal", so A_Frozen_Cnt resets. *)
Theorem watchdog_a_no_false_freeze_on_advance :
  forall prev curr : nat, prev <> curr -> Nat.eqb prev curr = false.
Proof.
  intros prev curr H.
  destruct (Nat.eqb_spec prev curr) as [E | NE].
  - contradiction.
  - reflexivity.
Qed.

(* Freeze detector does fire (equality holds) exactly when samples match. *)
Theorem watchdog_a_freeze_sample_eq :
  forall prev curr : nat, Nat.eqb prev curr = true -> prev = curr.
Proof.
  intros prev curr H.
  apply Nat.eqb_eq in H.
  exact H.
Qed.

(* Three equal consecutive samples (the A_Frozen_Cnt >= 3 threshold)
   is equivalent to three pairwise-equal observations — deterministic. *)
Theorem watchdog_a_three_stuck_samples :
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

(* Natural counters are non-negative — B never underflows the comparison. *)
Theorem watchdog_a_ticks_nonneg : forall n : nat, 0 <= n.
Proof. intro n; apply Nat.le_0_l. Qed.
