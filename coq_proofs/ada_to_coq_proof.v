(* Formal proof: Ada-to-Coq converter filename sanitization.
   The converter rewrites hyphens ('-', byte 45) to underscores ('_', byte 95)
   so that generated Coq proof filenames are accepted by coqc (which rejects
   hyphens in identifiers). Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import List.
Import ListNotations.
Require Import PeanoNat.
Require Import Lia.

Section AdaToCoq.
  (* Map a byte to a safe Coq-identifier byte: '-' (45) becomes '_' (95). *)
  Definition safe_byte (b : nat) : nat := if Nat.eq_dec b 45 then 95 else b.

  Fixpoint sanitize (s : list nat) : list nat :=
    match s with
    | nil => nil
    | h :: t => safe_byte h :: sanitize t
    end.

  Theorem safe_byte_no_hyphen : forall h, safe_byte h <> 45.
  Proof.
    intro h. unfold safe_byte.
    destruct (Nat.eq_dec h 45) as [Heq | Hne].
    - simpl. discriminate.
    - simpl. intro E. apply Hne. exact E.
  Qed.

  Theorem no_hyphen : forall s, ~ In 45 (sanitize s).
  Proof.
    induction s as [| h t IH]; simpl.
    - intro H. inversion H.
    - intro IN. destruct IN as [E | IN'].
      + apply safe_byte_no_hyphen with (h := h). exact E.
      + apply IH in IN'. exact IN'.
  Qed.
End AdaToCoq.
