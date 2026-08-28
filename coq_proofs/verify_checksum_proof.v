(* Formal proof: folding checksum bounded for util/verify_checksum.py.
   A modular folding checksum over Z always lands in [0, 256).
   Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import List.
Import ListNotations.
Require Import ZArith.
Require Import Lia.
Open Scope Z_scope.

Section VerifyChecksum.
  Fixpoint checksum (l : list Z) : Z :=
    match l with
    | nil => 0
    | h :: t => (checksum t + h) mod 256
    end.

  Theorem checksum_bounded : forall l, 0 <= checksum l < 256.
  Proof.
    induction l as [| h t IH]; simpl.
    - lia.
  - assert (Hpos : 0 < 256) by lia.
    pose proof (Z.mod_pos_bound (checksum t + h) 256 Hpos).
    lia.
  Qed.
End VerifyChecksum.
