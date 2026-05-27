with Ada.Text_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Interfaces.C;
with Interfaces.C.Strings;
with GNAT.SHA256;
with Earu.Types;

with Earu.Shm;
with Interfaces;
with Ada.Numerics.Generic_Elementary_Functions;

package body Earu.IO is
   use Earu.Types;
   use Earu.Shm;
   use type Interfaces.Unsigned_32;
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
            Str : String := Ada.Strings.Fixed.Trim (S (S'First .. Last), Ada.Strings.Both);
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
            Str : String := Ada.Strings.Fixed.Trim (S (S'First .. Last), Ada.Strings.Both);
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

   function Calculate_Hinge_Airflow (State : in Earu_State) return Real is
      package Math is new Ada.Numerics.Generic_Elementary_Functions (Real);
      Avg_Fan : constant Real := (State.SMC.Fan_RPMs (1) + State.SMC.Fan_RPMs (2)) / 2.0;
      Lid_Rad : constant Real := State.Lid_Angle * 3.141592653589793 / 180.0;
      Sin_Val : constant Real := Math.Sin (Lid_Rad);
      Airflow : Real;
   begin
      if Sin_Val < 0.0 then
         Airflow := 0.0;
      else
         Airflow := 15.0 * (Avg_Fan / 6000.0) * Sin_Val;
      end if;
      return Airflow;
   end Calculate_Hinge_Airflow;

   function Calculate_Outflow_Mass_Flow (State : in Earu_State) return Real is
      package Math is new Ada.Numerics.Generic_Elementary_Functions (Real);
      Avg_Fan : constant Real := (State.SMC.Fan_RPMs (1) + State.SMC.Fan_RPMs (2)) / 2.0;
      Lid_Rad : constant Real := State.Lid_Angle * 3.141592653589793 / 180.0;
      Sin_Val : constant Real := Math.Sin (Lid_Rad);
      Mass_Flow : Real;
   begin
      if Sin_Val < 0.0 then
         Mass_Flow := 0.0;
      else
         Mass_Flow := 0.003 * (Avg_Fan / 6000.0) * Sin_Val;
      end if;
      return Mass_Flow;
   end Calculate_Outflow_Mass_Flow;

   function Calculate_Outflow_Heatflux (State : in Earu_State) return Real is
      Mass_Flow : constant Real := Calculate_Outflow_Mass_Flow (State);
      Delta_T : Real := State.SMC.Airflow_Outlet_K - State.SMC.Airflow_Inlet_K;
      Heatflux : Real;
   begin
      if Delta_T < 0.0 then
         Delta_T := 0.0;
      end if;
      Heatflux := Mass_Flow * 1005.0 * Delta_T;
      return Heatflux;
   end Calculate_Outflow_Heatflux;

   function C_System (Command : Interfaces.C.char_array) return Interfaces.C.int;
   pragma Import (C, C_System, "system");

   function Read_NVRAM_Real (Name : String; Default : Earu.Types.Real := 0.0) return Earu.Types.Real is
      Ret : Interfaces.C.int;
      Tmp_File : constant String := "/tmp/earu_nvram_" & Name & ".txt";
      Command : constant String := "nvram " & Name & " 2>/dev/null | awk '{print $2}' > " & Tmp_File;
      File : Ada.Text_IO.File_Type;
      Line : Unbounded_String;
   begin
      Ret := C_System (Interfaces.C.To_C (Command));
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
      Command : constant String := "nvram " & Name & "=" & Value_Str;
   begin
      Ret := C_System (Interfaces.C.To_C (Command));
   end Write_NVRAM_Real;

   function Execute_And_Read_Real (Command : String; Default : Earu.Types.Real := 0.0) return Earu.Types.Real is
      Ret : Interfaces.C.int;
      Tmp_File : constant String := "/tmp/earu_cmd_out.txt";
      Full_Command : constant String := Command & " > " & Tmp_File & " 2>/dev/null";
      File : Ada.Text_IO.File_Type;
      Line : Unbounded_String;
   begin
      Ret := C_System (Interfaces.C.To_C (Full_Command));
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
   end Execute_And_Read_Real;

   function S (Str : String) return String is
      Result : Unbounded_String;
      I : Positive := Str'First;
      use Interfaces;
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

   function Base64_Encode (Data : String) return String is
      Table : constant String := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      Result : Unbounded_String;
      Tri : Natural;
      Val : Natural;
   begin
      if Data'Length = 0 then return ""; end if;
      for I in 0 .. (Data'Length / 3) - 1 loop
         Tri := Character'Pos(Data(Data'First + I*3)) * 65536 +
                Character'Pos(Data(Data'First + I*3 + 1)) * 256 +
                Character'Pos(Data(Data'First + I*3 + 2));
         Append (Result, Table (Tri / 262144 + 1));
         Append (Result, Table ((Tri / 4096) mod 64 + 1));
         Append (Result, Table ((Tri / 64) mod 64 + 1));
         Append (Result, Table (Tri mod 64 + 1));
      end loop;
      declare
         Rem_Len : constant Integer := Data'Length mod 3;
         Base_Idx : constant Integer := (Data'Length / 3) * 3;
      begin
         if Rem_Len = 1 then
            Val := Character'Pos(Data(Data'First + Base_Idx)) * 65536;
            Append (Result, Table (Val / 262144 + 1));
            Append (Result, Table ((Val / 4096) mod 64 + 1));
            Append (Result, "==");
         elsif Rem_Len = 2 then
            Val := Character'Pos(Data(Data'First + Base_Idx)) * 65536 + 
                   Character'Pos(Data(Data'First + Base_Idx + 1)) * 256;
            Append (Result, Table (Val / 262144 + 1));
            Append (Result, Table ((Val / 4096) mod 64 + 1));
            Append (Result, Table ((Val / 64) mod 64 + 1));
            Append (Result, "=");
         end if;
      end;
      return To_String (Result);
   end Base64_Encode;

   function Hash (Input : String) return String is
   begin
      return GNAT.SHA256.Digest (Input);
   end Hash;

   function Base64_Decode (Data : String) return String is
      Alphabet : constant String := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      function Char_To_Val (C : Character) return Integer is
      begin
         for I in 1 .. 64 loop
            if Alphabet (I) = C then return I - 1; end if;
         end loop;
         return 0;
      end Char_To_Val;
      Result : String (1 .. Data'Length);
      Len    : Natural := 0;
      I      : Integer := Data'First;
      Triple : Interfaces.Unsigned_32;
      C1, C2, C3, C4 : Character;
      V1, V2, V3, V4 : Integer;
   begin
      if Data'Length = 0 then return ""; end if;
      while I <= Data'Last - 3 loop
         C1 := Data (I); C2 := Data (I + 1); C3 := Data (I + 2); C4 := Data (I + 3);
         V1 := Char_To_Val (C1); V2 := Char_To_Val (C2); V3 := Char_To_Val (C3); V4 := Char_To_Val (C4);
         Triple := Interfaces.Shift_Left (Interfaces.Unsigned_32 (V1), 18) or
                   Interfaces.Shift_Left (Interfaces.Unsigned_32 (V2), 12) or
                   Interfaces.Shift_Left (Interfaces.Unsigned_32 (V3), 6) or
                   Interfaces.Unsigned_32 (V4);
         Len := Len + 1;
         Result (Len) := Character'Val (Interfaces.Shift_Right (Triple, 16) and 16#FF#);
         if C3 /= '=' then
            Len := Len + 1;
            Result (Len) := Character'Val (Interfaces.Shift_Right (Triple, 8) and 16#FF#);
         end if;
         if C4 /= '=' then
            Len := Len + 1;
            Result (Len) := Character'Val (Triple and 16#FF#);
         end if;
         I := I + 4;
      end loop;
      return Result (1 .. Len);
   exception
      when others => return "";
   end Base64_Decode;

   procedure Load_Initial_State (
      Path                 : String;
      Lat, Lon, Alt        : out Earu.Types.Real;
      Heading              : out Earu.Types.Real;
      Total_Dist           : out Earu.Types.Real;
      Cumulative_Fatigue   : out Earu.Types.Real;
      Machine_Life_Runtime : out Earu.Types.Real;
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
      Machine_Life_Runtime := 0.0;
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
      File     : Ada.Text_IO.File_Type;
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

      --  Append a 64-byte String field (hash / parity strings stored in State)
      function Trim64 (Str : String) return String is
      begin
         return Trim_Null (Str);
      end Trim64;

   begin
      Append (Buf, "{");

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
      ABool ("stutter_warning", State.Loop_Consistency.Stutter_Warning, False);
      Append (Buf, "}, ");

      --  ── high_res_drift ───────────────────────────────────────────────────
      Append (Buf, """high_res_drift"": {");
      AL ("t_cpu_ns",               State.Electron_Travel.T_CPU_ns);
      AL ("t_rtc_ns",               State.Electron_Travel.T_RTC_ns);
      AL ("t_gpu_ns",               State.Electron_Travel.T_GPU_ns);
      AL ("t_dat_ns",               State.Electron_Travel.T_DAT_ns);
      AL ("t_spu_ns",               State.Electron_Travel.T_SPU_ns);
      AP ("t_inference_fabric_ns",  "0");
      AP ("spu_lat_ms",             F (State.Electron_Travel.SPU_Lat_ms));
      AP ("gpu_lat_ms",             F (State.Electron_Travel.GPU_Lat_ms));
      AP ("rtc_jitter_ms",          F (State.Electron_Travel.RTC_Jitter_ms));
      AP ("inference_fabric_lat_ms","0.0");
      AP ("interference",           (if State.Electron_Travel.Interference then """Yes""" else """No"""));
      AP ("ts",                     S (Trim_Null (State.Electron_Travel.TS_ISO)), False);
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
      AP ("CorrectionFactor_Reckoning_Altitude",     F (State.Location.Corr_Alt));
      AP ("CorrectionFactor_Reckoning_Heading",      F (State.Location.Corr_Heading));
      AP ("CorrectionFactor_Reckoning_Velocity",     F (State.Location.Corr_Velocity));
      AP ("CorrectionFactor_Reckoning_VerticalRate", F (State.Location.Corr_VRate));
      AP ("master_warning", S (Trim_Null (State.Location.Warning_Reason)));
      AP ("master_caution", S (Trim_Null (State.Location.Caution_Reason)), False);
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
      AP    ("cpu_usage",                 F (State.System.CPU_Usage));
      AP    ("mem_usage",                 F (State.System.Mem_Usage));
      AI    ("battery_percent",           State.System.Battery_Percent);
      ABool ("battery_charging",          State.System.Battery_Charging);
      AP    ("BatteryDesignCapacityWh",   F (State.System.Battery_Design_Wh));
      AP    ("BatteryEnergyBankWh",       F (State.System.Battery_Energy_Wh));
      AP    ("BatteryFullChargeCapacityWh",F (State.System.Battery_Full_Wh));
      AP    ("BatteryHealthPct",          F (State.System.Battery_Health_Pct));
      Append (Buf, """load_avg"": [" &
         F (State.System.Load_Avg (1)) & ", " &
         F (State.System.Load_Avg (2)) & ", " &
         F (State.System.Load_Avg (3)) & "], ");
      AP    ("nonHumanInputHIDIdle",      F (State.System.Non_Human_HID_Idle_ns / 1_000_000_000.0));
      AP    ("ssd_used_pct",              F (State.System.SSD_Used_Pct));
      AP    ("ssd_available_spare",       F (State.System.SSD_Available_Spare));
      AP    ("ssd_life_left_years",       F (State.System.SSD_Life_Left_Years));
      AP    ("ssd_data_read_units",       F (State.System.SSD_Data_Read_Units));
      AP    ("ssd_data_write_units",      F (State.System.SSD_Data_Write_Units));
      AP    ("pmset_info",                S (Trim_Null (State.System.PMSet_Info)), False);
      Append (Buf, "}, ");

      --  ── smc ───────────────────────────────────────────────────────────────
      Append (Buf, """smc"": {");
      AP ("ambient_temp_k",  F (State.SMC.Ambient_Temp_K));
      AP ("humidity_pct",    F (State.SMC.Humidity_Pct));
      Append (Buf, """fan_rpms"": [" & F (State.SMC.Fan_RPMs (1)) & ", " & F (State.SMC.Fan_RPMs (2)) & "], ");
      AP ("thrust_n",        F (State.SMC.Thrust_N));
      AP ("massflow_kg_s",   F (State.SMC.Massflow_Kg_S));
      AP ("heatflux_j",      F (State.SMC.Heatflux_J));
      AP ("power",           F (State.SMC.Power));
      AP ("PowerRateUsage",  F (State.SMC.Power_Rate_Usage));
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
      AP ("talp_k",           F (State.SMC.TaLP_K));
      AP ("tarf_k",           F (State.SMC.TaRF_K));
      AI ("turbo",            State.SMC.Turbo);
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
                  "], " & F (WP.Press) & ", " & F (WP.Temp) & "]");
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
      Append (Buf, "}}, ");

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

      --  ── parity hashes (written by ML bridge into SHM header → State) ─────
      AP ("p_augmented", S (Trim64 (State.P_Augmented)));
      AP ("p_external",  S (Trim64 (State.P_External)));
      AP ("p_internal",  S (Trim64 (State.P_Internal)), False);

      --  ── close root & compute self-parity hash ─────────────────────────────
      declare
         Pre_Parity : constant String := To_String (Buf) & "}";
         P_Hash     : constant String := Hash (Pre_Parity);
      begin
         Append (Buf, ", ""parity"": """ & P_Hash & """");
      end;
      Append (Buf, "}");

      --  ── atomic write via rename ───────────────────────────────────────────
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Tmp_Path);
         Ada.Text_IO.Put_Line (File, To_String (Buf));
         Ada.Text_IO.Close (File);
         declare
            function rename (old_path, new_path : Interfaces.C.Strings.chars_ptr) return Interfaces.C.int;
            pragma Import (C, rename, "rename");
            C_Tmp  : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Tmp_Path);
            C_Path : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Path);
            Ret    : Interfaces.C.int := rename (C_Tmp, C_Path);
         begin
            Interfaces.C.Strings.Free (C_Tmp); Interfaces.C.Strings.Free (C_Path);
         end;
      exception
         when others => null;
      end;
   end Write_EARU_Data;

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
   Cache_F0   : Real := 2000.0;
   Cache_F1   : Real := 2000.0;
   Cache_Turbo : Integer := 0;

   function Read_Sensor_Real (Filename : String) return Earu.Types.Real is
      use Ada.Text_IO;
      File : File_Type;
      Val  : Real := 0.0;
   begin
      begin
         Open (File, In_File, "/usr/local/EnvironmentalAwareReferentialUnit/EARU_dataIO/" & Filename);
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
            Real_IO.Get (File, Val);
         exception
            when others =>
               Val := 0.0;
         end;
         Close (File);
      end if;
      
      if Val /= 0.0 then
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
         else return 0.0;
         end if;
      end if;
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
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
         Open (File, In_File, "/usr/local/EnvironmentalAwareReferentialUnit/EARU_dataIO/" & Filename);
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

end Earu.IO;
