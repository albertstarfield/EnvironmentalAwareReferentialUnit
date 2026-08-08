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
   function Trim_Null (S : String) return String is
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
   function Read_File (Path : String) return String is
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

   --  ── Open-Meteo Forecast URL ─────────────────────────────────────────
   --  Lat/Lon from Earu.Types.Location_Type (earu-types.ads).
   --  timezone=auto  → server localizes timestamps.
   --  timeformat=unixtime → integer timestamps for easy Python comparison.
   --  forecast_days=16 → maximum Open-Meteo free-tier horizon.
   --
   --  Axiom: Coordinates Lat=-6.333, Lon=106.971 correspond to the
   --  EARU deployment location (Banten, Indonesia).  Verified against
   --  the Location_Type default in earu-types.ads.
   Forecast_URL : constant String :=
      "https://api.open-meteo.com/v1/forecast"
      & "?latitude=-6.333&longitude=106.971"
      --  Current conditions (13 fields)
      & "&current=temperature_2m,apparent_temperature,relative_humidity_2m"
      & ",precipitation,rain,weather_code,cloud_cover,pressure_msl"
      & ",wind_speed_10m,wind_direction_10m,surface_pressure"
      & ",visibility,evapotranspiration"
      --  Hourly forecast (26 fields × 16 days × 24 h)
      & "&hourly=temperature_2m,relative_humidity_2m,precipitation_probability"
      & ",precipitation,rain,cloud_cover,wind_speed_10m,wind_direction_10m"
      & ",weather_code,soil_temperature_0cm,soil_temperature_54cm"
      & ",soil_moisture_0_to_1cm,uv_index,direct_radiation"
      & ",global_tilted_irradiance,shortwave_radiation,sunshine_duration"
      & ",cape,freezing_level_height,boundary_layer_height,lifted_index"
      & ",vapour_pressure_deficit,total_column_integrated_water_vapour"
      & ",dew_point_2m,wet_bulb_temperature_2m,surface_pressure"
      --  Daily summary (8 fields × 16 days)
      & "&daily=temperature_2m_max,temperature_2m_min,precipitation_sum"
      & ",precipitation_probability_max,sunrise,sunset,uv_index_max"
      & ",daylight_duration"
      & "&timezone=auto&timeformat=unixtime&forecast_days=16";

   --  Output file path on the RAM disk.  Writing directly to EARU_dataIO
   --  avoids an extra copy and keeps the hot EARU_data.dat small (reduces
   --  CPU overhead from 15 Hz reads).  The viewer reads this file only
   --  when the WEATHER page (page 7) is active.
   Temp_File : constant String := "/Volumes/EARU_dataIO/EARU_meteo.dat";

   --  curl command template.  -s = silent, -f = fail on HTTP error,
   --  --max-time 15 = prevent hangs, -o = output file.
   --  Axiom: curl is available on all macOS systems by default.
   Curl_Template : constant String :=
      "curl -s -f --max-time 15 -o " & Temp_File & " '";

   --  Fetch interval: 30 minutes (1800 s).
   --  Axiom: Open-Meteo updates hourly.  30-min polling is well within
   --  the 10,000 req/day free-tier limit (~48 req/day).
   Fetch_Interval : constant Duration := 1800.0;

   --  ── Fetcher task body ───────────────────────────────────────────────

   task body Fetcher is
      Running : Boolean := False;
      Cmd     : constant String :=
         Curl_Template & Forecast_URL & "'";
      C_Cmd   : Interfaces.C.Strings.chars_ptr;
   begin
      accept Start do
         Running := True;
      end Start;

      Ada.Text_IO.Put_Line ("[WeatherFetcher] Task started, fetching in 5s...");
      delay 5.0;  --  Wait for network stack to initialize

      while Running loop
         begin
            Ada.Text_IO.Put_Line ("[WeatherFetcher] Fetching via curl...");

            --  Execute curl subprocess.
            C_Cmd := Interfaces.C.Strings.New_String (Cmd);
            declare
               Ret : constant Interfaces.C.int := C_System (C_Cmd);
            begin
               Interfaces.C.Strings.Free (C_Cmd);
               if Ret /= 0 then
                  Ada.Text_IO.Put_Line ("[WeatherFetcher] curl failed, rc=" &
                     Interfaces.C.int'Image (Ret));
               end if;
            end;

            --  Read the downloaded file.
            declare
               Body_Str : constant String := Trim_Null (Read_File (Temp_File));
            begin
               Ada.Text_IO.Put_Line ("[WeatherFetcher] Read " &
                  Natural'Image (Body_Str'Length) & " bytes from " & Temp_File);
               if Body_Str'Length > 2 then
                  Shared.Store (Body_Str);
                  Ada.Text_IO.Put_Line ("[WeatherFetcher] Stored " &
                     Natural'Image (Body_Str'Length) & " bytes");
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

      procedure Store (JSON : String) is
         N : constant Natural := Natural'Min (JSON'Length, Data'Length);
      begin
         Data (1 .. N) := JSON (JSON'First .. JSON'First + N - 1);
         Len := N;
      end Store;

      function Latest_JSON return String is
      begin
         if Len = 0 then
            return "";
         else
            return Data (1 .. Len);
         end if;
      end Latest_JSON;

      function Length return Natural is
      begin
         return Len;
      end Length;

   end Meteo_Buffer;

end Earu.Weather_Fetcher;
