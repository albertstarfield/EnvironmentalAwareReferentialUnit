--  earu-bcg_shared.ads — Shared BCG State Between Tasks
--
--  Provides a protected wrapper around BCG_Detection.BCG_State so the
--  800 Hz IMU task can push samples while the Monitor task consumes them.
--
--  ─────────────────────────────────────────────────────────────────────────
--  AXIOMS
--  A1. Protected actions run at ceiling priority; total PO lock time per
--      Monitor cycle MUST stay microseconds-scale to protect the 800 Hz
--      sampler from priority inversion.
--  A2. A torn/corrupted control state is detectable via the guard word
--      owned by Earu.BCG_Detection (THEORY T4 there).
--
--  THEORIES
--  T1. Snapshot-then-compute: copy the state under a short O(copy) action,
--      then run the O(5.9M-MAC) autocorrelation OUTSIDE any protected
--      action on the private copy (audit V1 fix — no more 8M MACs inside
--      the PO starving the sampler).
--
--  APPLICATIONS
--  P1. IMU task   : Push        (O(1), every sample, real-time)
--  P2. Monitor    : Snapshot    (O(32 KB copy), then Compute unlocked)
--     Monitor must report Corrupted / Saturation_Events verbosely.
--
--  CITATIONS
--  C1. PHYSICS_AND_ASSUMPTIONS.md §5 (BCG pipeline context).
--  C2. IEEE Std 1003.1b priority-ceiling semantics for protected objects.
--
--  TIMING ANALYSIS: Push < 200 ns; Snapshot ≈ 32 KB struct copy < 10 µs;
--  hardware assumption Apple M-series, single-core ceiling protocol.

--  NOTE (Ravenscar/W8 fix): SPARK_Mode intentionally OFF for this unit.
--  GNATprove requires Ravenscar profile for protected types (SPARK RM 9(2));
--  adding Ravenscar would break the existing tasking model project-wide.
--  The real SPARK'd logic lives in BCG_Detection and Mood_Inference, which
--  are SPARK_Mode => On and free of protected-type constructs.
--  This thin wrapper delegates to fully proved subprograms; runtime safety
--  is enforced by Integrity_Ok checks + Snapshot's Corrupted out parameter.

with Earu.BCG_Detection;

package Earu.BCG_Shared is

   protected BCG_Buffer is

      procedure Push (Ax, Ay, Az : Float);
      --  Feed one sanitized-boundary sample; delegates to
      --  BCG_Detection.Push_Sample, whose own Post establishes
      --  Integrity_Ok on the state it writes.
      --  NOTE (audit V5 fix): no Post aspect here - aspect expressions of
      --  protected operations cannot reference private-part components
      --  (State is declared below in the private part), and cross-call
      --  knowledge about PO state is not statically provable anyway.
      --  Runtime guarantees are enforced inside Push_Sample and re-checked
      --  defensively by Compute's own integrity gate.
      --  TIMING/WCET: O(1), < 250 ns incl. PO overhead.

      procedure Snapshot
        (Item      : out Earu.BCG_Detection.BCG_State;
         Corrupted : out Boolean);
      --  ATOMIC COPY of the whole detector state under one short protected
      --  action (audit V1 fix). Callers run BCG_Detection.Compute on the
      --  returned copy OUTSIDE the PO. If Corrupted is True the internal
      --  state was repaired via Reset and Item is the fresh safe state;
      --  callers MUST report the corruption verbosely (safety-fallback
      --  policy). PARITY/GUARD: checked here, recovery = structural reset.
      --  NOTE (audit V5 fix): documented guarantee only - see Push note;
      --  Compute independently re-validates Integrity_Ok before use.
      --  TIMING/WCET: ≈ 32 KB copy, < 10 µs @ 3 GHz.

      function Is_Ready return Boolean;
      --  True when >= 8000 samples buffered. O(1).

      function Buffered return Natural;
      --  Current sample count. O(1).

   private
      State : Earu.BCG_Detection.BCG_State;
   end BCG_Buffer;

end Earu.BCG_Shared;
