(* Formal proof: key comparison is transitive for util/compare_keys.py.
   Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import ZArith.
Require Import Lia.
Open Scope Z_scope.

Section CompareKeys.
  Inductive cmp := Lt | Eq | Gt.
  Definition compare_keys (a b : Z) : cmp :=
    if a <? b then Lt else if b <? a then Gt else Eq.

  Theorem compare_trans : forall a b c,
      compare_keys a b = Lt -> compare_keys b c = Lt -> compare_keys a c = Lt.
  Proof.
    intros a b c H1 H2. unfold compare_keys in *.
    destruct (a <? b) eqn:Hab; destruct (b <? c) eqn:Hbc.
    - apply Z.ltb_lt in Hab. apply Z.ltb_lt in Hbc.
      assert (Hac : a < c) by lia.
      apply Z.ltb_lt in Hac. rewrite Hac. reflexivity.
    - destruct (c <? b) eqn:Hcb; discriminate.
    - destruct (b <? a) eqn:Hba; discriminate.
    - destruct (b <? a) eqn:Hba; discriminate.
  Qed.
End CompareKeys.
