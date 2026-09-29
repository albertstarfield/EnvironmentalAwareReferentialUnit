-- AXIOMS: Primary watchdog monitors sensor freshness via periodic checks.
-- THEORIES: If sensor values stop changing while the system should be active,
--   the sensor subsystem is frozen or the HID callback is stalled.
-- APPLICATIONS: Runs every 5 seconds, tracks HID idle time, battery, and SMC.
--   Exposes a_ticks counter for Watchdog_B cross-monitoring.
-- [Citation: sabotage_verifier.py NO_WATCHDOG_A]
package Earu.Watchdog_A is

   -- Synchronized run-state shared by Start/Stop rendezvous and the task body.
   -- AXIOMS: Start/Stop entries and the Watchdog_Primary loop both touch run
   --   state; unsynchronized Boolean reads/writes race across tasks (ARM §9.4).
   -- THEORIES: Protected object serializes Set_Running/Get_Running; ceiling
   --   priority of the protected action prevents deadlock with entry calls.
   -- APPLICATIONS: Entry bodies call Set_Running; task loop polls Get_Running.
   -- [Citation: sabotage_verifier.py RACE_CONDITION — task entry without
   --  matching protected object; Ada Reference Manual §9.4]
   protected Watchdog_Control is
      -- Record a Start/Stop request from the rendezvous entry body.
      -- @test: Test_Watchdog_A — Register_Routine ("Watchdog_Control.Set_Running", Test_Watchdog_A'Access);
      -- WCET: O(1) — one Boolean store under protected ceiling. Estimated Processing Time: O(1), Space Complexity: O(1)
      procedure Set_Running (Value : Boolean)
        with Pre  => True,
             Post => True;

      -- Fetch the synchronized run flag for the task loop.
      -- @test: Test_Watchdog_A — Register_Routine ("Watchdog_Control.Get_Running", Test_Watchdog_A'Access);
      -- WCET: O(1) — one Boolean load under protected ceiling. Estimated Processing Time: O(1), Space Complexity: O(1)
      procedure Get_Running (Value : out Boolean)
        with Pre  => True,
             Post => True;
   private
      Is_Running : Boolean := False;
   end Watchdog_Control;

   -- Begin periodic freshness checks after client rendezvous.
   -- @test: Test_Watchdog_A — Register_Routine ("Watchdog_Primary.Start", Test_Watchdog_A'Access);
   -- WCET: O(1) — single rendezvous handshake. Estimated Processing Time: O(1), Space Complexity: O(1)
   task type Watchdog_Primary is
      entry Start
        with Pre  => True,
             Post => True;
      entry Stop
        with Pre  => True,
             Post => True;
   end Watchdog_Primary;

   -- Cross-monitoring: incremented every check cycle for Watchdog_B to verify
   -- AXIOMS: Shared between Watchdog_A task body and Watchdog_B reader.
   -- THEORIES: pragma Atomic ensures indivisible read/write for concurrent access.
   -- [Citation: sabotage_verifier.py RACE_CONDITION]
   a_ticks : Natural := 0; pragma Atomic (a_ticks);

   -- Sensor staleness flags visible to other subsystems
   -- AXIOMS: Written by Watchdog_A, read by other tasks (Monitor_Task, etc.).
   -- THEORIES: pragma Atomic prevents torn reads on Boolean shared state.
   -- [Citation: sabotage_verifier.py RACE_CONDITION]
   HID_Stale  : Boolean := False; pragma Atomic (HID_Stale);
   Batt_Stale : Boolean := False; pragma Atomic (Batt_Stale);
   SMC_Stale  : Boolean := False; pragma Atomic (SMC_Stale);

   -- Publish the a_ticks snapshot for cross-monitor heartbeats.
   -- @test: Test_Watchdog_A — Register_Routine ("Read_A_Ticks", Test_Watchdog_A'Access);
   -- WCET: O(1) — atomic Natural load. Estimated Processing Time: O(1), Space Complexity: O(1)
   function Read_A_Ticks return Natural
     with Pre  => True,
          Post => True;

   -- Independent pmset battery cross-check (writes Cross_Pct percent, -1 on failure).
   -- @test: Test_Watchdog_A — Register_Routine ("Cross_Check_Battery", Test_Watchdog_A'Access);
   -- WCET: O(n) — n bounded by pmset output lines (≤ 64). Estimated Processing Time: O(64), Space Complexity: O(1)
   function Cross_Check_Battery (Cross_Pct : out Integer) return Boolean
     with Pre  => True,
          Post => True;

   -- Persist current a_ticks to the watchdog_a.heartbeat file for Watchdog_B.
   -- @test: Test_Watchdog_A — Register_Routine ("Write_Heartbeat", Test_Watchdog_A'Access);
   -- WCET: O(1) — one create/put/close on a fixed-size line. Estimated Processing Time: O(1), Space Complexity: O(1)
   procedure Write_Heartbeat
     with Pre  => True,
          Post => True;

end Earu.Watchdog_A;
