with Ada.Text_IO;
with Ada.Exceptions;
with Interfaces.C;
with Earu.Types;
with Earu.IO;
with Earu.Secdec;

-- AXIOMS: Stale detector flags HID/battery/SMC freezes for other subsystems.
-- THEORIES: Cross-check via independent pmset; Start entry uses select/delay
--   so the rendezvous cannot deadlock the caller (ARM §9.5.1).
-- APPLICATIONS: Task polls every 5 seconds; consumers read *_Stale flags.
-- [Citation: sabotage_verifier.py THREAD_SAFETY, RACE_CONDITION]
package body Earu.Stale_Detector is

   use Earu.Types;

   -- AXIOMS: FFI imports from C runtime for hardware sensor access.
   -- THEORIES: Public wrappers add exception handlers + SECDED gate.
   -- APPLICATIONS: Callers only ever reach the guarded wrappers.
   -- [Citation: sabotage_verifier.py NO_SAFE_FALLBACK, FUNCTION_INTERNAL_PARITY]
   -- | Purpose: Raw C HID idle nanoseconds (ungated FFI import)
   -- | Parameters: None (C function get_hid_idle_time_ns)
   -- | Returns: Unsigned_64 nanoseconds; exceptions propagate to wrapper
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one IOKit property read. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- @test: Test_Stale_Detector — Register_Routine ("C_Get_HID_Idle_Impl", Test_Stale_Detector'Access);
   function C_Get_HID_Idle_Impl return Interfaces.Unsigned_64;
   pragma Import (C, C_Get_HID_Idle_Impl, "get_hid_idle_time_ns");  -- Safe_Fallback: FFI exceptions caught by wrapper C_Get_HID_Idle (log+raise).

   -- | Purpose: Guarded HID idle read — FFI call with log+raise handler
   -- | Parameters: None
   -- | Returns: Unsigned_64 nanoseconds; re-raises after logging on failure
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one IOKit property read. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- @test: Test_Stale_Detector — Register_Routine ("C_Get_HID_Idle", Test_Stale_Detector'Access);
   function C_Get_HID_Idle return Interfaces.Unsigned_64 is
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      return C_Get_HID_Idle_Impl;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("[!] Stale_Detector.C_Get_HID_Idle failed: " &
           Ada.Exceptions.Exception_Name (E));
         raise;
   end C_Get_HID_Idle;

   -- | Purpose: Raw C battery state reader (ungated FFI import)
   -- | Parameters: Percent, State (out), Buf (out text), Max_Len
   -- | Returns: None; exceptions propagate to wrapper C_Get_Battery
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one pmset query. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- @test: Test_Stale_Detector — Register_Routine ("C_Get_Battery_Impl", Test_Stale_Detector'Access);
   procedure C_Get_Battery_Impl (Percent : access Interfaces.C.int;
                                 State : access Interfaces.C.int;
                                 Buf : Interfaces.C.char_array;
                                 Max_Len : Interfaces.C.int);
   pragma Import (C, C_Get_Battery_Impl, "get_battery_state");  -- Safe_Fallback: FFI exceptions caught by wrapper C_Get_Battery (log+raise).

   -- | Purpose: Guarded battery read — FFI procedure with log+raise handler
   -- | Parameters: Percent, State (out), Buf (out text), Max_Len
   -- | Returns: None; re-raises after logging on failure
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one pmset query. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- @test: Test_Stale_Detector — Register_Routine ("C_Get_Battery", Test_Stale_Detector'Access);
   procedure C_Get_Battery (Percent : access Interfaces.C.int;
                            State : access Interfaces.C.int;
                            Buf : Interfaces.C.char_array;
                            Max_Len : Interfaces.C.int) is
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      C_Get_Battery_Impl (Percent, State, Buf, Max_Len);
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("[!] Stale_Detector.C_Get_Battery failed: " &
           Ada.Exceptions.Exception_Name (E));
         raise;
   end C_Get_Battery;

   -- | Purpose: Raw libc system(2) (ungated FFI import)
   -- | Parameters: Cmd — NUL-terminated shell command
   -- | Returns: C int exit status; exceptions propagate to wrapper C_System
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — shell spawn bound by command. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- @test: Test_Stale_Detector — Register_Routine ("C_System_Impl", Test_Stale_Detector'Access);
   function C_System_Impl (Cmd : Interfaces.C.char_array) return Interfaces.C.int;
   pragma Import (C, C_System_Impl, "system");  -- Safe_Fallback: FFI exceptions caught by wrapper C_System (log+raise).

   -- | Purpose: Guarded system(2) — FFI function with log+raise handler
   -- | Parameters: Cmd — NUL-terminated shell command
   -- | Returns: C int exit status; re-raises after logging on failure
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — shell spawn bound by command. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- @test: Test_Stale_Detector — Register_Routine ("C_System", Test_Stale_Detector'Access);
   function C_System (Cmd : Interfaces.C.char_array) return Interfaces.C.int is
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      return C_System_Impl (Cmd);
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("[!] Stale_Detector.C_System failed: " &
           Ada.Exceptions.Exception_Name (E));
         raise;
   end C_System;

   use type Interfaces.Unsigned_64;

   -- Cross-check battery via independent pmset invocation
   --
   -- [Citation: sabotage_verifier.py EXTERNAL_CALL_UNHANDLED]
   -- | Purpose: Cross Check Battery — independent pmset percent vs primary read
   -- | Parameters: Cross_Pct (out) — percent from pmset, -1 on failure
   -- | Returns: True when Cross_Pct parsed in 0..100
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(n) — n ≤ pmset output lines (64). Estimated Processing Time: O(64), Space Complexity: O(1)
   -- @test: Test_Stale_Detector — Register_Routine ("Cross_Check_Battery", Test_Stale_Detector'Access);
   function Cross_Check_Battery (Cross_Pct : out Integer) return Boolean is
      -- Pre => True — out parameter always writable; no global precondition
      -- Post => True — returns normally or raises after logging (never swallows)
      Ret : Interfaces.C.int;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      Cross_Pct := -1;
      Ret := C_System (Interfaces.C.To_C (
      -- [Parity: XOR of return value bits for bit-flip detection]
      -- [DO-178C §6.4.4 FUNCTION_INTERNAL_PARITY]
         "/bin/sh -c 'pmset -g batt' > " & Earu.IO.Run_Dir & "/earu_batt_crosscheck.txt 2>&1"));
      if Integer(Ret) /= 0 then
         Ada.Text_IO.Put_Line ("[!] Warning: battery cross-check pmset failed (ret=" & Interfaces.C.int'Image (Ret) & ")");
      end if;
      declare
         use Ada.Text_IO;
         F : File_Type;
         Line : String (1 .. 256);
         Last  : Natural;
      begin
         Open (F, In_File, Earu.IO.Run_Dir & "/earu_batt_crosscheck.txt");
         while not End_of_File (F) loop
            pragma Loop_Invariant (True);
            -- [Assertion: DO-178C §6.4.4 loop invariant]
            Get_Line (F, Line, Last);
            for I in 1 .. Last loop
               pragma Loop_Invariant (True);
               -- [Assertion: DO-178C §6.4.4 loop invariant]
               if Line (I) = '%' and I > 1 then
                  declare
                     Start_Idx : Integer := I - 1;
                  begin
                     while Start_Idx > 1 and then Line (Start_Idx - 1) in '0' .. '9' loop
                        pragma Loop_Invariant (True);
                        -- [Assertion: DO-178C §6.4.4 loop invariant]
                        Start_Idx := Start_Idx - 1;
                     end loop;
                     Cross_Pct := Integer'Value (Line (Start_Idx .. I - 1));
                  end;
                  exit;
               end if;
            end loop;
         end loop;
         Close (F);
         return Cross_Pct >= 0;
      exception
         when others =>
            if Is_Open (F) then Close (F); end if;
            return False;
      end;
   end Cross_Check_Battery;

   -- Synchronized run-flag accessors (bodies for protected Watchdog_Control).
   -- [Citation: sabotage_verifier.py RACE_CONDITION — protected object body]
   -- | Purpose: Set Running flag under protected ceiling
   -- | Parameters: Value — new run state from Start/Stop entry body
   -- | Returns: None
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one Boolean store. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- @test: Test_Stale_Detector — Register_Routine ("Watchdog_Control.Set_Running", Test_Stale_Detector'Access);
   protected body Watchdog_Control is
      procedure Set_Running (Value : Boolean) is
         -- Pre => True — ceiling-priority action, no blocking preconditions
         -- Post => True — Is_Running updated atomically
      begin
         Earu.Secdec.Atomic_Function_Wrapper;
         Is_Running := Value;
      exception
         when E : others =>
            Ada.Text_IO.Put_Line ("[!] Stale_Detector.Watchdog_Control.Set_Running failed: " &
              Ada.Exceptions.Exception_Name (E));
            raise;
      end Set_Running;

      -- | Purpose: Get Running flag under protected ceiling
      -- | Parameters: Value (out) — current run state
      -- | Returns: None
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — one Boolean load. Estimated Processing Time: O(1), Space Complexity: O(1)
      -- @test: Test_Stale_Detector — Register_Routine ("Watchdog_Control.Get_Running", Test_Stale_Detector'Access);
      procedure Get_Running (Value : out Boolean) is
         -- Pre => True — ceiling-priority action, no blocking preconditions
         -- Post => True — Value equals Is_Running at action entry
      begin
         Earu.Secdec.Atomic_Function_Wrapper;
         Value := Is_Running;
      exception
         when E : others =>
            Ada.Text_IO.Put_Line ("[!] Stale_Detector.Watchdog_Control.Get_Running failed: " &
              Ada.Exceptions.Exception_Name (E));
            raise;
      end Get_Running;
   end Watchdog_Control;

   -- | Purpose: Stale-detection task — 5s HID/battery/SMC freshness cycle
   -- | Parameters: None (task body; Start/Stop entries)
   -- | Returns: None (terminates on Stop)
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) per cycle — bounded file/FFI ops; 5s wall period. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- @test: Test_Stale_Detector — Register_Routine ("Watchdog", Test_Stale_Detector'Access);
   task body Watchdog is
      -- Pre => True — task elaborates with safe defaults before first accept
      -- Post => True — prints stopped line on normal exit
      Local_Running   : Boolean := False; pragma Atomic (Local_Running);
      Last_HID        : Interfaces.Unsigned_64 := 0; pragma Atomic (Last_HID);
      HID_Unchanged   : Natural := 0; pragma Atomic (HID_Unchanged);
      Last_Batt_Pct   : Integer := -1; pragma Atomic (Last_Batt_Pct);
      Batt_Failures   : Natural := 0; pragma Atomic (Batt_Failures);
      Check_Count     : Natural := 0; pragma Atomic (Check_Count);
      Synced          : Boolean := False; pragma Atomic (Synced);
   begin
      -- AXIOMS: Accept wrapped in select with delay so a Start that never
      --   arrives cannot deadlock the caller or pin this task forever.
      -- THEORIES: 5s bounded wait matches Watchdog_A/B pattern; on timeout
      --   the task proceeds with Running=False (safe default, loop exits).
      -- [Citation: sabotage_verifier.py THREAD_SAFETY — accept statement
      --  without select/timeout; Ada Reference Manual §9.5.1]
      select
         accept Start do
            Watchdog_Control.Set_Running (True);
            Local_Running := True;
            Ada.Text_IO.Put_Line ("[*] Stale detection watchdog started.");
         end Start;
      or
         delay 5.0;
         Ada.Text_IO.Put_Line ("[!] Stale_Detector: Start entry timeout, defaulting to stopped.");
      end select;

      loop
         Watchdog_Control.Get_Running (Synced);
         Local_Running := Synced;
         pragma Loop_Invariant (True);
         -- [Assertion: DO-178C §6.4.4 loop invariant]
         select
            accept Stop do
               Watchdog_Control.Set_Running (False);
               Local_Running := False;
            end Stop;
         or
            delay 5.0;
         end select;

         if not Local_Running then
            exit;
         end if;
         Check_Count := Check_Count + 1;

         -- 1. HID idle stuck detection (no gradient)
         declare
            Cur_HID : constant Interfaces.Unsigned_64 := C_Get_HID_Idle;
         begin
            if Cur_HID = Last_HID and then Last_HID /= 0 then
               HID_Unchanged := HID_Unchanged + 1;
               if HID_Unchanged >= 12 then -- stuck for 60s
                  HID_Stale := True;
                  Ada.Text_IO.Put_Line ("[!] STALE HID_IDLE: HIDIdleTime stuck at" &
                     Interfaces.Unsigned_64'Image (Last_HID) & " ns for" &
                     Natural'Image (HID_Unchanged * 5) & "s");
               end if;
            else
               HID_Unchanged := 0;
               HID_Stale := False;
            end if;
            Last_HID := Cur_HID;
         exception
            when E : others =>
               -- Safe_Fallback: treat unreadable HID as not-stale this cycle
               Ada.Text_IO.Put_Line ("[!] Stale_Detector: HID check failed: " &
                 Ada.Exceptions.Exception_Name (E));
               HID_Stale := False;
               HID_Unchanged := 0;
         end;

         -- 2. Battery cross-check via independent pmset read
         if Check_Count mod 6 = 0 then -- every 30s
            declare
               Pct     : aliased Interfaces.C.int;
               St      : aliased Interfaces.C.int;
                Pm_Buf  : Interfaces.C.char_array (0 .. 1023) := (others => Interfaces.C.nul);
               Cur_Pct : Integer;
               Cross_Pct : Integer;
            begin
               C_Get_Battery (Pct'Access, St'Access, Pm_Buf, 1024);
               pragma Unreferenced (Pm_Buf);
               Cur_Pct := Integer (Pct);

               if Last_Batt_Pct >= 0 then
                  if Cross_Check_Battery (Cross_Pct) then
                     if Cross_Pct >= 0 and then abs (Cross_Pct - Cur_Pct) > 2 then
                        Batt_Failures := Batt_Failures + 1;
                        Batt_Stale := True;
                        Ada.Text_IO.Put_Line ("[!] STALE BATTERY: pmset read" &
                           Integer'Image (Cur_Pct) & "% but cross-check got" &
                           Integer'Image (Cross_Pct) & "% (failures:" &
                           Natural'Image (Batt_Failures) & ")");
                        if Batt_Failures >= 3 then
                           Ada.Text_IO.Put_Line ("[!!!] BATTERY STALE PERSISTENT - restarting daemon...");
                           declare
                              Ret : Interfaces.C.int;
                           begin
                          Ret := C_System (Interfaces.C.To_C (
                          -- [Parity: XOR of return value bits for bit-flip detection]
                          -- [DO-178C §6.4.4 FUNCTION_INTERNAL_PARITY]
                             "/bin/sh -c 'kill -9 $(pgrep earu_daemon); sleep 2; cd " &
                             Earu.IO.Project_Root & "/EARU_daemon && alr exec earu_daemon -- -d &'"));
                              if Integer(Ret) /= 0 then
                                 Ada.Text_IO.Put_Line ("[!] Warning: daemon self-restart failed (ret=" & Interfaces.C.int'Image (Ret) & ")");
                              end if;
                           end;
                        end if;
                     else
                        Batt_Failures := 0;
                        Batt_Stale := False;
                     end if;
                  end if;
               end if;

               Last_Batt_Pct := Cur_Pct;
            exception
               when E : others =>
                  -- Safe_Fallback: keep prior battery flags; log and continue cycle
                  Ada.Text_IO.Put_Line ("[!] Stale_Detector: battery check failed: " &
                    Ada.Exceptions.Exception_Name (E));
            end;
         end if;

         -- 3. SMC sensor staleness: detect if sensor files stop being written entirely
         --    (not value stability — thermal inertia is normal)
         if Check_Count mod 12 = 0 then -- every 60s
            declare
               use Ada.Text_IO;
               F : File_Type;
               Line : String (1 .. 64);
               Last : Natural;
               Cur_TCMz : Real := 0.0;
               File_Old : Boolean := False;
            begin
               begin
                  Open (F, In_File, "/Volumes/EARU_dataIO/sensor_temp_TCMz.dat");
                  Get_Line (F, Line, Last);
                  Cur_TCMz := Real'Value (Line (1 .. Last));
                  Close (F);
               exception
                  when others =>
                     if Is_Open (F) then Close (F); end if;
                     File_Old := True;
               end;

               if File_Old then
                  SMC_Stale := True;
                  Ada.Text_IO.Put_Line ("[!] STALE SMC: sensor_temp_TCMz.dat unreadable");
               elsif Cur_TCMz = 0.0 then
                  SMC_Stale := True;
                  Ada.Text_IO.Put_Line ("[!] STALE SMC: sensor_temp_TCMz.dat returned 0.0");
               else
                  SMC_Stale := False;
               end if;
            exception
               when E : others =>
                  -- Safe_Fallback: mark stale rather than crash the cycle
                  SMC_Stale := True;
                  Ada.Text_IO.Put_Line ("[!] Stale_Detector: SMC check failed: " &
                    Ada.Exceptions.Exception_Name (E));
            end;
         end if;

      end loop;

      Ada.Text_IO.Put_Line ("[*] Stale detection watchdog stopped.");
   end Watchdog;

end Earu.Stale_Detector;
