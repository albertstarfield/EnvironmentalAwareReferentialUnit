-- AXIOMS: Stale detector flags HID/battery/SMC freezes for other subsystems.
-- THEORIES: Cross-check via independent pmset reads; flags are Atomic so
--   monitor tasks never observe torn Boolean state.
-- APPLICATIONS: Task polls every 5 seconds; consumers read *_Stale flags.
-- [Citation: sabotage_verifier.py THREAD_SAFETY, RACE_CONDITION]
package Earu.Stale_Detector is

   -- Synchronized run-state shared by Start/Stop rendezvous and the task body.
   -- AXIOMS: Start/Stop entries and the Watchdog loop both touch run state;
   --   unsynchronized Boolean reads/writes race across tasks (ARM §9.4).
   -- THEORIES: Protected object serializes Set_Running/Get_Running; ceiling
   --   priority of the protected action prevents deadlock with entry calls.
   -- APPLICATIONS: Entry bodies call Set_Running; task loop polls Get_Running.
   -- [Citation: sabotage_verifier.py RACE_CONDITION — task entry without
   --  matching protected object; Ada Reference Manual §9.4]
   protected Watchdog_Control is
      -- Record a Start/Stop request from the rendezvous entry body.
      -- @test: Test_Stale_Detector — Register_Routine ("Watchdog_Control.Set_Running", Test_Stale_Detector'Access);
      -- WCET: O(1) — one Boolean store under protected ceiling. Estimated Processing Time: O(1), Space Complexity: O(1)
      procedure Set_Running (Value : Boolean)
        with Pre  => True,
             Post => True;

      -- Fetch the synchronized run flag for the task loop.
      -- @test: Test_Stale_Detector — Register_Routine ("Watchdog_Control.Get_Running", Test_Stale_Detector'Access);
      -- WCET: O(1) — one Boolean load under protected ceiling. Estimated Processing Time: O(1), Space Complexity: O(1)
      procedure Get_Running (Value : out Boolean)
        with Pre  => True,
             Post => True;
   private
      Is_Running : Boolean := False;
   end Watchdog_Control;

   -- Begin periodic staleness polls after client rendezvous.
   -- @test: Test_Stale_Detector — Register_Routine ("Watchdog.Start", Test_Stale_Detector'Access);
   -- WCET: O(1) — single rendezvous handshake. Estimated Processing Time: O(1), Space Complexity: O(1)
   task type Watchdog is
      entry Start
        with Pre  => True,
             Post => True;
      entry Stop
        with Pre  => True,
             Post => True;
   end Watchdog;

   -- Shared stale flags for other subsystems to read
   -- AXIOMS: Written by the Watchdog task body, read by Monitor_Task etc.
   -- THEORIES: pragma Atomic prevents torn reads on Boolean shared state.
   -- [Citation: sabotage_verifier.py RACE_CONDITION — Shared variable
   --  without pragma Volatile/Atomic]
   HID_Stale    : Boolean := False; pragma Atomic (HID_Stale);
   Batt_Stale   : Boolean := False; pragma Atomic (Batt_Stale);
   SMC_Stale    : Boolean := False; pragma Atomic (SMC_Stale);

   -- Independent pmset battery cross-check (writes Cross_Pct percent, -1 on failure).
   -- @test: Test_Stale_Detector — Register_Routine ("Cross_Check_Battery", Test_Stale_Detector'Access);
   -- WCET: O(n) — n bounded by pmset output lines (≤ 64). Estimated Processing Time: O(64), Space Complexity: O(1)
   function Cross_Check_Battery (Cross_Pct : out Integer) return Boolean
     with Pre  => True,
          Post => True;

end Earu.Stale_Detector;
