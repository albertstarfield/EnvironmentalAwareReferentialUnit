(* Formal proof: proof-path pruning removes excluded dirs for
   src/utils/sabotage_verifier.py. Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import List.
Import ListNotations.
Require Import String.

Section SabotageVerifier.
  Definition excluded (d : string) : bool :=
    if String.eqb d "vendor" then true
    else if String.eqb d ".git" then true
    else if String.eqb d "__pycache__" then true
    else false.

  Fixpoint prune (dirs : list string) : list string :=
    match dirs with
    | nil => nil
    | h :: t => if excluded h then prune t else h :: prune t
    end.

  Theorem prune_removes_excluded : forall d dirs,
      excluded d = true -> ~ In d (prune dirs).
  Proof.
    intros d dirs H. induction dirs as [| h t IH]; simpl; intro Hin.
    - inversion Hin.
    - destruct (excluded h) eqn:Heq.
      + apply IH. exact Hin.
      + destruct Hin as [E | IN].
        * rewrite E in Heq. rewrite H in Heq. discriminate Heq.
        * apply IH in IN. exact IN.
  Qed.
End SabotageVerifier.
