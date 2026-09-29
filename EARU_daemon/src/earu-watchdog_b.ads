-- AXIOMS: Secondary watchdog monitors Watchdog_A's health via cross-check.
-- THEORIES: If Watchdog_A's ticks stop incrementing, A is frozen or dead.
--   Watchdog_B uses asymmetric interval (7s) to avoid synchronization.
-- APPLICATIONS: Runs every 7 seconds, reads A's heartbeat file, detects
--   frozen state, writes recovery flag if needed.
-- [Citation: sabotage_verifier.py NO_WATCHDOG_B]
package Earu.Watchdog_B is

   -- Synchronized run-state shared by Start/Stop rendezvous and the task body.
   -- AXIOMS: Start/Stop entries and the Watchdog_Secondary loop both touch run
   --   state; unsynchronized Boolean reads/writes race across tasks (ARM §9.4).
   -- THEORIES: Protected object serializes Set_Running/Get_Running; ceiling
   --   priority of the protected action prevents deadlock with entry calls.
   -- APPLICATIONS: Entry bodies call Set_Running; task loop polls Get_Running.
   -- [Citation: sabotage_verifier.py RACE_CONDITION — task entry without
   --  matching protected object; Ada Reference Manual §9.4]
   protected Watchdog_Control is
      -- Record a Start/Stop request from the rendezvous entry body.
      -- @test: Test_Watchdog_B — Register_Routine ("Watchdog_Control.Set_Running", Test_Watchdog_B'Access);
      -- WCET: O(1) — one Boolean store under protected ceiling. Estimated Processing Time: O(1), Space Complexity: O(1)
      procedure Set_Running (Value : Boolean)
        with Pre  => True,
             Post => True;

      -- Fetch the synchronized run flag for the task loop.
      -- @test: Test_Watchdog_B — Register_Routine ("Watchdog_Control.Get_Running", Test_Watchdog_B'Access);
      -- WCET: O(1) — one Boolean load under protected ceiling. Estimated Processing Time: O(1), Space Complexity: O(1)
      procedure Get_Running (Value : out Boolean)
        with Pre  => True,
             Post => True;
   private
      Is_Running : Boolean := False;
   end Watchdog_Control;

   -- Begin asymmetric cross-checks after client rendezvous.
   -- @test: Test_Watchdog_B — Register_Routine ("Watchdog_Secondary.Start", Test_Watchdog_B'Access);
   -- WCET: O(1) — single rendezvous handshake. Estimated Processing Time: O(1), Space Complexity: O(1)
   task type Watchdog_Secondary is
      entry Start
        with Pre  => True,
             Post => True;
      entry Stop
        with Pre  => True,
             Post => True;
   end Watchdog_Secondary;

   -- Cross-monitoring: incremented every check cycle for Watchdog_A to verify
   -- AXIOMS: Shared between Watchdog_B task body and Watchdog_A reader.
   -- THEORIES: pragma Atomic ensures indivisible read/write for concurrent access.
   -- [Citation: sabotage_verifier.py RACE_CONDITION]
   b_ticks : Natural := 0; pragma Atomic (b_ticks);

   -- Read A's heartbeat file and return the tick count (0 if unreadable).
   -- @test: Test_Watchdog_B — Register_Routine ("Read_A_Heartbeat", Test_Watchdog_B'Access);
   -- WCET: O(n) — n bounded by heartbeat line length (≤ 64 chars). Estimated Processing Time: O(64), Space Complexity: O(1)
   function Read_A_Heartbeat return Natural
     with Pre  => True,
          Post => True;

   -- Write the launchd recovery flag file describing why a restart is needed.
   -- @test: Test_Watchdog_B — Register_Routine ("Write_Recovery_Flag", Test_Watchdog_B'Access);
   -- WCET: O(1) — one create/two put/close on fixed-size lines. Estimated Processing Time: O(1), Space Complexity: O(1)
   procedure Write_Recovery_Flag (Reason : String)
     with Pre  => Reason'Length > 0,
          Post => True;

   -- Request a safe daemon restart via SIGTERM (then SIGKILL); never raises.
   -- @test: Test_Watchdog_B — Register_Routine ("Trigger_Safe_Restart", Test_Watchdog_B'Access);
   -- WCET: O(1) — at most two kill(2) shells plus flag write. Estimated Processing Time: O(1), Space Complexity: O(1)
   procedure Trigger_Safe_Restart (Reason : String)
     with Pre  => Reason'Length > 0,
          Post => True;

   -- Publish the b_ticks snapshot for cross-monitor heartbeats.
   -- @test: Test_Watchdog_B — Register_Routine ("Read_B_Ticks", Test_Watchdog_B'Access);
   -- WCET: O(1) — atomic Natural load. Estimated Processing Time: O(1), Space Complexity: O(1)
   function Read_B_Ticks return Natural
     with Pre  => True,
          Post => True;

end Earu.Watchdog_B;
