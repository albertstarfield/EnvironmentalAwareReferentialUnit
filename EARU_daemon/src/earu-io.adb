with Ada.Text_IO;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Exceptions;
with Interfaces;
with Interfaces.C.Strings;
with GNAT.SHA256;

with Earu.Weather_Fetcher;
with System;

   -- =========================================================================
   -- TECHNICAL NOTE: Telemetry Integrity and Hashing Fixes (2026-05-28)
   -- =========================================================================
   -- Switched from Ada.Text_IO to Ada.Streams.Stream_IO for writing 
   -- EARU_data.dat. This ensures that the JSON payload is written as raw bytes, 
   -- preventing double-encoding of UTF-8 characters (like the vibration symbol) 
   -- which was the root cause of the parity failure in smc_daemon.
   -- =========================================================================

package body Earu.IO is
   use Earu.Types;
   use type System.Address;
   use type Interfaces.Unsigned_8;
   use Ada.Strings.Unbounded;

   package Real_IO is new Ada.Text_IO.Float_IO (Real);

   function F (R : Real) return String is
      S : String (1 .. 128) := (others => ' ');
      Last : Natural;
   begin
      if not R'Valid or else R /= R then
         return "null";
      end if;
      if R = 0.0 then return "0.0"; end if;
      if Abs (R) >= 1.0E-4 and then Abs (R) < 1.0E16 then
         Real_IO.Put (S, R, Aft => 16, Exp => 0);
         Last := S'Last;
         while Last > S'First and then S (Last) = ' ' loop Last := Last - 1; end loop;
         declare
             Str : constant String := Ada.Strings.Fixed.Trim (S (S'First .. Last), Ada.Strings.Both);
             Dot : Natural := 0;
         begin
            for I in Str'Range loop
               if Str(I) = '.' then Dot := I; exit; end if;
            end loop;
            if Dot > 0 then
               Last := Str'Last;
               while Last > Dot + 1 and then Str (Last) = '0' loop Last := Last - 1; end loop;
               return Str (Str'First .. Last);
            else
               return Str & ".0";
            end if;
         end;
      else
         Real_IO.Put (S, R, Aft => 15, Exp => 2);
         Last := S'Last;
         while Last > S'First and then S (Last) = ' ' loop Last := Last - 1; end loop;
         declare
             Trimmed : constant String := Ada.Strings.Fixed.Trim (S (S'First .. Last), Ada.Strings.Both);
             Str     : String (Trimmed'Range) := Trimmed;
          begin
             for I in Str'Range loop
                if Str(I) = 'E' then Str(I) := 'e'; end if;
             end loop;
             return Str;
          end;
      end if;
   end F;

   function B (Val : Boolean) return String is
   begin
      return (if Val then "true" else "false");
   end B;

   function YN (Val : Boolean) return String is
   begin
      return (if Val then """Yes""" else """No""");
   end YN;

   function Trim_Null (Str : String) return String is
      Last : Natural := Str'First - 1;
   begin
      for I in Str'Range loop
         if Str (I) /= Character'Val (0) and then Str (I) /= ' ' then
            Last := I;
         elsif Str (I) = Character'Val (0) then
            exit;
         end if;
      end loop;
      if Last < Str'First then return ""; else return Str (Str'First .. Last); end if;
   end Trim_Null;

   function C_System (Command : Interfaces.C.char_array) return Interfaces.C.int;
   pragma Import (C, C_System, "system");

   --  Wrap_Background
   --  Wraps a shell command so it runs under `taskpolicy -b` (PRIO_DARWIN_BG):
   --  throttled disk I/O, low scheduling priority, reduced power impact.
   --  Every spawned helper process (netstat, smartctl, ioreg, nvram, ...)
   --  inherits the policy. This matters: polling netstat every 100ms with
   --  full-priority shell procs measurably raised net power draw (~9W -> ~22W).
   --
   --  Single quotes in the inner command are escaped as '\'' so the whole
   --  command can be safely wrapped in one outer single-quoted argument.
   function Wrap_Background (Command : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("taskpolicy -b /bin/sh -c '");
   begin
      for I in Command'Range loop
         if Command (I) = ''' then
            Append (Result, "'\''");
         else
            Append (Result, Command (I));
         end if;
      end loop;
      Append (Result, "'");
      return To_String (Result);
   end Wrap_Background;

   function Read_NVRAM_Real (Name : String; Default : Earu.Types.Real := 0.0) return Earu.Types.Real is
      Ret : Interfaces.C.int;
       Tmp_File : constant String := Run_Dir & "/earu_nvram_" & Name & ".txt";
      Command : constant String := Wrap_Background ("nvram " & Name & " 2>/dev/null | awk '{print $2}' > " & Tmp_File);
      File : Ada.Text_IO.File_Type;
      Line : Unbounded_String;
   begin
       Ret := C_System (Interfaces.C.To_C (Command));
       pragma Unreferenced (Ret);
       begin
          Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Tmp_File);
         if not Ada.Text_IO.End_Of_File (File) then
            Line := To_Unbounded_String (Ada.Text_IO.Get_Line (File));
         end if;
         Ada.Text_IO.Close (File);
         return Real'Value (To_String (Line));
      exception
         when others =>
            if Ada.Text_IO.Is_Open (File) then Ada.Text_IO.Close (File); end if;
            return Default;
      end;
   end Read_NVRAM_Real;

   procedure Write_NVRAM_Real (Name : String; Value : Earu.Types.Real) is
      Ret : Interfaces.C.int;
      Value_Str : constant String := F (Value);
      Command : constant String := Wrap_Background ("nvram " & Name & "=" & Value_Str);
   begin
       Ret := C_System (Interfaces.C.To_C (Command));
       pragma Unreferenced (Ret);
    end Write_NVRAM_Real;

   function C_Popen (Command : Interfaces.C.char_array; Mode : Interfaces.C.char_array) return System.Address;
   pragma Import (C, C_Popen, "popen");

   function C_Pclose (Stream : System.Address) return Interfaces.C.int;
   pragma Import (C, C_Pclose, "pclose");

   function C_Fread (Ptr : System.Address; Size : Interfaces.C.size_t;
                     N : Interfaces.C.size_t; Stream : System.Address) return Interfaces.C.size_t;
   pragma Import (C, C_Fread, "fread");

   --  Execute_And_Read_Real
   --  Runs a shell command and reads its FIRST line of output as a Real.
   --
   --  IMPLEMENTATION NOTE (2026-08-03):
   --  The previous implementation redirected the command output to a single
   --  shared temp file (/tmp/earu_cmd_out.txt). That was broken: 10 callers
   --  across 6 concurrent daemon tasks (Sensors_Task, Monitor_Task,
   --  Telemetry_Task, Network_Probe_Task, ...) all raced on the same file -
   --  one task would truncate/overwrite the file between another task's
   --  system() call and its file read, producing empty/garbage values
   --  (e.g. network bandwidth always 0). This version uses popen() so each
   --  call reads its output through a private pipe - no shared state, no race.
   function Execute_And_Read_Real (Command : String; Default : Earu.Types.Real := 0.0) return Earu.Types.Real is
      use Interfaces.C;
      Stream : System.Address;
      Buf    : char_array (0 .. 1023);
      N_Read : size_t;
      Ret    : int;
      Line   : String (1 .. 1024);
      Last   : Integer := 0;
   begin
      --  Run the command under taskpolicy -b so the spawned shell and all its
      --  children (netstat, smartctl, ioreg, ...) run in background priority:
      --  throttled I/O + reduced power draw.
      Stream := C_Popen (To_C (Wrap_Background (Command)), To_C ("r"));
      if Stream = System.Null_Address then
         return Default;
      end if;

      N_Read := C_Fread (Buf (0)'Address, 1, 1024, Stream);
      Ret := C_Pclose (Stream);
      pragma Unreferenced (Ret);

      if N_Read = 0 then
         return Default;
      end if;

      --  Convert the raw bytes to a trimmed String
      for I in 0 .. N_Read - 1 loop
         Line (Integer (I) + 1) := Character (Buf (I));
      end loop;
      Last := Integer (N_Read);

      --  Trim trailing whitespace / newline / CR
      while Last > 0 and then (Line (Last) = ' ' or Line (Last) = ASCII.LF or Line (Last) = ASCII.CR or Line (Last) = ASCII.HT) loop
         Last := Last - 1;
      end loop;

      if Last = 0 then
         return Default;
      end if;

      begin
         return Real'Value (Line (1 .. Last));
      exception
         when Constraint_Error =>
            return Default;
      end;
   end Execute_And_Read_Real;

   --  Convert a Byte_Array_64 (Unsigned_8 array) to a trimmed String.
   --  Stops at the first null byte (0).
   function Byte64_To_String (Arr : Earu.Types.Byte_Array_64) return String is
      Last : Natural := 0;
   begin
      for I in Arr'Range loop
         if Interfaces.Unsigned_8'(Arr (I)) = 0 then
            exit;
         end if;
         Last := I;
      end loop;
      if Last = 0 then return ""; end if;
      declare
         Result : String (1 .. Last);
      begin
         for I in 1 .. Last loop
            Result (I) := Character'Val (Interfaces.Unsigned_8'(Arr (I)));
         end loop;
         return Result;
      end;
   end Byte64_To_String;

   --  Convert a Byte_Array_24 (Unsigned_8 array) to a trimmed String.
   --  Stops at the first null byte (0).
   function Byte24_To_String (Arr : Earu.Types.Byte_Array_24) return String is
      Last : Natural := 0;
   begin
      for I in Arr'Range loop
         if Interfaces.Unsigned_8'(Arr (I)) = 0 then
            exit;
         end if;
         Last := I;
      end loop;
      if Last = 0 then return ""; end if;
      declare
         Result : String (1 .. Last);
      begin
         for I in 1 .. Last loop
            Result (I) := Character'Val (Interfaces.Unsigned_8'(Arr (I)));
         end loop;
         return Result;
      end;
   end Byte24_To_String;

   function Byte48_To_String (Arr : Earu.Types.Byte_Array_48) return String is
      Last : Natural := 0;
   begin
      for I in Arr'Range loop
         if Interfaces.Unsigned_8'(Arr (I)) = 0 then
            exit;
         end if;
         Last := I;
      end loop;
      if Last = 0 then return ""; end if;
      declare
         Result : String (1 .. Last);
      begin
         for I in 1 .. Last loop
            Result (I) := Character'Val (Interfaces.Unsigned_8'(Arr (I)));
         end loop;
         return Result;
      end;
   end Byte48_To_String;

   function S (Str : String) return String is
      Result : Unbounded_String;
      I : Positive := Str'First;
   begin
      Append (Result, """");
      while I <= Str'Last loop
         case Str (I) is
            when '"' => Append (Result, "\""");
            when '\' => Append (Result, "\\");
            when ASCII.LF => Append (Result, "\n");
            when ASCII.CR => Append (Result, "\r");
            when ASCII.HT => Append (Result, "\t");
            when others => Append (Result, Str (I));
         end case;
         I := I + 1;
      end loop;
      Append (Result, """");
      return To_String (Result);
   end S;

   function Hash (Input : String) return String is
   begin
      return GNAT.SHA256.Digest (Input);
   end Hash;

   procedure Load_Initial_State (
      Path                 : String;
      Lat, Lon, Alt        : out Earu.Types.Real;
      Heading              : out Earu.Types.Real;
      Total_Dist           : out Earu.Types.Real;
      Cumulative_Fatigue   : out Earu.Types.Real;
      Machine_Life_Runtime : out Earu.Types.Real;
      NVRAM_Write_Cycles   : out Earu.Types.Real;
      Q_W, Q_X, Q_Y, Q_Z   : out Earu.Types.Real;
      Success              : out Boolean
   ) is
      File : Ada.Text_IO.File_Type;
      Primary_Line : Unbounded_String;
      Verified : Boolean := False;

      function Get_Real_Value (JSON : String; Key : String; Default : Real := 0.0) return Real is
         Idx : Integer := Ada.Strings.Fixed.Index (JSON, """" & Key & """:");
      begin
         if Idx = 0 then return Default; end if;
         Idx := Idx + Key'Length + 2;
         while Idx <= JSON'Last and then JSON (Idx) = ' ' loop Idx := Idx + 1; end loop;
         declare
            Start_Pos : constant Integer := Idx;
         begin
            while Idx <= JSON'Last and then JSON (Idx) /= ',' and then JSON (Idx) /= '}' and then JSON (Idx) /= ']' and then JSON (Idx) /= ' ' loop
               Idx := Idx + 1;
            end loop;
            if Start_Pos < Idx then return Real'Value (JSON (Start_Pos .. Idx - 1));
            else return Default; end if;
         end;
      exception
         when others => return Default;
      end Get_Real_Value;

   begin
      Success := False;
      Lat := -6.333012; Lon := 106.971199; Alt := 0.0;
      Heading := 0.0; Total_Dist := 0.0; Cumulative_Fatigue := 0.0;
      Machine_Life_Runtime := 0.0; NVRAM_Write_Cycles := 0.0;
      Q_W := 1.0; Q_X := 0.0; Q_Y := 0.0; Q_Z := 0.0;

      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
         if not Ada.Text_IO.End_Of_File (File) then
            Primary_Line := To_Unbounded_String (Ada.Text_IO.Get_Line (File));
            Verified := True; -- Simplified for now
         end if;
         Ada.Text_IO.Close (File);
      exception
         when others =>
            if Ada.Text_IO.Is_Open (File) then Ada.Text_IO.Close (File); end if;
            return;
      end;

      if Verified then
         declare
            S_JSON : constant String := To_String (Primary_Line);
         begin
            Lat := Get_Real_Value (S_JSON, "lat", Lat);
            Lon := Get_Real_Value (S_JSON, "lon", Lon);
            Alt := Get_Real_Value (S_JSON, "alt", Alt);
            Heading := Get_Real_Value (S_JSON, "heading", Heading);
            Total_Dist := Get_Real_Value (S_JSON, "total_distance_m", Total_Dist);
            Cumulative_Fatigue := Get_Real_Value (S_JSON, "cumulative_fatigue", Cumulative_Fatigue);
            Machine_Life_Runtime := Get_Real_Value (S_JSON, "machine_life_runtime", 0.0);
            NVRAM_Write_Cycles := Get_Real_Value (S_JSON, "nvram_write_cycles", 0.0);
            Success := True;
         exception
            when others => Success := False;
         end;
      end if;
   end Load_Initial_State;

   procedure Write_EARU_Data (
      State   : Earu.Types.Earu_State;
      Path    : String;
      Weather : Earu.Shm.Weather_SHM_Ptr
   ) is
      use Ada.Streams.Stream_IO;
      File     : Ada.Streams.Stream_IO.File_Type;
      Tmp_Path : constant String := Path & ".tmp";
      Buf      : Unbounded_String;

      --  Append "key": val,  (or without trailing comma when Comma=False)
      procedure AP (Key : String; Val : String; Comma : Boolean := True) is
      begin
         Append (Buf, """" & Key & """: " & Val & (if Comma then ", " else ""));
      end AP;

      --  Integer value helper
      procedure AI (Key : String; Val : Integer; Comma : Boolean := True) is
      begin
         AP (Key, Ada.Strings.Fixed.Trim (Integer'Image (Val), Ada.Strings.Both), Comma);
      end AI;

      --  Long_Long_Integer value helper
      procedure AL (Key : String; Val : Long_Long_Integer; Comma : Boolean := True) is
      begin
         AP (Key, Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (Val), Ada.Strings.Both), Comma);
      end AL;

      --  Boolean as JSON true/false
      procedure ABool (Key : String; Val : Boolean; Comma : Boolean := True) is
      begin
         AP (Key, B (Val), Comma);
      end ABool;

   begin
      Append (Buf, "{");
      pragma Unreferenced (Weather);

      --  ── time ─────────────────────────────────────────────────────────────
      AP ("time", F (State.Time));

      --  ── accel ─────────────────────────────────────────────────────────────
      Append (Buf, """accel"": {");
      AP ("mag", F (State.Accel_Mag));
      AP ("x",   F (State.Accel.X));
      AP ("y",   F (State.Accel.Y));
      AP ("z",   F (State.Accel.Z), False);
      Append (Buf, "}, ");

      --  ── gyro ──────────────────────────────────────────────────────────────
      Append (Buf, """gyro"": {");
      AP ("x", F (State.Gyro.X));
      AP ("y", F (State.Gyro.Y));
      AP ("z", F (State.Gyro.Z), False);
      Append (Buf, "}, ");

      --  ── lid_angle / lid_speed ─────────────────────────────────────────────
      AP ("lid_angle", F (State.Lid_Angle));
      AP ("lid_speed", F (State.Lid_Speed));

      --  ── orientation ──────────────────────────────────────────────────────
      Append (Buf, """orientation"": {");
      AP ("roll",  F (State.Orientation.Roll));
      AP ("pitch", F (State.Orientation.Pitch));
      AP ("yaw",   F (State.Orientation.Yaw));
      Append (Buf, """q"": [" &
         F (State.Orientation.Q.W) & ", " &
         F (State.Orientation.Q.X) & ", " &
         F (State.Orientation.Q.Y) & ", " &
         F (State.Orientation.Q.Z) & "]");
      Append (Buf, "}, ");

      --  ── orientation_degree (same values — already in degrees) ─────────────
      Append (Buf, """orientation_degree"": {");
      AP ("roll",  F (State.Orientation.Roll));
      AP ("pitch", F (State.Orientation.Pitch));
      AP ("yaw",   F (State.Orientation.Yaw), False);
      Append (Buf, "}, ");

      --  ── als ───────────────────────────────────────────────────────────────
      Append (Buf, """als"": {");
      AP ("lux_factor", F (State.ALS.Lux_Factor));
      Append (Buf, """spectral"": [" &
         Ada.Strings.Fixed.Trim (Integer'Image (State.ALS.Spectral (1)), Ada.Strings.Both) & ", " &
         Ada.Strings.Fixed.Trim (Integer'Image (State.ALS.Spectral (2)), Ada.Strings.Both) & ", " &
         Ada.Strings.Fixed.Trim (Integer'Image (State.ALS.Spectral (3)), Ada.Strings.Both) & ", " &
         Ada.Strings.Fixed.Trim (Integer'Image (State.ALS.Spectral (4)), Ada.Strings.Both) & "]");
      Append (Buf, "}, ");

      --  ── loop_consistency ─────────────────────────────────────────────────
      Append (Buf, """loop_consistency"": {");
      AP    ("avg_ms",          F (State.Loop_Consistency.Avg_Ms));
      AP    ("low_01_ms",       F (State.Loop_Consistency.Low_01_Ms));
      AP    ("low_1_ms",        F (State.Loop_Consistency.Low_1_Ms));
      AP    ("pct_90_ms",       F (State.Loop_Consistency.Pct_90_Ms));
      AI    ("stutters",        State.Loop_Consistency.Stutters);
      ABool ("stutter_warning", State.Loop_Consistency.Stutter_Warning);
      AP    ("wcef_latency",    F (State.Loop_Consistency.Wcef_Latency), False);
      Append (Buf, "}, ");

      --  ── high_res_drift ───────────────────────────────────────────────────
      Append (Buf, """high_res_drift"": {");
      AL ("t_cpu_ns",               State.Interaction_Responsiveness.T_CPU_ns);
      AL ("t_rtc_ns",               State.Interaction_Responsiveness.T_RTC_ns);
      AL ("t_gpu_ns",               State.Interaction_Responsiveness.T_GPU_ns);
      AL ("t_dat_ns",               State.Interaction_Responsiveness.T_DAT_ns);
      AL ("t_spu_ns",               State.Interaction_Responsiveness.T_SPU_ns);
      AP ("t_inference_fabric_ns",  "0");
      AP ("spu_lat_ms",             F (State.Interaction_Responsiveness.SPU_Lat_ms));
      AP ("gpu_lat_ms",             F (State.Interaction_Responsiveness.GPU_Lat_ms));
      AP ("rtc_jitter_ms",          F (State.Interaction_Responsiveness.RTC_Jitter_ms));
      AP ("inference_fabric_lat_ms","0.0");
      AP ("interference",           (if State.Interaction_Responsiveness.Interference then """Yes""" else """No"""));
      AP ("ts",                     S (Trim_Null (State.Interaction_Responsiveness.TS_ISO)), False);
      Append (Buf, "}, ");

      --  ── location ─────────────────────────────────────────────────────────
      Append (Buf, """location"": {");
      AP ("lat",            F (State.Location.Lat));
      AP ("lon",            F (State.Location.Lon));
      AP ("alt",            F (State.Location.Alt));
      AP ("heading",        F (State.Location.Heading));
      AP ("total_distance_m", F (State.Location.Total_Dist));
      AP ("alt_rate",       F (State.Location.Alt_Rate));
      AP ("mach",           F (State.Location.Mach));
      AP ("odometer_30m",   F (State.Location.Odometer_30m));
      AP ("v_mag",          F (State.Location.V_Mag));
      AP ("calibrated_g",   F (State.Location.Calibrated_G));
      AP ("pressure_hpa",   F (State.Location.Pressure_HPa));
      AP ("compass_dir",    S (Ada.Strings.Fixed.Trim (State.Location.Compass_Dir, Ada.Strings.Both)));
      Append (Buf, """pos"": [" &
         F (State.Location.Pos.X) & ", " &
         F (State.Location.Pos.Y) & ", " &
         F (State.Location.Pos.Z) & "], ");
      Append (Buf, """vel"": [" &
         F (State.Location.Vel.X) & ", " &
         F (State.Location.Vel.Y) & ", " &
         F (State.Location.Vel.Z) & "], ");
      AP ("locationd_anchor_refresh_speed", F (State.Location.Anchor_Refresh_Speed));
      AP ("lockin_miss",                    F (State.Location.Lockin_Miss));
      AP ("time",                           F (State.Time));
      AP ("CorrectionFactor_Reckoning_Altitude",     F (State.Location.Corr_Alt));
      AP ("CorrectionFactor_Reckoning_Heading",      F (State.Location.Corr_Heading));
      AP ("CorrectionFactor_Reckoning_Velocity",     F (State.Location.Corr_Velocity));
      AP ("CorrectionFactor_Reckoning_VerticalRate", F (State.Location.Corr_VRate));
      AP ("master_warning", S (Trim_Null (State.Location.Warning_Reason)));
      AP ("master_caution", S (Trim_Null (State.Location.Caution_Reason)));
      AP ("inside_significant_location", B (State.Location.Inside_Significant_Location));
      Append (Buf, """significant_locations"": [");
      for I in 1 .. State.Sig_Loc_Count loop
         Append (Buf, "{");
         Append (Buf, """lat"": " & F (State.Sig_Locations(I).Lat) & ", ");
         Append (Buf, """lon"": " & F (State.Sig_Locations(I).Lon) & ", ");
         Append (Buf, """alt"": " & F (State.Sig_Locations(I).Alt) & ", ");
         Append (Buf, """time"": " & F (State.Sig_Locations(I).Time));
         Append (Buf, "}");
         if I < State.Sig_Loc_Count then
            Append (Buf, ", ");
         end if;
      end loop;
      Append (Buf, "]");
      Append (Buf, "}, ");

      --  ── seismic_activity ─────────────────────────────────────────────────
      Append (Buf, """seismic_activity"": {");
      AP ("peak_g",          F (State.Seismic_Activity.Peak_G));
      AP ("certainty",       F (State.Seismic_Activity.Certainty));
      AP ("spectral_balance",F (State.Seismic_Activity.Spectral_Balance));
      AP ("motion_type",     S (Trim_Null (State.Seismic_Activity.Motion_Type)));
      Append (Buf, """damage_fatigue"": {");
      AP    ("aggregated_risk",         F (State.Seismic_Activity.Damage_Fatigue.Aggregated_Risk));
      AP    ("cumulative_fatigue",      F (State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue));
      AP    ("solder_fatigue_prob",     F (State.Seismic_Activity.Damage_Fatigue.Solder_Fatigue_Prob));
      AP    ("electromech_fatigue_prob",F (State.Seismic_Activity.Damage_Fatigue.Electromech_Fatigue_Prob));
      AP    ("structural_life_left_y",  F (State.Seismic_Activity.Damage_Fatigue.Structural_Life_Left_Y));
      AP    ("structural_life_left_m",  F (State.Seismic_Activity.Damage_Fatigue.Structural_Life_Left_M));
      AP    ("structural_life_left_d",  F (State.Seismic_Activity.Damage_Fatigue.Structural_Life_Left_D));
      AP    ("seu_risk_multiplier",     F (State.Seismic_Activity.Damage_Fatigue.Seu_Risk_Multiplier));
      AP    ("alt_stress_multiplier",   F (State.Seismic_Activity.Damage_Fatigue.Alt_Stress_Multiplier));
      AI    ("anomaly_event_upset",     State.Seismic_Activity.Damage_Fatigue.Anomaly_Upset_Count);
      Append (Buf, """data_integrity_check"": {");
      ABool ("active",       State.Seismic_Activity.Damage_Fatigue.Data_Integrity.Active);
      AP    ("triggered_at", F (State.Seismic_Activity.Damage_Fatigue.Data_Integrity.Triggered_At), False);
      Append (Buf, "}}}, ");

      --  ── system ────────────────────────────────────────────────────────────
      Append (Buf, """system"": {");
      AP    ("uptime_earu",               F (State.System.Uptime_Earu));
      AP    ("uptime_system",             F (State.System.Uptime_System));
      AP    ("machine_life_runtime",      F (State.System.Machine_Life_Runtime));
      AP    ("nvram_write_cycles",        F (State.System.NVRAM_Write_Cycles));
      AP    ("nvram_rated_endurance",     F (State.System.NVRAM_Rated_Endurance));
      AP    ("cpu_usage",                 F (State.System.CPU_Usage));
      AP    ("mem_usage",                 F (State.System.Mem_Usage));
      AI    ("battery_percent",           State.System.Battery_Percent);
      ABool ("battery_charging",          State.System.Battery_Charging);
      AP    ("BatteryDesignCapacityWh",   F (State.System.Battery_Design_Wh));
      AP    ("BatteryEnergyBankWh",       F (State.System.Battery_Energy_Wh));
      AP    ("BatteryFullChargeCapacityWh",F (State.System.Battery_Full_Wh));
      AP    ("BatteryHealthPct",          F (State.System.Battery_Health_Pct));
      AP    ("p_augmented",               F (State.System.P_Augmented));
      AP    ("p_external",                F (State.System.P_External));
      AP    ("p_internal",                F (State.System.P_Internal));
      AP    ("Batt_Life_Y",               F (State.System.Batt_Life_Y));
      AP    ("Drain_Time_Active",         F (State.System.Drain_Time_Active));
      AP    ("Drain_Time_Sleep",          F (State.System.Drain_Time_Sleep));
      AP    ("Drain_Time_Hib",            F (State.System.Drain_Time_Hib));
      AP    ("Drain_Time_DeepHib",        F (State.System.Drain_Time_DeepHib));
      AP    ("abandoned_playback_recommendation_s", F (State.System.Abandoned_Playback_Recommendation_S));
      Append (Buf, """load_avg"": [" &
         F (State.System.Load_Avg (1)) & ", " &
         F (State.System.Load_Avg (2)) & ", " &
         F (State.System.Load_Avg (3)) & "], ");
      AP    ("nonHumanInputHIDIdle",      F (State.System.Non_Human_HID_Idle_ns / 1_000_000_000.0));
      AP    ("ssd_used_pct",              F (State.System.SSD_Used_Pct));
      AP    ("ssd_available_spare",       F (State.System.SSD_Available_Spare));
      AP    ("ssd_life_left_years",       F (State.System.SSD_Life_Left_Years));
      AP    ("ssd_life_left_months",      F (State.System.SSD_Life_Left_Months));
      AP    ("ssd_life_left_days",        F (State.System.SSD_Life_Left_Days));
      AP    ("ssd_data_read_units",       F (State.System.SSD_Data_Read_Units));
      AP    ("ssd_data_write_units",      F (State.System.SSD_Data_Write_Units));
      ABool ("active_network_accessed",   State.System.Active_Network_Accessed);
      AP    ("total_network_bandwidth_up_kbps",   F (State.System.Total_Network_Bandwidth_Up_Kbps));
      AP    ("total_network_bandwidth_down_kbps", F (State.System.Total_Network_Bandwidth_Down_Kbps));
      AP    ("pmset_info",                S (Trim_Null (State.System.PMSet_Info)), False);
      Append (Buf, "}, ");

      --  ── smc ───────────────────────────────────────────────────────────────
      Append (Buf, """smc"": {");
      AP ("ambient_temp_k",  F (State.SMC.Ambient_Temp_K));
      AP ("humidity_pct",    F (State.SMC.Humidity_Pct));
      Append (Buf, """fan_rpms"": [" & F (State.SMC.Fan_RPMs (1)) & ", " & F (State.SMC.Fan_RPMs (2)) & "], ");
      AP ("F0Tg",            F (State.SMC.Fan_Targets (1)));
      AP ("F1Tg",            F (State.SMC.Fan_Targets (2)));
      AP ("thrust_n",        F (State.SMC.Thrust_N));
      AP ("massflow_kg_s",   F (State.SMC.Massflow_Kg_S));
      AP ("heatflux_j",      F (State.SMC.Heatflux_J));
      AP ("cooling_efficiency_pct", F (State.SMC.Cooling_Efficiency_Pct));
      AP ("work_efficiency_pct",    F (State.SMC.Work_Efficiency_Pct));
      AP ("thermal_inefficiency_w", F (State.SMC.Thermal_Inefficiency_W));
      AP ("power",           F (State.SMC.Power));
      AP ("PowerRateUsage",  F (State.SMC.Power_Rate_Usage));
      AP ("PowerSurvivalW",  F (State.SMC.Power_Survival_W));
      AP ("DayPowerUsage_Wh",               F (State.SMC.Day_Power_Usage_Wh));
      AP ("EstimatedTodayPowerUsage_Wh",    F (State.SMC.Est_Today_Power_Wh));
      AP ("AccumulativePowerUsageThisMonth_Wh", F (State.SMC.Accum_Power_Month_Wh));
      AP ("AccumulativePowerUsageMeter_Wh", F (State.SMC.Accum_Power_Meter_Wh));
      AP ("PulsingSuggestionMaintenanceWindowWake",       F (State.SMC.Pulse_Wake));
      AP ("PulsingSuggestionMaintenanceWindowWakeLength", F (State.SMC.Pulse_Length));
      AP ("WillBatterySurviveOneDay",       YN (State.SMC.Will_Bat_Survive));
      AP ("inOrderToSurviveDayMustHibernate", YN (State.SMC.Must_Hibernate));
      AP ("airflow_inlet_k",  F (State.SMC.Airflow_Inlet_K));
      AP ("airflow_outlet_k", F (State.SMC.Airflow_Outlet_K));
      --  Airflow pair channels (dual-fan MacBook Pro 14" M2 Pro)
      AP ("airflow_inlet_1_k",  F (State.SMC.Airflow_Inlet_1_K));   --  Pair 1: Ts1P ambient
      AP ("airflow_outlet_1_k", F (State.SMC.Airflow_Outlet_1_K));  --  Pair 1: TaLP left exhaust
      AP ("airflow_inlet_2_k",  F (State.SMC.Airflow_Inlet_2_K));   --  Pair 2: Ts1P ambient
      AP ("airflow_outlet_2_k", F (State.SMC.Airflow_Outlet_2_K));  --  Pair 2: TaRF right exhaust
      AP ("talp_k",           F (State.SMC.TaLP_K));
      AP ("tarf_k",           F (State.SMC.TaRF_K));
      AI ("turbo",            State.SMC.Turbo);
      --  SMC Power Management Keys
      AP ("aPMX",  F (State.SMC.Active_Perf_Mode));
      AP ("mTPL",  F (State.SMC.Max_Turbo_Power_Lim));
      AP ("mUTL",  F (State.SMC.Max_User_Turbo_Lim));
      AP ("xPPT",  F (State.SMC.Pkg_Power_Tracking));
      AP ("xLPM",  F (State.SMC.Low_Power_Mode_Lim));
      AP ("PHPB",  F (State.SMC.Pkg_High_Pwr_Budget));
      AP ("PHPM",  F (State.SMC.Pkg_High_Pwr_Mode));
      AP ("PHPC",  F (State.SMC.Pkg_High_Pwr_Curr));
      AP ("PHPS",  F (State.SMC.Pkg_High_Pwr_Sensor));
      AP ("PMVC",  F (State.SMC.Pwr_Mgmt_Vrm_Curr));
      AP ("PPSC",  F (State.SMC.Pwr_Supply_Curr));
      AP ("PSVR",  F (State.SMC.Pwr_Supply_Vrm));
      AP ("PDBR",  F (State.SMC.Pwr_Device_Batt_Rate));
      AP ("PDTR",  F (State.SMC.Pwr_Device_Temp_Rate));
      Append (Buf, """temps"": {");
      AP ("PSTR", F (State.SMC.Temps.PSTR));
      AP ("TCMz", F (State.SMC.Temps.TCMz));
      AP ("TaLP", F (State.SMC.Temps.TaLP));
      AP ("TaLT", F (State.SMC.Temps.TaLT));
      AP ("TaLW", F (State.SMC.Temps.TaLW));
      AP ("TaRF", F (State.SMC.Temps.TaRF));
      AP ("TaRT", F (State.SMC.Temps.TaRT));
      AP ("TaRW", F (State.SMC.Temps.TaRW));
      AP ("Tg0X", F (State.SMC.Temps.Tg0X));
      AP ("Ts0P", F (State.SMC.Temps.Ts0P));
      AP ("Ts1P", F (State.SMC.Temps.Ts1P), False);
      Append (Buf, "}, ");
      Append (Buf, """gas_constants"": {");
      AP ("Cp",    F (State.SMC.Gas_Constants.Cp));
      AP ("R",     F (State.SMC.Gas_Constants.R));
      AP ("gamma", F (State.SMC.Gas_Constants.Gamma), False);
      Append (Buf, "}, ");
      Append (Buf, """fluid_dynamics"": {");
      AP ("flow_scale_l",          F (State.SMC.Flow_Scale_L));
      AP ("char_velocity_u0",      F (State.SMC.Char_Velocity_U0));
      AP ("turbulence_int_up",     F (State.SMC.Turbulence_Int_Up));
      AP ("reynolds_number_re0",    F (State.SMC.Reynolds_Number_Re0));
      AP ("reynolds_number",        F (State.SMC.Reynolds_Number));
      AP ("weber_number",           F (State.SMC.Weber_Number));
      AP ("strouhal_number",        F (State.SMC.Strouhal_Number));
      AP ("cauchy_number",          F (State.SMC.Cauchy_Number), False);
      Append (Buf, "}}, ");

      --  ── user_entity_detection ─────────────────────────────────────────────
      Append (Buf, """user_entity_detection"": {");
      AI ("count", State.User_Entity.Count);
      Append (Buf, """inferred_mood"": {");
      AP ("Anxious/Frustrated", F (State.User_Entity.Mood.Anxious));
      AP ("Calm/Relaxed",       F (State.User_Entity.Mood.Calm));
      AP ("Excited/Joyful",     F (State.User_Entity.Mood.Excited));
      AP ("Tired/Bored",        F (State.User_Entity.Mood.Tired), False);
      Append (Buf, "}, ");
      Append (Buf, """detected"": [");
      for I in 1 .. 3 loop
         Append (Buf, "[" & F (State.User_Entity.Detected (I).BPM) & ", " &
                           F (State.User_Entity.Detected (I).Confidence) & "]");
         if I < 3 then Append (Buf, ", "); end if;
      end loop;
      Append (Buf, "]}, ");

      --  ── ecosystem_weather ────────────────────────────────────────────────
      Append (Buf, """ecosystem_weather"": {");
      AP ("category",              S (Trim_Null (State.Ecosystem_Weather.Category)));
      AP ("condition_icon",        S (Trim_Null (State.Ecosystem_Weather.Condition_Icon)));
      AP ("dew_point_k",           F (State.Ecosystem_Weather.Dew_Point_K));
      AP ("dew_point_spread",      F (State.Ecosystem_Weather.Dew_Point_Spread));
      AP ("humidity_pct",          F (State.Ecosystem_Weather.Humidity_Pct));
      AP ("air_fluid_density",     F (State.Ecosystem_Weather.Air_Fluid_Density));
      AP ("pressure_tendency_hpa", F (State.Ecosystem_Weather.Pressure_Tendency_HPa));
      AP ("api_humidity_pct",      F (State.Ecosystem_Weather.API_Humidity_Pct));
      AP ("hum_offset",            F (State.Ecosystem_Weather.Hum_Offset));
      AP ("smc_p_offset_hpa",      F (State.Ecosystem_Weather.SMC_P_Offset_HPa));
      --  wind_map: 7x7 grid serialized as nested arrays
      Append (Buf, """wind_map"": [");
      for Row in 1 .. 7 loop
         Append (Buf, "[");
         for Col in 1 .. 7 loop
            declare
               WP : constant Earu.Types.Wind_Point := State.Ecosystem_Weather.Wind_Map (Row, Col);
            begin
               Append (Buf, "[" & F (WP.Speed) & ", [" &
                  F (WP.Vec.X) & ", " & F (WP.Vec.Y) & ", " & F (WP.Vec.Z) &
                  "], " & F (WP.Press) & ", " & F (WP.Temp) &
                  ", " & F (WP.Pos_X) & ", " & F (WP.Pos_Y) & "]");
               if Col < 7 then Append (Buf, ", "); end if;
            end;
         end loop;
         Append (Buf, "]");
         if Row < 7 then Append (Buf, ", "); end if;
      end loop;
      Append (Buf, "], ");
      --  stats buckets
      Append (Buf, """stats"": {");
      declare
         procedure Bucket (Key : String; Bkt : Earu.Types.Stat_Bucket; Comma : Boolean := True) is
            Dir_Str : constant String := Ada.Strings.Fixed.Trim (String (Bkt.Dir), Ada.Strings.Both);
            St      : constant Character := Bkt.State;
         begin
            Append (Buf, """" & Key & """: [" &
               F (Bkt.Val) & ", """ & St & """, """ & Dir_Str & """, " &
               F (Bkt.Drift) & "]" & (if Comma then ", " else ""));
         end Bucket;
      begin
         Bucket ("0.1",   State.Ecosystem_Weather.Stats.S_0_1);
         Bucket ("1.0",   State.Ecosystem_Weather.Stats.S_1_0);
         Bucket ("10.0",  State.Ecosystem_Weather.Stats.S_10_0);
         Bucket ("100.0", State.Ecosystem_Weather.Stats.S_100_0, False);
      end;
      --  Close the stats inner dict.
      Append (Buf, "}");
      --  3rdparty_meteo is now written to a separate file (EARU_meteo.dat)
      --  by the weather fetcher to keep EARU_data.dat small.  The viewer
      --  reads it directly from that file when page 7 is active.
      --  Close the metar_taf sub-object (computed by earu-math.adb).
      if State.Ecosystem_Weather.Metar_Report (1) /= ' ' then
         Append (Buf, ",");
         Append (Buf, """metar_taf"": {");
         Append (Buf, """metar"": """
                 & Ada.Strings.Fixed.Trim (State.Ecosystem_Weather.Metar_Report, Ada.Strings.Both)
                 & """");
         Append (Buf, ",");
         Append (Buf, """taf"": """
                 & Ada.Strings.Fixed.Trim (State.Ecosystem_Weather.Taf_Report, Ada.Strings.Both)
                 & """");
         Append (Buf, ",");
         Append (Buf, """wind_speed_kts"": " & F (State.Ecosystem_Weather.Wind_Speed_Kts));
         Append (Buf, ",");
         Append (Buf, """wind_dir_deg"": " & F (State.Ecosystem_Weather.Wind_Dir_Deg));
         Append (Buf, "}");
      end if;
      --  Close the ecosystem_weather dict.
      Append (Buf, "}, ");

      --  ── wifi_scan ────────────────────────────────────────────────────────
      Append (Buf, """wifi_scan"": {");
      AI ("count", Integer (State.WiFi_Scan.Count));
      AI ("error_code", Integer (State.WiFi_Scan.Error_Code));
      AP ("timestamp", F (State.WiFi_Scan.Timestamp));
      AP ("scan_duration_ms", F (State.WiFi_Scan.Scan_Duration_Ms));
      Append (Buf, """networks"": [");
      for I in 1 .. Integer'Min (
        Integer (State.WiFi_Scan.Count),
        Earu.Types.WIFI_SCAN_MAX)
      loop
         declare
            N : constant Earu.Types.WiFi_Network_Entry :=
              State.WiFi_Scan.Networks (I);
            SSID_Str  : constant String := Trim_Null (Byte64_To_String (N.SSID));
            BSSID_Str : constant String := Trim_Null (Byte24_To_String (N.BSSID));
         begin
            Append (Buf, "{");
            AP ("ssid", S (SSID_Str));
            AP ("bssid", S (BSSID_Str));
            AP ("rssi", Ada.Strings.Fixed.Trim (
                  Interfaces.Integer_32'Image (N.RSSI), Ada.Strings.Both));
            AP ("channel", Ada.Strings.Fixed.Trim (
                  Interfaces.Integer_32'Image (N.Channel), Ada.Strings.Both));
            AI ("is_secure", Integer (N.Is_Secure), False);
            Append (Buf, "}");
         end;
         if I < Integer'Min (Integer (State.WiFi_Scan.Count),
                             Earu.Types.WIFI_SCAN_MAX)
         then
            Append (Buf, ", ");
         end if;
      end loop;
      Append (Buf, "], ");
      AI ("network_count", Integer (State.WiFi_Scan.Count), False);
      Append (Buf, "}, ");

      --  ── bluetooth_scan ───────────────────────────────────────────────────
      Append (Buf, """bluetooth_scan"": {");
      AI ("count", Integer (State.BLE_Scan.Count));
      AI ("error_code", Integer (State.BLE_Scan.Error_Code));
      AP ("timestamp", F (State.BLE_Scan.Timestamp));
      AP ("scan_duration_ms", F (State.BLE_Scan.Scan_Duration_Ms), False);
      Append (Buf, ", ""devices"": [");
      for I in 1 .. Integer'Min (Integer (State.BLE_Scan.Count),
                                  Earu.Types.BLE_SCAN_MAX)
      loop
         declare
            D : constant Earu.Types.BLE_Device_Entry :=
              State.BLE_Scan.Devices (I);
         begin
            Append (Buf, "{");
            AP ("name", S (Byte64_To_String (D.Name)));
            AP ("device_id", S (Byte48_To_String (D.Device_Id)));
            AP ("rssi", Integer_32'Image (D.RSSI));
            AP ("tx_power_level", Integer_32'Image (D.TX_Power_Level));
            AP ("is_connectable", Integer'Image (Integer (D.Is_Connectable)), False);
            Append (Buf, "}");
            if I < Integer'Min (Integer (State.BLE_Scan.Count),
                                Earu.Types.BLE_SCAN_MAX)
            then
               Append (Buf, ", ");
            end if;
         end;
      end loop;
      Append (Buf, "], ");
      AI ("device_count", Integer (State.BLE_Scan.Count), False);
      Append (Buf, "}, ");

      --  ── Sol_BlueMarble_TimeAnchor ─────────────────────────────────────────
      Append (Buf, """Sol_BlueMarble_TimeAnchor"": {");
      AL ("Morning_Astronomical_Twilight", State.Sol_BlueMarble.Morning_Astronomical_Twilight);
      AL ("Solar_Noon_Transit", State.Sol_BlueMarble.Solar_Noon_Transit);
      AL ("Dynamic_Shadow_Ratio_Match", State.Sol_BlueMarble.Dynamic_Shadow_Ratio_Match);
      AL ("Evening_Civil_Horizon_Clearance", State.Sol_BlueMarble.Evening_Civil_Horizon_Clearance);
      AL ("Evening_Astronomical_Twilight", State.Sol_BlueMarble.Evening_Astronomical_Twilight);
      AL ("Last_Third_Night_Segment", State.Sol_BlueMarble.Last_Third_Night_Segment, False);
      Append (Buf, "}, ");

      --  ── events ────────────────────────────────────────────────────────────
      Append (Buf, """events"": [");
      for I in 1 .. State.Event_Count loop
         declare
            E : constant Earu.Types.Event_Type := State.Events (I);
         begin
            Append (Buf, "{");
            AP    ("time", F (E.Time));
            AP    ("tstr", S (Trim_Null (E.TStr)));
            AP    ("amp",  F (E.Amp));
            AP    ("lbl",  S (Trim_Null (E.Lbl)));
            AP    ("sev",  S (Trim_Null (E.Sev)));
            AP    ("sym",  S (Trim_Null (E.Sym)));
            Append (Buf, """src"": [" & S (Trim_Null (E.Src)) & "], ");
            AI    ("nsrc", E.NSrc);
            Append (Buf, """bands"": []}");
            if I < State.Event_Count then Append (Buf, ", "); end if;
         end;
      end loop;
      Append (Buf, "], ");

      --  ── close root & compute self-parity hash ─────────────────────────────
      declare
         Pre_Parity : constant String := To_String (Buf) & "}";
         P_Hash     : constant String := Hash (Pre_Parity);
      begin
         Append (Buf, """parity"": """ & P_Hash & """");
      end;
      Append (Buf, "}");

      --  ── atomic write via Stream_IO ───────────────────────────────────────────
      --  NOTE: We use Stream_IO to write raw bytes directly. This prevents Ada.Text_IO
      --  from performing UTF-8 encoding on non-ASCII characters, which would change the
      --  byte sequence and invalidate the SHA256 parity hash calculated on the buffer.
      begin
         declare
            S_Buf : constant String := To_String (Buf);
         begin
            Create (File, Out_File, Tmp_Path);
            for I in S_Buf'Range loop
               Character'Write (Stream (File), S_Buf (I));
            end loop;
            Character'Write (Stream (File), ASCII.LF);
            Close (File);
         end;
         declare
            function rename (old_path, new_path : Interfaces.C.Strings.chars_ptr) return Interfaces.C.int;
            pragma Import (C, rename, "rename");
            C_Tmp  : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Tmp_Path);
            C_Path : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Path);
            Ret    : Interfaces.C.int := rename (C_Tmp, C_Path);
            pragma Unreferenced (Ret);
         begin
            Interfaces.C.Strings.Free (C_Tmp); Interfaces.C.Strings.Free (C_Path);
         end;
      exception
         when E : others =>
            Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
               "[Write_EARU_Data] exception: " & Ada.Exceptions.Exception_Message (E));
            if Is_Open (File) then Close (File); end if;
      end;
   end Write_EARU_Data;

   -- SAFETY NOTE: These caches are written only by Monitor_Task (single-writer).
   -- No mutex needed because Ada task scheduling guarantees mutual exclusion
   -- for a single task accessing its own variables.
   Cache_TCMz : Real := 75.0;
   Cache_Tg0X : Real := 60.0;
   Cache_TaLP : Real := 50.0;
   Cache_TaRF : Real := 50.0;
   Cache_TaLT : Real := 40.0;
   Cache_TaLW : Real := 40.0;
   Cache_TaRT : Real := 40.0;
   Cache_TaRW : Real := 40.0;
   Cache_Ts0P : Real := 50.0;
   Cache_Ts1P : Real := 35.0;
   Cache_PSTR : Real := 15.0;
   Cache_F0    : Real := 2000.0;
   Cache_F1    : Real := 2000.0;
   Cache_F0Tg  : Real := 2000.0;
   Cache_F1Tg  : Real := 2000.0;
   Cache_Turbo : Integer := 0;

   function Read_Sensor_Real (Filename : String) return Earu.Types.Real is
      use Ada.Text_IO;
      File : File_Type;
      Val  : Real := 0.0;
      Read_Success : Boolean := False;

      function Try_Read (Path : String) return Boolean is
      begin
         Open (File, In_File, Path);
         Real_IO.Get (File, Val);
         Close (File);
         return Val /= 0.0; -- Success if we got a non-zero value
      exception
         when others =>
            if Is_Open (File) then Close (File); end if;
            return False;
      end Try_Read;

   begin
      -- Try primary RAM disk path
      Read_Success := Try_Read ("/Volumes/EARU_dataIO/" & Filename);

      -- Fallback 1: Try local project root
      if not Read_Success then
         Read_Success := Try_Read ("/usr/local/EnvironmentalAwareReferentialUnit/" & Filename);
      end if;

      -- Fallback 2: Handle prefix mismatch (SMC vs TEMP)
      if not Read_Success then
      if Filename'Length > 11 and then Filename (Filename'First .. Filename'First + 10) = "sensor_smc_" then
             declare
                Fallback_Name : constant String := "sensor_temp_" & Filename (Filename'First + 11 .. Filename'Last);
            begin
               Read_Success := Try_Read ("/Volumes/EARU_dataIO/" & Fallback_Name);
               if not Read_Success then
                  Read_Success := Try_Read ("/usr/local/EnvironmentalAwareReferentialUnit/" & Fallback_Name);
               end if;
            end;
      elsif Filename'Length > 12 and then Filename (Filename'First .. Filename'First + 11) = "sensor_temp_" then
              declare
                Fallback_Name : constant String := "sensor_smc_" & Filename (Filename'First + 12 .. Filename'Last);
            begin
               Read_Success := Try_Read ("/Volumes/EARU_dataIO/" & Fallback_Name);
               if not Read_Success then
                  Read_Success := Try_Read ("/usr/local/EnvironmentalAwareReferentialUnit/" & Fallback_Name);
               end if;
            end;
         end if;
      end if;
      
      if Read_Success then
         if Filename = "sensor_temp_TCMz.dat" then Cache_TCMz := Val;
         elsif Filename = "sensor_temp_Tg0X.dat" then Cache_Tg0X := Val;
         elsif Filename = "sensor_temp_TaLP.dat" then Cache_TaLP := Val;
         elsif Filename = "sensor_temp_TaRF.dat" then Cache_TaRF := Val;
         elsif Filename = "sensor_temp_TaLT.dat" then Cache_TaLT := Val;
         elsif Filename = "sensor_temp_TaLW.dat" then Cache_TaLW := Val;
         elsif Filename = "sensor_temp_TaRT.dat" then Cache_TaRT := Val;
         elsif Filename = "sensor_temp_TaRW.dat" then Cache_TaRW := Val;
         elsif Filename = "sensor_temp_Ts0P.dat" or Filename = "sensor_temp_Ts0p.dat" then Cache_Ts0P := Val;
         elsif Filename = "sensor_temp_Ts1P.dat" or Filename = "sensor_temp_Ts1p.dat" then Cache_Ts1P := Val;
         elsif Filename = "sensor_temp_PSTR.dat" then Cache_PSTR := Val;
         elsif Filename = "sensor_fan_F0Ac.dat" then Cache_F0 := Val;
         elsif Filename = "sensor_fan_F1Ac.dat" then Cache_F1 := Val;
         elsif Filename = "sensor_fan_F0Tg.dat" then Cache_F0Tg := Val;
         elsif Filename = "sensor_fan_F1Tg.dat" then Cache_F1Tg := Val;
         end if;
         return Val;
      else
         if Filename = "sensor_temp_TCMz.dat" then return Cache_TCMz;
         elsif Filename = "sensor_temp_Tg0X.dat" then return Cache_Tg0X;
         elsif Filename = "sensor_temp_TaLP.dat" then return Cache_TaLP;
         elsif Filename = "sensor_temp_TaRF.dat" then return Cache_TaRF;
         elsif Filename = "sensor_temp_TaLT.dat" then return Cache_TaLT;
         elsif Filename = "sensor_temp_TaLW.dat" then return Cache_TaLW;
         elsif Filename = "sensor_temp_TaRT.dat" then return Cache_TaRT;
         elsif Filename = "sensor_temp_TaRW.dat" then return Cache_TaRW;
         elsif Filename = "sensor_temp_Ts0P.dat" or Filename = "sensor_temp_Ts0p.dat" then return Cache_Ts0P;
         elsif Filename = "sensor_temp_Ts1P.dat" or Filename = "sensor_temp_Ts1p.dat" then return Cache_Ts1P;
         elsif Filename = "sensor_temp_PSTR.dat" then return Cache_PSTR;
         elsif Filename = "sensor_fan_F0Ac.dat" then return Cache_F0;
         elsif Filename = "sensor_fan_F1Ac.dat" then return Cache_F1;
         elsif Filename = "sensor_fan_F0Tg.dat" then return Cache_F0Tg;
         elsif Filename = "sensor_fan_F1Tg.dat" then return Cache_F1Tg;
         else return 0.0;
         end if;
      end if;
    exception
       when others =>
          if Is_Open (File) then
             Close (File);
          end if;
          -- NOTE: Cache lookup duplicated from lines 970-989 above.
          -- Refactoring into a helper would require restructuring the
          -- nested begin blocks. Accept duplication for now.
          if Filename = "sensor_temp_TCMz.dat" then return Cache_TCMz;
         elsif Filename = "sensor_temp_Tg0X.dat" then return Cache_Tg0X;
         elsif Filename = "sensor_temp_TaLP.dat" then return Cache_TaLP;
         elsif Filename = "sensor_temp_TaRF.dat" then return Cache_TaRF;
         elsif Filename = "sensor_temp_TaLT.dat" then return Cache_TaLT;
         elsif Filename = "sensor_temp_TaLW.dat" then return Cache_TaLW;
         elsif Filename = "sensor_temp_TaRT.dat" then return Cache_TaRT;
         elsif Filename = "sensor_temp_TaRW.dat" then return Cache_TaRW;
         elsif Filename = "sensor_temp_Ts0P.dat" or Filename = "sensor_temp_Ts0p.dat" then return Cache_Ts0P;
         elsif Filename = "sensor_temp_Ts1P.dat" or Filename = "sensor_temp_Ts1p.dat" then return Cache_Ts1P;
         elsif Filename = "sensor_temp_PSTR.dat" then return Cache_PSTR;
         elsif Filename = "sensor_fan_F0Ac.dat" then return Cache_F0;
         elsif Filename = "sensor_fan_F1Ac.dat" then return Cache_F1;
         elsif Filename = "sensor_fan_F0Tg.dat" then return Cache_F0Tg;
         elsif Filename = "sensor_fan_F1Tg.dat" then return Cache_F1Tg;
         else return 0.0;
         end if;
   end Read_Sensor_Real;

   function Read_Sensor_Integer (Filename : String) return Integer is
      use Ada.Text_IO;
      File : File_Type;
      Val  : Integer := 0;
      package Int_IO is new Ada.Text_IO.Integer_IO (Integer);
   begin
      begin
          Open (File, In_File, "/Volumes/EARU_dataIO/" & Filename);
      exception
         when Name_Error | Use_Error =>
            begin
               Open (File, In_File, "/usr/local/EnvironmentalAwareReferentialUnit/" & Filename);
            exception
               when others =>
                  null;
            end;
      end;
      
      if Is_Open (File) then
         begin
            Int_IO.Get (File, Val);
         exception
            when others =>
               Val := 0;
         end;
         Close (File);
         Cache_Turbo := Val;
      end if;
      
      return Cache_Turbo;
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         return Cache_Turbo;
   end Read_Sensor_Integer;

   Cache_Fan_Pressure : Real := 0.0;

   function Read_Fan_Pressure_Est return Earu.Types.Real is
      use Ada.Text_IO;
      File : File_Type;
      Line_Buf : String (1 .. 256);
      Last     : Natural;
      Path     : constant String := "/Volumes/EARU_dataIO/smcFanPressurehPaDetection";
   begin
      begin
         Open (File, In_File, Path);
      exception
         when Name_Error | Use_Error =>
            -- Fallback: check symlinked local copy
            begin
               Open (File, In_File, "smcFanPressurehPaDetection");
            exception
               when others => return Cache_Fan_Pressure;
            end;
      end;

      while not End_Of_File (File) loop
         Get_Line (File, Line_Buf, Last);
         declare
            L : constant String := Line_Buf (1 .. Last);
         begin
            if Last >= 8 and then L (1 .. 8) = "EST_HPA:" then
               -- Extract value after "EST_HPA:" — trim leading spaces
               declare
                  Val_Str : constant String := Ada.Strings.Fixed.Trim (L (9 .. Last), Ada.Strings.Both);
               begin
                  Cache_Fan_Pressure := Real'Value (Val_Str);
               end;
               exit;
            end if;
         end;
      end loop;

      Close (File);
      return Cache_Fan_Pressure;
   exception
      when others =>
         if Is_Open (File) then Close (File); end if;
         return Cache_Fan_Pressure;
   end Read_Fan_Pressure_Est;

end Earu.IO;
