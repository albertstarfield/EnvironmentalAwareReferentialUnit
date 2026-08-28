(* Formal proof: masked raw checksum bounded for util/verify_raw_checksum.py.
   An 8-bit masked folding checksum stays within [0, 255].
   Standard: DO-178C 5.2.2, ECSS-Q-ST-80C 6.3 *)
Require Import List.
Import ListNotations.
Require Import ZArith.
Require Import Lia.
Open Scope Z_scope.

Section VerifyRawChecksum.
  Fixpoint rchecksum (l : list Z) : Z :=
    match l with
    | nil => 0
    | h :: t => Z.land (rchecksum t + h) 255
    end.

  Lemma land255_mod : forall n, Z.land n 255 = n mod 256.
  Proof.
    intros n.
    replace 255 with (Z.ones 8) by (vm_compute; reflexivity).
    apply Z.land_ones. lia.
  Qed.

  Theorem rchecksum_bounded : forall l, 0 <= rchecksum l <= 255.
  Proof.
    induction l as [| h t IH]; simpl.
    - lia.
    - rewrite land255_mod.
      assert (Hpos : 0 < 256) by lia.
      pose proof (Z.mod_pos_bound (rchecksum t + h) 256 Hpos).
      lia.
  Qed.
End VerifyRawChecksum.
