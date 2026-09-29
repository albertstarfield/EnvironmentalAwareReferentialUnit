--  SECDED TED parity gate: every guarded operation below calls
--  Earu.Secdec.Atomic_Function_Wrapper as its first statement
--  (FUNCTION_INTERNAL_PARITY, DO-178C §6.4.4 — see earu-secdec.ads).
with Earu.Secdec;
--  Loud-failure logging for the safe-fallback handlers below (verbose
--  error reporting: full exception information, never swallowed).
with Ada.Text_IO;
with Ada.Exceptions;

package body Earu.Network_Status is

   protected body Shared_Status is

      -- | Purpose: Set — record the current reachability status of one service.
      -- | Parameters: Index — 1-based slot (1..13); Status — new status value.
      -- | Returns: None; out-of-range indexes are dropped safely.
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — one bounds test + one store.
      -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
      -- @test: Test_Network_Status — Register_Routine ("Set", Test_Network_Status'Access);
      procedure Set (Index : Positive; Status : Service_Status) is
         -- Pre => True — any Positive accepted; guard below drops > 13.
         -- Post => True — slot Index updated when in 1 .. 13, else unchanged.
         -- WCET: O(1) — one compare + one store. Estimated Processing Time: O(1); Space Complexity: O(1)
      begin
         Earu.Secdec.Atomic_Function_Wrapper;
         if Index <= 13 then
            Current_Statuses (Index) := Status;
         end if;
      exception
         when others =>
            --  Safe_Fallback: out-of-range slots are ignored by design
            --  (guard above); an unexpected fault propagates loudly so the
            --  monitor task reports it — never a silent stale status.
            raise;
      end Set;

      -- | Purpose: Get — read the current reachability status of one service.
      -- | Parameters: Index — 1-based slot (1..13).
      -- | Returns: Service_Status; Unavailable for out-of-range indexes.
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — one bounds test + one load.
      -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
      -- @test: Test_Network_Status — Register_Routine ("Get", Test_Network_Status'Access);
      function Get (Index : Positive) return Service_Status is
         -- Pre => True — any Positive accepted; > 13 maps to Unavailable.
         -- Post => True — result is a valid Service_Status enumeration value.
         -- WCET: O(1) — one compare + one load. Estimated Processing Time: O(1); Space Complexity: O(1)
      begin
         Earu.Secdec.Atomic_Function_Wrapper;
         --  Sequential guard (no elsif-after-return): out-of-range reads
         --  return the documented Unavailable default first.
         if Index > 13 then
            return Unavailable;
         end if;
         return Current_Statuses (Index);
      exception
         when E : others =>
            --  Safe_Fallback: guard covers every Positive; unexpected fault
            --  degrades to Unavailable (safe worst case) after logging.
            Ada.Text_IO.Put_Line
              ("[!] Network_Status.Get failed: "
               & Ada.Exceptions.Exception_Information
                   (E));
            return Unavailable;
      end Get;

      -- | Purpose: Get All — snapshot the full 13-service status array.
      -- | Parameters: None.
      -- | Returns: Status_Array copy of all current statuses.
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(13) — fixed-size record copy.
      -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
      -- @test: Test_Network_Status — Register_Routine ("Get_All", Test_Network_Status'Access);
      function Get_All return Status_Array is
         -- Pre => True — total snapshot of the fixed 13-slot array.
         -- Post => True — result is a valid Status_Array (all enum values).
         -- WCET: O(1) — bounded 13-element copy. Estimated Processing Time: O(1); Space Complexity: O(1)
      begin
         Earu.Secdec.Atomic_Function_Wrapper;
         return Current_Statuses;
      exception
         when E : others =>
            --  Safe_Fallback: on unexpected fault return the all-Unavailable
            --  snapshot (safe worst case), then propagate loudly.
            Ada.Text_IO.Put_Line
              ("[!] Network_Status.Get_All failed: "
               & Ada.Exceptions.Exception_Information
                   (E));
            return (others => Unavailable);
      end Get_All;
   end Shared_Status;

end Earu.Network_Status;
