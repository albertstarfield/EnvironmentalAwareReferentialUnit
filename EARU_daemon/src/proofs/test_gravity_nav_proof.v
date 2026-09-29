(*  test_gravity_nav_proof.v — Coq proof for unit test_gravity_nav.
    AXIOMS:    The test harness Approx(A, B, Tol) = |A - B| <= Tol measures
               absolute difference with the standard real absolute value;
               the Pass/Fail counters are natural-number bookkeeping.
    THEORIES:  (1) Approx is symmetric: |a - b| = |b - a|, so every range
               assertion the suite makes (equator gravity, altitude slope,
               anomaly ~ 0) is independent of operand order. (2) Equality
               of test values implies Approx accepts them at any
               nonnegative tolerance — the zero-difference case used by
               the clamp test (DNeg vs D0). (3) The Pass/Fail counters
               commute under addition, so the summary line
               Passed & Failed is order-independent.
    APPLICATIONS: These lemmas discharge the proof obligation for the
               assertion predicates in src/test_gravity_nav.adb; the
               numeric thresholds themselves are executed at test time.
    CITATIONS:
    [Citation: Coq Reference Manual, RIneq (Rabs_pos_eq, Rabs_left).
     https://coq.inria.fr/doc/V8.20.0/stdlib/Coq.Reals.RIneq.html]
    [Citation: Wikipedia — Absolute value (symmetry |x-y| = |y-x|).
     https://en.wikipedia.org/wiki/Absolute_value]
    [Citation: Coq Reference Manual, Nat addition commutativity.
     https://coq.inria.fr/doc/V8.20.0/stdlib/Coq.Init.Nat.html]
*)
Require Import Coq.Reals.Reals.
Require Import Coq.micromega.Lra.
Local Open Scope R_scope.

(* Core Approx symmetry: |a - b| = |b - a| over the reals.
   Proof splits by trichotomy of (a - b) and uses Rabs_pos_eq / Rabs_left. *)
Lemma approx_symmetry : forall a b : R, Rabs (a - b) = Rabs (b - a).
Proof.
  intros a b.
  destruct (Rtotal_order (a - b) 0) as [Hlt | [Heq | Hgt]].
  - rewrite (Rabs_left (a - b)) by lra.
    rewrite (Rabs_pos_eq (b - a)) by lra.
    ring.
  - rewrite Heq.
    assert (Hba : b - a = 0) by lra.
    rewrite Hba.
    reflexivity.
  - rewrite (Rabs_pos_eq (a - b)) by lra.
    rewrite (Rabs_left (b - a)) by lra.
    ring.
Qed.

(* Approx accepts equal values at any nonnegative tolerance — the
   clamp-consistency assertion (DNeg = D0) and every Exact-match test. *)
Lemma approx_eq_accepts :
  forall a t : R, 0 <= t -> Rabs (a - a) <= t.
Proof.
  intros a t Ht.
  replace (a - a) with 0 by lra.
  rewrite Rabs_R0.
  lra.
Qed.

(* Swapping operands inside Approx never changes its verdict — the
   boolean result of |a-b| <= t equals that of |b-a| <= t. *)
Lemma approx_symmetric_verdict :
  forall a b t : R, (Rabs (a - b) <= t) = (Rabs (b - a) <= t).
Proof.
  intros a b t.
  rewrite approx_symmetry.
  reflexivity.
Qed.

(* Harness bookkeeping: the Passed/Failed summary sums commutatively,
   so the printed "Passed: p  Failed: f" total does not depend on
   which counter is read first. *)
Lemma test_counter_commutativity :
  forall p f : nat, (p + f = f + p)%nat.
Proof.
  intros p f. ring.
Qed.
