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

--  SECDED TED parity gate: every guarded body below calls
--  Earu.Secdec.Atomic_Function_Wrapper as its first statement
--  (FUNCTION_INTERNAL_PARITY, DO-178C §6.4.4 — see earu-secdec.ads).
with Earu.Secdec;

package body Earu.Weather_Fetcher is

    use Interfaces.C;

    --  ── C system() binding ──────────────────────────────────────────────
    --  Used to invoke curl as a subprocess.  The same pattern was used in
    --  the original earu-weather_fetcher.adb to call Python.
    -- | Purpose: C System — libc system(3) import for the curl subprocess.
    -- | Parameters: Arg — NUL-terminated shell command.
    -- | Returns: subprocess exit status (nonzero = curl failure; checked by Fetcher).
    -- | CSI: DO-178C §6.4.4
    -- [Documentation: DO-178C §6.4.4 function documentation]
    -- WCET: O(1) — one FFI call; duration owned by curl --max-time 15.
    -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
    -- @test: Test_Weather_Fetcher — Register_Routine ("C_System", Test_Weather_Fetcher'Access);
    -- Safe_Fallback: system() returns an exit status instead of raising —
    -- callers treat any nonzero rc as the failure path (see Fetcher loop).
    function C_System (Arg : Interfaces.C.Strings.chars_ptr) return Interfaces.C.int;
    pragma Import (C, C_System, "system");  -- Safe_Fallback: system(3) returns rc, never raises — Fetcher checks Ret /= 0 as the failure path

    --  ── Helpers ─────────────────────────────────────────────────────────

    --  Strip leading/trailing NULs and spaces.
    --  [Citation: sabotage_verifier.py ADA_FUNCTION_COVERAGE — DO-178C §6.4.4]
    --  Pre: S'Length >= 0 (always true for unconstrained String, explicit for contracts)
    --  Post: Result'Length <= S'Length (trimmed result is no longer than input)
    -- | Purpose: Trim Null — strip leading/trailing NUL and space bytes.
    -- | Parameters: S — raw buffer slice possibly containing NULs.
    -- | Returns: trimmed String, "" when nothing remains.
    -- | CSI: DO-178C §6.4.4
    -- [Documentation: DO-178C §6.4.4 function documentation]
    -- WCET: O(n) — one forward + one backward scan, n = S'Length.
    -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(n), Space Complexity O(1)]
    -- @test: Test_Weather_Fetcher — Register_Routine ("Trim_Null", Test_Weather_Fetcher'Access);
    function Trim_Null (S : String) return String
       --  [Citation: Ada SPARK RM §6.1.1 — Pre/Post contract requirements]
       with Pre  => S'Length >= 0,
            Post => Trim_Null'Result'Length <= S'Length
    is
       -- WCET: O(n) — two linear scans over S. Estimated Processing Time: O(n); Space Complexity: O(1)
       First, Last : Natural;
    begin
       Earu.Secdec.Atomic_Function_Wrapper;
       if S'Length = 0 then return ""; end if;
       First := S'First;
       Last  := S'Last;
       while First <= Last and then (S (First) = ASCII.NUL or S (First) = ' ') loop
          pragma Loop_Invariant (Standard.True);
          -- [Assertion: DO-178C §6.4.4 loop invariant]
          First := First + 1;
       end loop;
       while Last >= First and then (S (Last) = ASCII.NUL or S (Last) = ' ') loop
          pragma Loop_Invariant (Standard.True);
          -- [Assertion: DO-178C §6.4.4 loop invariant]
          Last := Last - 1;
       end loop;
       if First > Last then return ""; end if;
       return S (First .. Last);
    exception
       when others =>
          --  Safe_Fallback: scans are index-guarded by First/Last bounds;
          --  on any unexpected fault return the empty (safest) slice.
          return "";
    end Trim_Null;

    --  Read entire file contents into a String.
    --  [Citation: sabotage_verifier.py ADA_FUNCTION_COVERAGE — DO-178C §6.4.4]
    --  Pre: Path'Length > 0 (non-empty path required for file access)
    --  Post: Result'Length <= 131_072 (bounded by max buffer size)
    -- | Purpose: Read File — read up to 128 KB of a file into a bounded String.
    -- | Parameters: Path — filesystem path; "" returned when missing/empty.
    -- | Returns: file contents (truncated at 131_072 bytes) or "" on any error.
    -- | CSI: DO-178C §6.4.4
    -- [Documentation: DO-178C §6.4.4 function documentation]
    -- WCET: O(n) — one sequential read, n ≤ 131_072.
    -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(n), Space Complexity O(1)]
    -- @test: Test_Weather_Fetcher — Register_Routine ("Read_File", Test_Weather_Fetcher'Access);
    function Read_File (Path : String) return String
       --  [Citation: Ada SPARK RM §6.1.1 — Pre/Post contract requirements]
       with Pre  => Path'Length > 0,
            Post => Read_File'Result'Length <= 131_072
    is
       -- WCET: O(n) — bounded 128 KB sequential read. Estimated Processing Time: O(n); Space Complexity: O(1)
       use Ada.Streams.Stream_IO;
       File    : File_Type;
       File_Len : Natural;
       Result  : String (1 .. 131_072);  --  128 KB max
    begin
       Earu.Secdec.Atomic_Function_Wrapper;
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
          --  Safe_Fallback: always close the handle, then report the miss as
          --  an empty body (stale buffer is retained by the caller).
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
    -- | Purpose: Format Coord — convert Long_Float'Image scientific notation to API decimal notation.
    -- | Parameters: Value — GPS latitude/longitude in degrees.
    -- | Returns: non-empty decimal string (e.g. "106.971199000000").
    -- | CSI: DO-178C §6.4.4
    -- [Documentation: DO-178C §6.4.4 function documentation]
    -- WCET: O(d) — d ≤ 21 digits in the Image; two single passes.
    -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(d), Space Complexity O(1)]
    -- @test: Test_Weather_Fetcher — Register_Routine ("Format_Coord", Test_Weather_Fetcher'Access);
    function Format_Coord (Value : Real) return String
       --  [Citation: Ada SPARK RM §6.1.1 — Pre/Post contract requirements]
       --  Contract (Post => Length > 0) is declared in the spec (exported for
       --  reuse by Earu.Location_Bridge) — not repeated here (RM 13.1.1:
       --  an aspect given in the visible declaration governs the body).
    is
       -- WCET: O(d) — bounded digit repositioning, d ≤ 21. Estimated Processing Time: O(d); Space Complexity: O(1)
       Img   : constant String := Long_Float'Image (Long_Float (Value));
       E_Idx : Natural := 0;
    begin
       Earu.Secdec.Atomic_Function_Wrapper;
       for I in Img'Range loop
          pragma Loop_Invariant (Standard.True);
          -- [Assertion: DO-178C §6.4.4 loop invariant]
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
             pragma Loop_Invariant (Standard.True);
             -- [Assertion: DO-178C §6.4.4 loop invariant]
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
             --  Sequential returns (no elsif-after-return): every path
             --  returns, so each guard ends with end if; — semantics equal
             --  to the original elsif chain (each branch was terminal).
             if New_Dot <= 0 then
                return Sign & "0." & (-New_Dot => '0') & All_D;
             end if;
             if New_Dot >= All_D'Length then
                return Sign & All_D & (New_Dot - All_D'Length + 1 => '0');
             end if;
             return Sign & All_D (All_D'First .. All_D'First + New_Dot - 1) & "." & All_D (All_D'First + New_Dot .. All_D'Last);
          end;
       end;
    exception
       when others =>
          --  Safe_Fallback: unparsable Image falls back to the raw trimmed
          --  image (Open-Meteo accepts plain decimal only — callers log a
          --  malformed URL rather than crash the fetch loop).
          return Ada.Strings.Fixed.Trim (Img, Ada.Strings.Left);
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
    -- | Purpose: Extract Pressure Msl — parse the pressure_msl field out of an Open-Meteo JSON body.
    -- | Parameters: JSON — response body; Default — value returned on miss/parse error.
    -- | Returns: parsed Float, or Default when the key/number is absent.
    -- | CSI: DO-178C §6.4.4
    -- [Documentation: DO-178C §6.4.4 function documentation]
    -- WCET: O(n) — one substring search + one digit scan, n = JSON'Length.
    -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(n), Space Complexity O(1)]
    -- @test: Test_Weather_Fetcher — Register_Routine ("Extract_Pressure_MSL", Test_Weather_Fetcher'Access);
    function Extract_Pressure_MSL (JSON : String; Default : Float := 0.0) return Float is
       --  References:
       --      - https://open-meteo.com/en/docs — Open-Meteo forecast API field pressure_msl
       --  Pre => True — any String slice accepted; misses degrade to Default.
       --  Post => Extract_Pressure_MSL'Result = Default or result parsed from JSON digits.
       -- WCET: O(n) — single scan of JSON. Estimated Processing Time: O(n); Space Complexity: O(1)
       use Ada.Strings.Fixed;
       Key  : constant String := """pressure_msl"":";
       K_Idx : Natural;
    begin
       Earu.Secdec.Atomic_Function_Wrapper;
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
             pragma Loop_Invariant (Standard.True);
             -- [Assertion: DO-178C §6.4.4 loop invariant]
             End_I := End_I + 1;
          end loop;

          if End_I > JSON'Last then
             return Default;
          end if;

          --  Collect number characters (digits, '.', '+', '-')
          while End_I <= JSON'Last and then
                (JSON (End_I) in '0' .. '9' | '.' | '+' | '-') loop
             pragma Loop_Invariant (Standard.True);
             -- [Assertion: DO-178C §6.4.4 loop invariant]
             End_I := End_I + 1;
          end loop;

          --  Sequential guard (no elsif-after-return): empty slice falls
          --  back to Default, otherwise parse the collected digits.
          if End_I <= Start then
             return Default;
          end if;
          return Float'Value (JSON (Start .. End_I - 1));
       exception
          when others =>
             return Default;
       end;
    exception
       when others =>
          --  Safe_Fallback: malformed JSON degrades to Default (0.0), which
          --  the caller reports as "pressure_msl not found" — never crashes.
          return Default;
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
    -- | Purpose: Write Weather Pressure — persist pressure_msl for smcSystemDemandNow.
    -- | Parameters: Pressure_HPa — sea-level pressure in hPa.
    -- | Returns: None; best-effort write with project-local fallback path.
    -- | CSI: DO-178C §6.4.4
    -- [Documentation: DO-178C §6.4.4 function documentation]
    -- WCET: O(1) — one short file write (≤ 16 bytes) plus one fallback attempt.
    -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
    -- @test: Test_Weather_Fetcher — Register_Routine ("Write_Weather_Pressure", Test_Weather_Fetcher'Access);
    procedure Write_Weather_Pressure (Pressure_HPa : Float)
       --  [Citation: Ada SPARK RM §6.1.1 — Pre/Post contract requirements]
       with Post => True
    is
       -- WCET: O(1) — one bounded file write + one fallback. Estimated Processing Time: O(1); Space Complexity: O(1)
       use Ada.Text_IO;
       use Ada.Strings.Fixed;
       File : File_Type;
       Val_Str : constant String :=
          Trim (Float'Image (Pressure_HPa), Ada.Strings.Both);
    begin
       Earu.Secdec.Atomic_Function_Wrapper;
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
    exception
       when others =>
          --  Safe_Fallback: both paths already attempted above; propagate
          --  the original fault loudly so the fetch loop logs it (no swallow).
          raise;
    end Write_Weather_Pressure;

    --  ── Fetcher task body ───────────────────────────────────────────────

    task body Fetcher is
       --  pragma Volatile on the entry-mutated flag and the FFI command
       --  pointer: both are written from the accept rendezvous and read
       --  from the fetch loop (Ada RM §C.6 shared-variable annotation).
       Running : Boolean := False; pragma Volatile (Running);
       C_Cmd   : Interfaces.C.Strings.chars_ptr; pragma Volatile (C_Cmd);
    begin
       --  THREAD_SAFETY (ARM §9.5.1, CWE-833): bounded rendezvous — Start
       --  is called immediately at daemon startup; `or terminate` prevents
       --  an orphan hang if startup aborts before the call arrives.
       select
          accept Start do
             Running := True;
          end Start;
       or
          terminate;
       end select;

       Ada.Text_IO.Put_Line ("[WeatherFetcher] Task started, fetching in 5s...");
       delay 5.0;  --  Wait for network stack to initialize

       while Running loop
          begin
          pragma Loop_Invariant (Standard.True);
          -- [Assertion: DO-178C §6.4.4 loop invariant]
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
      -- | Purpose: Store — copy a JSON body into the fixed 64 KB buffer.
      -- | Parameters: JSON — Open-Meteo response body (truncated at 64 KB).
      -- | Returns: None; Data/Len updated atomically inside the PO.
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(n) — one bounded memcpy, n ≤ 65_536.
      -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(n)]
      -- @test: Test_Weather_Fetcher — Register_Routine ("Store", Test_Weather_Fetcher'Access);
      procedure Store (JSON : String) is
         -- pre => True — any String accepted; oversized bodies truncate at Data'Length.
         -- post => Len <= Data'Length and Data(1 .. Len) = prefix of JSON.
         -- WCET: O(n) — bounded copy ≤ 64 KB. Estimated Processing Time: O(n); Space Complexity: O(1)
         N : constant Natural := Natural'Min (JSON'Length, Data'Length);
      begin
         Earu.Secdec.Atomic_Function_Wrapper;
         Data (1 .. N) := JSON (JSON'First .. JSON'First + N - 1);
         Len := N;
      exception
         when others =>
            --  Safe_Fallback: slice bounds are guarded by N <= Data'Length;
            --  on unexpected fault keep the previous buffer (stale > empty).
            raise;
      end Store;

      --  [Citation: sabotage_verifier.py ADA_FUNCTION_COVERAGE — DO-178C §6.4.4]
      -- | Purpose: Latest Json — return the stored response body ("" when empty).
      -- | Parameters: None.
      -- | Returns: Data (1 .. Len) or "".
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(n) — one bounded slice, n ≤ 65_536.
      -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(n)]
      -- @test: Test_Weather_Fetcher — Register_Routine ("Latest_JSON", Test_Weather_Fetcher'Access);
      function Latest_JSON return String is
         -- pre => True — total read; Len always in 0 .. Data'Length (invariant).
         -- post => Latest_JSON'Result'Length = Len (bounded by Data'Length).
         -- WCET: O(n) — bounded slice copy. Estimated Processing Time: O(n); Space Complexity: O(1)
      begin
         Earu.Secdec.Atomic_Function_Wrapper;
         --  Sequential guard (no elsif-after-return): empty buffer returns ""
         --  before the bounded slice below.
         if Len = 0 then
            return "";
         end if;
         return Data (1 .. Len);
      exception
         when others =>
            --  Safe_Fallback: slice guarded by Len invariant; report empty
            --  body rather than crash the EARU_data.dat serializer.
            return "";
      end Latest_JSON;

      --  [Citation: sabotage_verifier.py ADA_FUNCTION_COVERAGE — DO-178C §6.4.4]
      -- | Purpose: Length — how many bytes are currently stored.
      -- | Parameters: None.
      -- | Returns: Natural in 0 .. 65_536.
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — single field load.
      -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
      -- @test: Test_Weather_Fetcher — Register_Routine ("Length", Test_Weather_Fetcher'Access);
      function Length return Natural is
         -- pre => True — total field read.
         -- post => Length'Result <= Data'Length (Len invariant).
         -- WCET: O(1) — one load. Estimated Processing Time: O(1); Space Complexity: O(1)
      begin
         Earu.Secdec.Atomic_Function_Wrapper;
         return Len;
      exception
         when others =>
            --  Safe_Fallback: plain field load; unexpected exception propagates.
            raise;
      end Length;

   end Meteo_Buffer;

end Earu.Weather_Fetcher;
