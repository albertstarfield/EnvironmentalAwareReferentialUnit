--  earu-bcg_shared.adb — Shared BCG State Between Tasks (implementation)
--
--  See earu-bcg_shared.ads for axioms/theories/applications/citations and
--  per-operation timing blocks. Implementation notes only are repeated here.

--  NOTE (Ravenscar fix): SPARK_Mode intentionally OFF for this unit.
--  The body inherits the spec's project-wide Off default. The real SPARK'd
--  logic delegates to BCG_Detection.Push_Sample and BCG_Detection.Compute,
--  which are SPARK_Mode => On and fully contracted.

package body Earu.BCG_Shared is

   protected body BCG_Buffer is

      procedure Push (Ax, Ay, Az : Float) is
      begin
         --  All Murphy boundary validation lives in BCG_Detection.Push_
         --  Sample (NaN rejection, axis clamps, guard-word refresh).
         Earu.BCG_Detection.Push_Sample (State, Ax, Ay, Az);
      end Push;

      procedure Snapshot
        (Item      : out Earu.BCG_Detection.BCG_State;
         Corrupted : out Boolean)
      is
      begin
         if Earu.BCG_Detection.Integrity_Ok (State) then
            Corrupted := False;
         else
            --  RECOVERY MECHANISM (audit W6/V5): guard-word mismatch means
            --  torn control state; self-heal structurally and tell the
            --  caller loudly instead of propagating poison downstream.
            Corrupted := True;
            Earu.BCG_Detection.Reset (State);
         end if;

         Item := State;   --  single short atomic copy (< 10 µs, AXIOM A1)
      end Snapshot;

      function Is_Ready return Boolean is
      begin
         return Earu.BCG_Detection.Ready (State);
      end Is_Ready;

      function Buffered return Natural is
      begin
         return Earu.BCG_Detection.Samples_Buffered (State);
      end Buffered;

   end BCG_Buffer;

end Earu.BCG_Shared;
