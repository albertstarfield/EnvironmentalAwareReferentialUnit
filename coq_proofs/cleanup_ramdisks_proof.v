(* Formal proof: cleanup preserves a subset for util/cleanup_ramdisks.py.
   After removing stale ramdisks, every remaining mount was present before.
   Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import List.
Import ListNotations.
Require Import ZArith.

Section CleanupRamdisks.
  Fixpoint cleanup (l : list Z) (stale : Z -> bool) : list Z :=
    match l with
    | nil => nil
    | h :: t => if stale h then cleanup t stale else h :: cleanup t stale
    end.

  Theorem cleanup_subset : forall l f, incl (cleanup l f) l.
  Proof.
    induction l as [| h t IH]; intros f; cbn; try easy.
    case_eq (f h); intros Hfh; cbn.
    - apply incl_tl. apply IH.
    - intros x [Heq | Hin]; [ subst x; left; reflexivity | right; apply IH in Hin; exact Hin ].
  Qed.
End CleanupRamdisks.
