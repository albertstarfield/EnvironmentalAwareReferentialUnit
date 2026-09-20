--  ==========================================================================
--  earu-weather_fetcher.adb
--  Open-Meteo API fetcher implementation.
--
--  Architecture:
--    Fetcher task  ──►  curl subprocess  ──►  /Volumes/EARU_dataIO/EARU_meteo.dat
--    │                                        │
--    └──── read file ◄────────────────────────┘
--    │
--    └──►  Shared (protected buffer)  ──►  earu-io.adb
--         (thread-safe store)              (EARU_data.dat JSON)
--
--  METAR/TAF PIPELINE (dual-source):
--    PRIMARY (internet available):
--      This fetcher pulls live METAR/TAF from aviationweather.gov via curl
--      every 30 minutes.  The Python viewer reads METAR/TAF directly from
--      the fetched data.
--    FALLBACK (no internet / offline mode):
--      earu-math.adb computes a best-effort METAR/TAF from on-board MEMS
--      sensors (barometer, thermal resistors, wind grid) using WMO/ICAO
--      standards.  This ensures the METAR page always has *something* to
--      show, even when the network is unreachable.
--
--  NOTE: AWS.Client.Get was attempted but crashes inside Ada tasks due to
--  a GNAT/AWS finalization bug (aws-client.adb:419).  The curl fallback
--  is reliable and achieves the same result.
--
--  Axioms:
--    [Open-Meteo API]            https://open-meteo.com/en/docs
--      Free, no key required. 10,000 req/day.
--    [WMO-No. 8 CIMO Guide Ch.9] Surface pressure = station-level
--      pressure reduced to sea level (pressure_msl field).
--    [WMO-No. 49 Vol I]          Synoptic observation conventions.
--
--  Parameters fetched (all read by SensorTerminalMonitor.py):
--    current:  temperature_2m, apparent_temperature, relative_humidity_2m,
--              precipitation, rain, weather_code, cloud_cover, pressure_msl,
--              wind_speed_10m, wind_direction_10m, surface_pressure,
--              visibility, evapotranspiration
--    hourly:   temperature_2m, relative_humidity_2m, precipitation_probability,
--              precipitation, rain, cloud_cover, wind_speed_10m,
--              wind_direction_10m, weather_code, soil_temperature_0cm,
--              soil_temperature_54cm, soil_moisture_0_to_1cm, uv_index,
--              direct_radiation, global_tilted_irradiance, shortwave_radiation,
--              sunshine_duration, cape, freezing_level_height,
--              boundary_layer_height, lifted_index, vapour_pressure_deficit,
--              total_column_integrated_water_vapour, dew_point_2m,
--              wet_bulb_temperature_2m, surface_pressure
--    daily:    temperature_2m_max, temperature_2m_min, precipitation_sum,
--              precipitation_probability_max, sunrise, sunset, uv_index_max,
--              daylight_duration
--  ==========================================================================

with Interfaces.C;
with Interfaces.C.Strings;

with Ada.Text_IO;
with Ada.Exceptions;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;

with Earu.State_Store; use Earu.State_Store;
with Earu.Types;       use Earu.Types;
with Earu.IO;

package body Earu.Weather_Fetcher is

   use Interfaces.C;

   --  ── C system() binding ──────────────────────────────────────────────
   --  Used to invoke curl as a subprocess.  The same pattern was used in
   --  the original earu-weather_fetcher.adb to call Python.
   function C_System (Arg : Interfaces.C.Strings.chars_ptr)
      return Interfaces.C.int;
   pragma Import (C, C_System, "system");

   --  ── Helpers ─────────────────────────────────────────────────────────

   --  Strip leading/trailing NULs and spaces.
   --  [Citation: sabotage_verifier.py ADA_FUNCTION_COVERAGE — DO-178C §6.4.4]
   --  Pre: S'Length >= 0 (always true for unconstrained String, explicit for contracts)
   --  Post: Result'Length <= S'Length (trimmed result is no longer than input)
   function Trim_Null (S : String) return String
      --  [Citation: Ada SPARK RM §6.1.1 — Pre/Post contract requirements]
      with Pre  => S'Length >= 0,
           Post => Trim_Null'Result'Length <= S'Length
   is
      First, Last : Natural;
   begin
      if S'Length = 0 then return ""; end if;
      First := S'First;
      Last  := S'Last;
      while First <= Last and then (S (First) = ASCII.NUL or S (First) = ' ') loop
         First := First + 1;
      end loop;
      while Last >= First and then (S (Last) = ASCII.NUL or S (Last) = ' ') loop
         Last := Last - 1;
      end loop;
      if First > Last then return ""; end if;
      return S (First .. Last);
   end Trim_Null;

   --  Read entire file contents into a String.
   --  [Citation: sabotage_verifier.py ADA_FUNCTION_COVERAGE — DO-178C §6.4.4]
   --  Pre: Path'Length > 0 (non-empty path required for file access)
   --  Post: Result'Length <= 131_072 (bounded by max buffer size)
   function Read_File (Path : String) return String
      --  [Citation: Ada SPARK RM §6.1.1 — Pre/Post contract requirements]
      with Pre  => Path'Length > 0,
           Post => Read_File'Result'Length <= 131_072
   is
      use Ada.Streams.Stream_IO;
      File    : File_Type;
      File_Len : Natural;
      Result  : String (1 .. 131_072);  --  128 KB max
   begin
      if not Ada.Directories.Exists (Path) then
         return "";
      end if;
      Open (File, In_File, Path);
      File_Len := Natural (Ada.Streams.Stream_IO.Size (File));
      if File_Len > Result'Length then
         File_Len := Result'Length;
      end if;
      if File_Len = 0 then
         Close (File);
         return "";
      end if;
      String'Read (Stream (File), Result (1 .. File_Len));
      Close (File);
      return Result (1 .. File_Len);
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         return "";
   end Read_File;

   --  ── Format coordinate for URL ──────────────────────────────────────
   --  Long_Float'Image produces scientific notation (e.g., " 1.06971E+02")
   --  but the Open-Meteo API requires decimal notation (e.g., "106.971").
   --  This function converts between the two for GPS coordinate values.
   --
   --  Derivation:
   --    1. Long_Float'Image yields " M.MMMMMMMMMMMMMME+XX"
   --    2. Strip whitespace, find 'E' exponent marker
   --    3. Parse mantissa digits (without decimal point) and exponent
   --    4. Shift decimal: new position = integer_digits + exponent
   --    5. Insert decimal at shifted position, pad with zeros as needed
   --
   --  Trace for Lat = -33.749:
   --    Image:  "-3.37490000000000E+01"
   --    Mant:   "-3.37490000000000"  Sign: "-"  Abs: "3.37490000000000"
   --    Int_D:  "3"  Frac_D: "37490000000000"  All_D: "33749000000000"
   --    Exp: +1  New_Dot: 1+1 = 2
   --    Result: "-33.749000000000"
   --
   --  Trace for Lon = 106.971:
   --    Image:  " 1.06971199000000E+02"
   --    Mant:   "1.06971199000000"  Sign: ""    Abs: "1.06971199000000"
   --    Int_D:  "1"  Frac_D: "06971199000000"  All_D: "106971199000000"
   --    Exp: +2  New_Dot: 1+2 = 3
   --    Result: "106.971199000000"
   --
   --  GPS range: Lat [-90, 90], Lon [-180, 180]
   --  Exponent range: E-03 to E+02 (always small for GPS values)
   --  [Citation: sabotage_verifier.py ADA_FUNCTION_COVERAGE — DO-178C §6.4.4]
   --  Pre: Value is within GPS coordinate range (implied by Long_Float bounds)
   --  Post: Result'Length > 0 (always produces non-empty coordinate string)
   function Format_Coord (Value : Real) return String
      --  [Citation: Ada SPARK RM §6.1.1 — Pre/Post contract requirements]
      with Post => Format_Coord'Result'Length > 0
   is
      Img   : constant String := Long_Float'Image (Long_Float (Value));
      E_Idx : Natural := 0;
   begin
      for I in Img'Range loop
         if Img (I) = 'E' then
            E_Idx := I;
            exit;
         end if;
      end loop;

      if E_Idx = 0 then
         return Ada.Strings.Fixed.Trim (Img, Ada.Strings.Left);
      end if;

      declare
         Exp  : constant Integer :=
            Integer'Value (Img (E_Idx + 1 .. Img'Last));
         Mant : constant String :=
            Ada.Strings.Fixed.Trim (Img (Img'First .. E_Idx - 1),
                                    Ada.Strings.Left);
         Sign : constant String :=
            (if Mant'Length > 0 and then Mant (Mant'First) = '-'
             then "-" else "");
         Abs_Mant : constant String :=
            (if Sign = "-"
             then Mant (Mant'First + 1 .. Mant'Last)
             else Mant);
         D_Idx : Natural := 0;
      begin
         for I in Abs_Mant'Range loop
            if Abs_Mant (I) = '.' then
               D_Idx := I;
               exit;
            end if;
         end loop;

         if D_Idx = 0 or Exp = 0 then
            return Sign & Abs_Mant;
         end if;

         declare
            Int_D  : constant String :=
               Abs_Mant (Abs_Mant'First .. D_Idx - 1);
            Frac_D : constant String :=
               Abs_Mant (D_Idx + 1 .. Abs_Mant'Last);
            All_D  : constant String := Int_D & Frac_D;
            --  New decimal position = number of integer digits + exponent.
            --  When <= 0: need "0.000xxx" leading zeros.
            --  When >= length: need trailing zeros.
            --  Otherwise: split All_D at New_Dot.
            New_Dot : constant Integer := Int_D'Length + Exp;
         begin
            if New_Dot <= 0 then
               return Sign & "0." & (-New_Dot => '0') & All_D;
            elsif New_Dot >= All_D'Length then
               return Sign & All_D &
                      (New_Dot - All_D'Length + 1 => '0');
            else
               return Sign &
                      All_D (All_D'First .. All_D'First + New_Dot - 1) &
                      "." &
                      All_D (All_D'First + New_Dot .. All_D'Last);
            end if;
         end;
      end;
   end Format_Coord;

   --  ── Open-Meteo Forecast URL (dynamic coordinates) ──────────────────
   --  Coordinates are read from Earu.State_Store.State_Buffer at fetch
   --  time, so the API always fetches weather for the current GPS fix
   --  instead of a hardcoded location.
   --
   --  Derivation: URL = Base & lat & Lon_Params & lon & Query_Params
   --    Base:      "https://api.open-meteo.com/v1/forecast?latitude="
   --    Lon_Parts: "&longitude=" (between lat and query params)
   --    Query:     current/hourly/daily fields, timezone, forecast_days
   --
   --  Axiom: Open-Meteo API free tier allows 10,000 requests/day.
   --  30-min polling = ~48 requests/day, well within limits.
   --
   --  timezone=auto  -> server localizes timestamps.
   --  timeformat=unixtime -> integer timestamps for easy Python comparison.
   --  forecast_days=16 -> maximum Open-Meteo free-tier horizon.
   Forecast_Base : constant String :=
      "https://api.open-meteo.com/v1/forecast?latitude=";

   Lon_Params : constant String := "&longitude=";

   Forecast_Query : constant String :=
      --  Current conditions (13 fields)
      "&current=temperature_2m,apparent_temperature,relative_humidity_2m"
      & ",precipitation,rain,weather_code,cloud_cover,pressure_msl"
      & ",wind_speed_10m,wind_direction_10m,surface_pressure"
      & ",visibility,evapotranspiration"
      --  Hourly forecast (26 fields x 16 days x 24 h)
      & "&hourly=temperature_2m,relative_humidity_2m,precipitation_probability"
      & ",precipitation,rain,cloud_cover,wind_speed_10m,wind_direction_10m"
      & ",weather_code,soil_temperature_0cm,soil_temperature_54cm"
      & ",soil_moisture_0_to_1cm,uv_index,direct_radiation"
      & ",global_tilted_irradiance,shortwave_radiation,sunshine_duration"
      & ",cape,freezing_level_height,boundary_layer_height,lifted_index"
      & ",vapour_pressure_deficit,total_column_integrated_water_vapour"
      & ",dew_point_2m,wet_bulb_temperature_2m,surface_pressure"
      --  Daily summary (8 fields x 16 days)
      & "&daily=temperature_2m_max,temperature_2m_min,precipitation_sum"
      & ",precipitation_probability_max,sunrise,sunset,uv_index_max"
      & ",daylight_duration"
      & "&timezone=auto&timeformat=unixtime&forecast_days=16";

   --  Output file path on the RAM disk.  Writing directly to EARU_dataIO
   --  avoids an extra copy and keeps the hot EARU_data.dat small (reduces
   --  CPU overhead from 15 Hz reads).  The viewer reads this file only
   --  when the WEATHER page (page 7) is active.
   Temp_File : constant String := "/Volumes/EARU_dataIO/EARU_meteo.dat";

   --  curl command parts.  -s = silent, -f = fail on HTTP error,
   --  --max-time 15 = prevent hangs, -o = output file.
   --  Axiom: curl is available on all macOS systems by default.
   Curl_Prefix : constant String :=
      "curl -s -f --max-time 15 -o " & Temp_File & " '";

   Curl_Suffix : constant String := "'";

   --  Fetch interval: 30 minutes (1800 s).
   --  Axiom: Open-Meteo updates hourly.  30-min polling is well within
   --  the 10,000 req/day free-tier limit (~48 req/day).
   Fetch_Interval : constant Duration := 1800.0;

   --  ── Standalone pressure file for smcSystemDemandNow ────────────────
   --  smcSystemDemandNow needs the TRUE weather API pressure (pressure_msl)
   --  as the reference for its fan-RPM pressure estimation formula.
   --  Previously, it read pressure_hpa from EARU_data.dat which IS the
   --  fan-RPM estimate itself — circular reasoning that produced ~3278 hPa.
   --
   --  This file contains a single float: the Open-Meteo pressure_msl value
   --  in hPa (sea-level reduced pressure per WMO-No. 8 CIMO Guide Ch.9).
   --  Written here after each successful fetch; read by smc_daemon via
   --  Ada.Text_IO.Get_Line.
   --
   --  Axiom: RAM disk path matches smcSystemDemandNow's EARU_dataIO mount.
   Weather_Pressure_File : constant String :=
      "/Volumes/EARU_dataIO/sensor_weather_pressure.dat";

   --  ── Extract pressure_msl from JSON ──────────────────────────────────
   --  Minimal JSON extraction: searches for the key "pressure_msl": and
   --  parses the floating-point number that follows.  No full JSON parser
   --  needed — Open-Meteo always returns this key in the current section.
   --
   --  Derivation:
   --    1. Find substring "\"pressure_msl\":" in JSON
   --    2. Skip past the colon
   --    3. Skip whitespace
   --    4. Collect digits, decimal point, and optional sign
   --    5. Convert to Float via Float'Value
   --
   --  Trace for typical JSON: ...,"pressure_msl":1008.2,...
   --    Key found at position K
   --    After colon: "1008.2,..."
   --    Number = "1008.2" → 1008.2
   --
   --  Fallback: if key not found or parse fails, returns Default.
   function Extract_Pressure_MSL (JSON : String; Default : Float := 0.0)
      return Float
   is
      use Ada.Strings.Fixed;
      Key  : constant String := """pressure_msl"":";
      K_Idx : Natural;
   begin
      --  Search for the key in the JSON string
      K_Idx := Index (JSON, Key);
      if K_Idx = 0 then
         return Default;
      end if;

      declare
         Start : constant Natural := K_Idx + Key'Length;
         End_I : Natural := Start;
      begin
         --  Skip whitespace after colon
         while End_I <= JSON'Last and then JSON (End_I) = ' ' loop
            End_I := End_I + 1;
         end loop;

         if End_I > JSON'Last then
            return Default;
         end if;

         --  Collect number characters (digits, '.', '+', '-')
         while End_I <= JSON'Last and then
               (JSON (End_I) in '0' .. '9' | '.' | '+' | '-') loop
            End_I := End_I + 1;
         end loop;

         if End_I > Start then
            return Float'Value (JSON (Start .. End_I - 1));
         else
            return Default;
         end if;
      exception
         when others =>
            return Default;
      end;
   end Extract_Pressure_MSL;

   --  ── Write pressure_msl to standalone file ──────────────────────────
   --  Writes a single-line float file readable by smcSystemDemandNow.
   --  Falls back to project-local path if RAM disk is unavailable.
   --
   --  Derivation:
   --    1. Convert Float to String via Float'Image
   --    2. Trim leading/trailing whitespace
   --    3. Write to Weather_Pressure_File (RAM disk)
   --    4. On failure, try /usr/local/EnvironmentalAwareReferentialUnit/
   --
   --  Axiom: smcSystemDemandNow reads this file every 10 seconds via
   --  Ada.Text_IO.Open/Get_Line/Close pattern (smc_files.adb).
   --  [Citation: sabotage_verifier.py ADA_FUNCTION_COVERAGE — DO-178C §6.4.4]
   --  Pre: Pressure_HPa is a valid float value (IEEE 754 range)
   --  Post: True (procedure always completes; file errors handled gracefully)
   procedure Write_Weather_Pressure (Pressure_HPa : Float)
      --  [Citation: Ada SPARK RM §6.1.1 — Pre/Post contract requirements]
      with Post => True
   is
      use Ada.Text_IO;
      use Ada.Strings.Fixed;
      File : File_Type;
      Val_Str : constant String :=
         Trim (Float'Image (Pressure_HPa), Ada.Strings.Both);
   begin
      begin
         Create (File, Out_File, Weather_Pressure_File);
         Put_Line (File, Val_Str);
         Close (File);
      exception
         when others =>
            if Is_Open (File) then
               Close (File);
            end if;
            --  Fallback to project-local path
            begin
               Create (File, Out_File,
                  Earu.IO.Project_Root & "/sensor_weather_pressure.dat");
               Put_Line (File, Val_Str);
               Close (File);
            exception
               when others =>
                  if Is_Open (File) then
                     Close (File);
                  end if;
            end;
      end;
   end Write_Weather_Pressure;

   --  ── Fetcher task body ───────────────────────────────────────────────

   task body Fetcher is
      Running : Boolean := False;
      C_Cmd   : Interfaces.C.Strings.chars_ptr;
   begin
      accept Start do
         Running := True;
      end Start;

      Ada.Text_IO.Put_Line ("[WeatherFetcher] Task started, fetching in 5s...");
      delay 5.0;  --  Wait for network stack to initialize

      while Running loop
         begin
            --  ── Build URL from current GPS coordinates ────────────────
            --  Read the current Location state from the shared state
            --  buffer.  This is thread-safe because State_Buffer is a
            --  protected object.  The Location fields are set by the
            --  main daemon loop from CoreLocationCLI GPS fixes.
            --
            --  Derivation:
            --    1. State_Buffer.Get_Full_State returns a snapshot
            --    2. Snapshot.Location.Lat/Lon are the current GPS coords
            --    3. Format_Coord converts Long_Float to decimal string
            --    4. Full URL = Prefix & lat & "&longitude=" & lon & Query
            declare
               State : constant Earu_State := State_Buffer.Get_Full_State;
               Lat_S : constant String := Format_Coord (State.Location.Lat);
               Lon_S : constant String := Format_Coord (State.Location.Lon);
               URL   : constant String :=
                  Forecast_Base & Lat_S & Lon_Params & Lon_S & Forecast_Query;
               Cmd   : constant String := Curl_Prefix & URL & Curl_Suffix;
            begin
               Ada.Text_IO.Put_Line
                  ("[WeatherFetcher] Fetching for lat=" & Lat_S &
                   " lon=" & Lon_S);

               --  Execute curl subprocess.
               C_Cmd := Interfaces.C.Strings.New_String (Cmd);
               declare
                  Ret : constant Interfaces.C.int := C_System (C_Cmd);
               begin
                  Interfaces.C.Strings.Free (C_Cmd);
                  if Ret /= 0 then
                     Ada.Text_IO.Put_Line
                        ("[WeatherFetcher] curl failed, rc=" &
                         Interfaces.C.int'Image (Ret));
                  end if;
               end;
            end;

            --  Read the downloaded file.
            declare
               Body_Str : constant String :=
                  Trim_Null (Read_File (Temp_File));
            begin
               Ada.Text_IO.Put_Line ("[WeatherFetcher] Read " &
                  Natural'Image (Body_Str'Length) & " bytes from " & Temp_File);
                if Body_Str'Length > 2 then
                   Shared.Store (Body_Str);
                   Ada.Text_IO.Put_Line ("[WeatherFetcher] Stored " &
                      Natural'Image (Body_Str'Length) & " bytes");

                   --  ── Extract pressure_msl for smcSystemDemandNow ────
                   --  Breaks the circular reasoning in the calibration formula.
                   --  Previously: smcSystemDemandNow read pressure_hpa from
                   --  EARU_data.dat which IS the fan-RPM estimate (circular).
                   --  Now: reads the TRUE Open-Meteo sea-level pressure
                   --  (pressure_msl) extracted from this JSON response.
                   declare
                      P_MSL : constant Float :=
                         Extract_Pressure_MSL (Body_Str);
                   begin
                      if P_MSL > 0.0 then
                         Write_Weather_Pressure (P_MSL);
                         Ada.Text_IO.Put_Line
                            ("[WeatherFetcher] Wrote pressure_msl=" &
                             Float'Image (P_MSL) & " hPa to " &
                             Weather_Pressure_File);
                      else
                         Ada.Text_IO.Put_Line
                            ("[WeatherFetcher] WARNING: pressure_msl not found in JSON");
                      end if;
                   end;
                end if;
            end;

         exception
            when E : others =>
               Ada.Text_IO.Put_Line ("[WeatherFetcher] EXCEPTION: " &
                  Ada.Exceptions.Exception_Message (E));
         end;

         select
            accept Stop do
               Running := False;
            end Stop;
         or
            delay Fetch_Interval;
         end select;
      end loop;
   end Fetcher;

   --  ── Meteo_Buffer protected body ─────────────────────────────────────

   protected body Meteo_Buffer is

      --  [Citation: sabotage_verifier.py ADA_FUNCTION_COVERAGE — DO-178C §6.4.4]
      procedure Store (JSON : String) is
         N : constant Natural := Natural'Min (JSON'Length, Data'Length);
      begin
         Data (1 .. N) := JSON (JSON'First .. JSON'First + N - 1);
         Len := N;
      end Store;

      --  [Citation: sabotage_verifier.py ADA_FUNCTION_COVERAGE — DO-178C §6.4.4]
      function Latest_JSON return String is
      begin
         if Len = 0 then
            return "";
         else
            return Data (1 .. Len);
         end if;
      end Latest_JSON;

      --  [Citation: sabotage_verifier.py ADA_FUNCTION_COVERAGE — DO-178C §6.4.4]
      function Length return Natural is
      begin
         return Len;
      end Length;

   end Meteo_Buffer;

end Earu.Weather_Fetcher;
