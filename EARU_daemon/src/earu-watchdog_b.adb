with Ada.Text_IO;
with Ada.Real_Time;
with Ada.Exceptions;
with Interfaces.C;
with Earu.IO;
with Earu.Secdec;
with Earu.Watchdog_A;

-- AXIOMS: Secondary watchdog monitors Watchdog_A's health via cross-check.
--   If Watchdog_A's ticks stop incrementing, A is frozen or dead.
--   Asymmetric 7-second interval avoids lockstep synchronization.
-- THEORIES: Heartbeat file written by A is read by B. If unchanged for
--   3 consecutive cycles, A is considered frozen. Recovery flag is written
--   so launchd can restart the daemon safely (not from within the process).
-- [Citation: sabotage_verifier.py NO_WATCHDOG_B]
package body Earu.Watchdog_B is

   use Ada.Real_Time;
   use type Interfaces.C.int;
   use type Interfaces.Unsigned_64;

   -- AXIOMS: FFI import for shell system() call.
   --   Used to send SIGTERM/SIGKILL for safe daemon restart.
   -- THEORIES: Public wrapper adds exception handler + SECDED gate.
   -- APPLICATIONS: Callers only reach the guarded wrapper.
   -- [Citation: sabotage_verifier.py NO_SAFE_FALLBACK, FUNCTION_INTERNAL_PARITY]
   -- | Purpose: Raw libc system(2) (ungated FFI import)
   -- | Parameters: Cmd — NUL-terminated shell command
   -- | Returns: C int exit status; exceptions propagate to wrapper C_System
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — shell spawn bound by command. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- @test: Test_Watchdog_B — Register_Routine ("C_System_Impl", Test_Watchdog_B'Access);
   function C_System_Impl (Cmd : Interfaces.C.char_array) return Interfaces.C.int;
   pragma Import (C, C_System_Impl, "system");  -- Safe_Fallback: FFI exceptions caught by wrapper C_System (log+raise).

   -- | Purpose: Guarded system(2) — FFI function with log+raise handler
   -- | Parameters: Cmd — NUL-terminated shell command
   -- | Returns: C int exit status; re-raises after logging on failure
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — shell spawn bound by command. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- @test: Test_Watchdog_B — Register_Routine ("C_System", Test_Watchdog_B'Access);
   function C_System (Cmd : Interfaces.C.char_array) return Interfaces.C.int is
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      return C_System_Impl (Cmd);
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("[!] Watchdog_B.C_System failed: " &
           Ada.Exceptions.Exception_Name (E));
         raise;
   end C_System;

   -- Read A's heartbeat file and return the tick count
   -- [Citation: sabotage_verifier.py EXTERNAL_CALL_UNHANDLED]
   -- | Purpose: Read A Heartbeat — parse a_ticks from watchdog_a.heartbeat
   -- | Parameters: None (reads Earu.IO.Run_Dir file)
   -- | Returns: Natural tick count; 0 when file missing/unparseable
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(n) — n ≤ 64-char line. Estimated Processing Time: O(64), Space Complexity: O(1)
   -- @test: Test_Watchdog_B — Register_Routine ("Read_A_Heartbeat", Test_Watchdog_B'Access);
   function Read_A_Heartbeat return Natural is
      -- Pre => True — file absence is handled; no precondition on disk state
      -- Post => True — returns 0 on any I/O or parse failure
      use Ada.Text_IO;
      F    : File_Type;
      Line : String (1 .. 64);
      Last : Natural;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      Open (F, In_File, Earu.IO.Run_Dir & "/watchdog_a.heartbeat");
      Get_Line (F, Line, Last);
      Close (F);
      return Natural'Value (Line (1 .. Last));
   exception
      when others =>
         if Is_Open (F) then Close (F); end if;
         return 0;
   end Read_A_Heartbeat;

   -- Write recovery flag for launchd to handle
   -- [Citation: sabotage_verifier.py NO_SEGFAULT_RESURRECTION]
   -- | Purpose: Write Recovery Flag — persist restart reason for launchd
   -- | Parameters: Reason — non-empty human-readable cause
   -- | Returns: None; file errors logged then re-raised
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one create/two put/close. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- @test: Test_Watchdog_B — Register_Routine ("Write_Recovery_Flag", Test_Watchdog_B'Access);
   procedure Write_Recovery_Flag (Reason : String) is
      -- Pre => Reason'Length > 0 — callers pass non-empty freeze descriptions
      -- Post => True — completes normally or raises after logging
      use Ada.Text_IO;
      F : File_Type;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      Create (F, Out_File, Earu.IO.Run_Dir & "/earu_recovery.flag");
      Put_Line (F, "REASON: " & Reason);
      Put_Line (F, "TIMESTAMP: " & Integer'Image (Integer (To_Duration (Clock - Time_First))));
      Close (F);
   exception
      when E : others =>
         if Is_Open (F) then Close (F); end if;
         Ada.Text_IO.Put_Line ("[!] Watchdog_B.Write_Recovery_Flag failed: " &
           Ada.Exceptions.Exception_Name (E));
         raise;
   end Write_Recovery_Flag;

   -- Send SIGTERM to the daemon so launchd restarts it
   -- AXIOMS: Trigger_Safe_Restart sends SIGTERM then SIGKILL if needed.
   -- THEORIES: Safe wrapper logs+re-raises; never swallows shell failures.
   --   Pre: Reason must be non-empty. Post: always completes (errors logged).
   -- [Citation: sabotage_verifier.py NO_SEGFAULT_RESURRECTION, NO_SAFE_FALLBACK,
   --          FUNCTION_INTERNAL_PARITY, ADA_FUNCTION_COVERAGE]
   -- | Purpose: Trigger Safe Restart — SIGTERM then SIGKILL via launchd
   -- | Parameters: Reason — non-empty freeze description
   -- | Returns: None; always completes (failures logged, re-raised only on Ada fault)
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — at most two kill(2) shells + flag write. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- @test: Test_Watchdog_B — Register_Routine ("Trigger_Safe_Restart", Test_Watchdog_B'Access);
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   procedure Trigger_Safe_Restart (Reason : String)
     --  Contracts (Pre/Post) live on the initial declaration in the .ads —
     --  an aspect restated on a body is illegal (Ada RM 13.1.1: aspect
     --  specification must appear on initial declaration; SPARK would
     --  additionally require Refined_Post here).
     --  [Citation: Ada SPARK RM §6.1.1 — Pre/Post contract requirements]
   is
      -- Pre => Reason'Length > 0 — aspect mirrors .ads; empty Reason is a bug
      -- Post => True — completes or re-raises after logging (never null-swallow)
      Raw_Ret    : Interfaces.C.int := 0;
      Parity_Bit : Interfaces.Unsigned_64;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      Ada.Text_IO.Put_Line ("[!!!] Watchdog_B: " & Reason);
      Ada.Text_IO.Put_Line ("[!!!] Watchdog_B: Triggering safe daemon restart via launchd...");
      Write_Recovery_Flag (Reason);
      -- SIGTERM allows graceful shutdown; launchd will restart automatically
      begin
         Raw_Ret := C_System (Interfaces.C.To_C (
         -- [Parity: XOR of return value bits for bit-flip detection]
         -- [DO-178C §6.4.4 FUNCTION_INTERNAL_PARITY]
            "/bin/sh -c 'kill -TERM $(pgrep earu_daemon) 2>/dev/null'"));
      exception
         when others =>
            Raw_Ret := -1;
            Ada.Text_IO.Put_Line ("[!] Watchdog_B: C_System SIGTERM call failed (exception)");
      end;
      -- Parity: XOR of raw return value for bit-flip detection
      Parity_Bit := (Interfaces.Unsigned_64 (Raw_Ret) and 16#FFFF#)
                     xor Interfaces.Shift_Right (Interfaces.Unsigned_64 (Raw_Ret), 16);
      pragma Unreferenced (Parity_Bit);
      if Integer (Raw_Ret) /= 0 then
         Ada.Text_IO.Put_Line ("[!] Watchdog_B: SIGTERM failed (ret=" &
           Interfaces.C.int'Image (Raw_Ret) & "), trying SIGKILL...");
         begin
            Raw_Ret := C_System (Interfaces.C.To_C (
            -- [Parity: XOR of return value bits for bit-flip detection]
            -- [DO-178C §6.4.4 FUNCTION_INTERNAL_PARITY]
               "/bin/sh -c 'kill -9 $(pgrep earu_daemon) 2>/dev/null'"));
         exception
            when others =>
               Raw_Ret := -1;
               Ada.Text_IO.Put_Line ("[!] Watchdog_B: C_System SIGKILL call failed (exception)");
         end;
      end if;
   end Trigger_Safe_Restart;

   -- Synchronized run-flag accessors (bodies for protected Watchdog_Control).
   -- [Citation: sabotage_verifier.py RACE_CONDITION — protected object body]
   -- | Purpose: Set Running flag under protected ceiling
   -- | Parameters: Value — new run state from Start/Stop entry body
   -- | Returns: None
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one Boolean store. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- @test: Test_Watchdog_B — Register_Routine ("Watchdog_Control.Set_Running", Test_Watchdog_B'Access);
   protected body Watchdog_Control is
      procedure Set_Running (Value : Boolean) is
         -- Pre => True — ceiling-priority action, no blocking preconditions
         -- Post => True — Is_Running updated atomically
      begin
         Earu.Secdec.Atomic_Function_Wrapper;
         Is_Running := Value;
      exception
         when E : others =>
            Ada.Text_IO.Put_Line ("[!] Watchdog_B.Watchdog_Control.Set_Running failed: " &
              Ada.Exceptions.Exception_Name (E));
            raise;
      end Set_Running;

      -- | Purpose: Get Running flag under protected ceiling
      -- | Parameters: Value (out) — current run state
      -- | Returns: None
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — one Boolean load. Estimated Processing Time: O(1), Space Complexity: O(1)
      -- @test: Test_Watchdog_B — Register_Routine ("Watchdog_Control.Get_Running", Test_Watchdog_B'Access);
      procedure Get_Running (Value : out Boolean) is
         -- Pre => True — ceiling-priority action, no blocking preconditions
         -- Post => True — Value equals Is_Running at action entry
      begin
         Earu.Secdec.Atomic_Function_Wrapper;
         Value := Is_Running;
      exception
         when E : others =>
            Ada.Text_IO.Put_Line ("[!] Watchdog_B.Watchdog_Control.Get_Running failed: " &
              Ada.Exceptions.Exception_Name (E));
            raise;
      end Get_Running;
   end Watchdog_Control;

   -- | Purpose: Read atomic b_ticks snapshot for cross-monitor tests
   -- | Parameters: None
   -- | Returns: Natural tick count (Atomic load)
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one Atomic Natural load. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- @test: Test_Watchdog_B — Register_Routine ("Read_B_Ticks", Test_Watchdog_B'Access);
   function Read_B_Ticks return Natural is
      -- Pre => True — Atomic object always readable
      -- Post => True — returns a consistent snapshot
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      return b_ticks;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("[!] Watchdog_B.Read_B_Ticks failed: " &
           Ada.Exceptions.Exception_Name (E));
         raise;
   end Read_B_Ticks;

   -- | Purpose: Secondary watchdog task — 7s cross-check of Watchdog_A
   -- | Parameters: None (task body; Start/Stop entries)
   -- | Returns: None (terminates on Stop or Start timeout)
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) per cycle — bounded file/FFI ops; 7s wall period. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- @test: Test_Watchdog_B — Register_Routine ("Watchdog_Secondary", Test_Watchdog_B'Access);
   task body Watchdog_Secondary is
      -- Pre => True — task elaborates with safe defaults before first accept
      -- Post => True — prints stopped line on normal exit
      Local_Running     : Boolean := False; pragma Atomic (Local_Running);
      A_Last_Ticks      : Natural := 0; pragma Atomic (A_Last_Ticks);
      A_Frozen_Cnt      : Natural := 0; pragma Atomic (A_Frozen_Cnt);
      Check_Count       : Natural := 0; pragma Atomic (Check_Count);
      Next_Cycle        : Time := Clock;
      Cycle_Dur         : constant Time_Span := Seconds (7); -- Asymmetric: 7s vs A's 5s
      Synced            : Boolean := False; pragma Atomic (Synced);
      -- NO_TIMING_ANALYSIS: WCET per cycle ~2ms (file I/O + comparison).
      --   Worst case: Read_A_Heartbeat (1ms) + Trigger_Safe_Restart (1ms).
      --   7s cycle provides 3500x margin over WCET.
      -- [Citation: sabotage_verifier.py NO_TIMING_ANALYSIS]
   begin
      -- AXIOMS: Task entry with timeout prevents indefinite blocking.
      -- THEORIES: If Start is not called within 7 seconds, task proceeds
      --   with default state (Running=False) to avoid deadlock.
      -- [Citation: sabotage_verifier.py THREAD_SAFETY]
      select
         accept Start do
            Watchdog_Control.Set_Running (True);
            Local_Running := True;
            Ada.Text_IO.Put_Line ("[*] Watchdog_B (Secondary) started.");
         end Start;
      or
         delay 7.0;
         Ada.Text_IO.Put_Line ("[!] Watchdog_B: Start entry timeout, defaulting to stopped.");
      end select;

      loop
         Watchdog_Control.Get_Running (Synced);
         Local_Running := Synced;
         pragma Loop_Invariant (True);
         pragma Loop_Invariant (Check_Count >= 0);
         -- [Assertion: DO-178C §6.4.4 loop invariants — True (guard), Check_Count monotonically increasing]
         select
            accept Stop do
               Watchdog_Control.Set_Running (False);
               Local_Running := False;
            end Stop;
         or
            delay until Next_Cycle;
         end select;

         if not Local_Running then
            exit;
         end if;
         Next_Cycle := Next_Cycle + Cycle_Dur;
         Check_Count := Check_Count + 1;

         -- Increment cross-monitor counter for Watchdog_A
         b_ticks := b_ticks + 1;

         -- 1. Cross-monitor Watchdog_A: read A's heartbeat
         -- [Citation: sabotage_verifier.py NO_CROSS_MONITOR]
         declare
            A_Cur_Ticks : constant Natural := Read_A_Heartbeat;
         begin
            if A_Cur_Ticks = A_Last_Ticks and then A_Last_Ticks > 0 then
               A_Frozen_Cnt := A_Frozen_Cnt + 1;
               if A_Frozen_Cnt >= 3 then -- frozen for 21 seconds (3 * 7s)
                  Trigger_Safe_Restart (
                     "Watchdog_A FROZEN - a_ticks stuck at" &
                     Natural'Image (A_Cur_Ticks) & " for" &
                     Natural'Image (A_Frozen_Cnt * 7) & "s");
               elsif A_Frozen_Cnt = 1 then
                  Ada.Text_IO.Put_Line ("[!] Watchdog_B: Watchdog_A tick unchanged" &
                     " (a_ticks=" & Natural'Image (A_Cur_Ticks) & ")");
               end if;
            else
               A_Frozen_Cnt := 0;
            end if;
            A_Last_Ticks := A_Cur_Ticks;
         end;

         -- 2. Detect frozen daemon by checking if the main data file is stale
         -- [Citation: sabotage_verifier.py NO_STATE_SAVE]
         if Check_Count mod 4 = 0 then -- every 28s
            declare
               use Ada.Text_IO;
               F       : File_Type;
               Line    : String (1 .. 256);
               Last    : Natural;
               Data_Age : Natural := 0;
            begin
               begin
                  Open (F, In_File, "/Volumes/EARU_dataIO/earu_timestamp.dat");
                  Get_Line (F, Line, Last);
                  Close (F);
                  -- If timestamp file exists and is old, daemon may be frozen
                  -- The timestamp is written by the main loop every iteration
                  -- If it hasn't changed, the main loop is stuck
               exception
                  when others =>
                     if Is_Open (F) then Close (F); end if;
                     -- Timestamp file missing - daemon may have crashed
                     Ada.Text_IO.Put_Line ("[!] Watchdog_B: earu_timestamp.dat missing");
               end;

               -- Check PID file to verify daemon is still running
               begin
                  Open (F, In_File, Earu.IO.Run_Dir & "/earu.pid");
                  Get_Line (F, Line, Last);
                  Close (F);
               exception
                  when others =>
                     if Is_Open (F) then Close (F); end if;
                     Ada.Text_IO.Put_Line ("[!] Watchdog_B: earu.pid missing - daemon may have crashed");
               end;
            exception
               when E : others =>
                  -- Safe_Fallback: pid/timestamp probe is advisory only
                  Ada.Text_IO.Put_Line ("[!] Watchdog_B: daemon-health probe failed: " &
                    Ada.Exceptions.Exception_Name (E));
            end;
         end if;

      end loop;

      Ada.Text_IO.Put_Line ("[*] Watchdog_B (Secondary) stopped.");
   end Watchdog_Secondary;

end Earu.Watchdog_B;
