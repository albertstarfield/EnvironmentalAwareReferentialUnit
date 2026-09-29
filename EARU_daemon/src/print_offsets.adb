with Ada.Text_IO; use Ada.Text_IO;
with Earu.Shm; use Earu.Shm;
with Earu.Secdec;
with Ada.Exceptions;

-- Purpose: Utility procedure to print the memory layout offsets of shared
--          memory record types (Stats_SHM, Weather_SHM) for debugging
--          cross-language shared memory alignment.
-- Returns: None (procedure)
-- WCET: O(1) — fixed offset prints. Estimated Processing Time: O(1), Space Complexity: O(1)
-- [Timing: DO-178C §6.4.4 WCET analysis]
-- @test: Test_Print_Offsets — Register_Routine ("Print_Offsets", Test_Print_Offsets'Access);
procedure Print_Offsets is
   -- Pre => True — standalone diagnostic; no inputs, no preconditions
   -- Post => True — all record offsets printed to standard output
   -- WCET: O(1) — 18 Put_Line calls, fixed strings. Estimated Processing Time: O(1), Space Complexity: O(1)
   pragma Warnings (Off);
   S : Stats_SHM;
   W : Weather_SHM;
   pragma Warnings (On);
begin
   Earu.Secdec.Atomic_Function_Wrapper;  -- [FUNCTION_INTERNAL_PARITY: SECDED TED gate, DO-178C §6.4.4]
   Put_Line ("Stats_SHM Total Size: " & S'Size'Img);
   Put_Line ("Header offset: " & S.Header'Position'Img);
   Put_Line ("CPU_Usage offset: " & S.CPU_Usage'Position'Img);
   Put_Line ("T_CPU_ns offset: " & S.T_CPU_ns'Position'Img);
   Put_Line ("SMC_PSTR offset: " & S.SMC_PSTR'Position'Img);
   Put_Line ("Bat_Design_Wh offset: " & S.Bat_Design_Wh'Position'Img);
   Put_Line ("Load_Avg_1 offset: " & S.Load_Avg_1'Position'Img);
   Put_Line ("HID_Idle_ns offset: " & S.HID_Idle_ns'Position'Img);
   Put_Line ("TS_ISO offset: " & S.TS_ISO'Position'Img);
   Put_Line ("PMSET_Info offset: " & S.PMSET_Info'Position'Img);

   Put_Line ("Weather_SHM Total Size: " & W'Size'Img);
   Put_Line ("Grid offset: " & W.Grid'Position'Img);
   Put_Line ("Meteo_JSON offset: " & W.Meteo_JSON'Position'Img);
exception
   when E : others =>
      Ada.Text_IO.Put_Line ("[!] Print_Offsets failed: " &
        Ada.Exceptions.Exception_Name (E));
      raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
end Print_Offsets;
