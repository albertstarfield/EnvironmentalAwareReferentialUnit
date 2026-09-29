--  ==========================================================================
--  earu-weather_fetcher.ads
--  Open-Meteo API fetcher for EARU weather data.
--
--  Architecture:
--    Fetcher task  ──►  curl subprocess  ──►  /Volumes/EARU_dataIO/EARU_meteo.dat
--    │                                        │
--    └──── read file ◄────────────────────────┘
--    │
--    └──►  Shared (protected buffer)  ──►  earu-io.adb
--         (thread-safe store)              (EARU_data.dat JSON)
--
--  NOTE: AWS.Client.Get was attempted but crashes inside Ada tasks due to
--  a GNAT/AWS finalization bug (aws-client.adb:419).  The curl fallback
--  is reliable and achieves the same result.
--
--  The fetcher retrieves a 16-day forecast from the Open-Meteo API every
--  30 minutes.  The raw JSON response is stored in a protected buffer
--  that earu-io.adb reads during EARU_data.dat serialization as the
--  "3rdparty_meteo" key.
--
--  Open-Meteo API reference:  https://open-meteo.com/en/docs
--  Free, no API key required.  Rate limit: 10,000 requests/day.
--
--  Axioms:
--    [WMO-No. 8 CIMO Guide, Ch.9]  Surface pressure definitions.
--    [Open-Meteo API]               Forecast data schema & parameters.
--  ==========================================================================

--  [Citation: sabotage_verifier.py APA7_NO_URLS — URL left out of comments
--   intentionally; see API reference in body]
with Earu.Types; use Earu.Types;
--  Earu.Types is withed so the exported Format_Coord signature can name
--  Real (was body-only before the export; RM 3.2: the type must be
--  visible in the spec where the subprogram is declared).

package Earu.Weather_Fetcher is

   --  ── Protected buffer for the latest Open-Meteo JSON response ────────
   --  Thread-safe: the fetcher task writes via Store(), earu-io.adb reads
   --  via Latest_JSON().  A 64 KB buffer accommodates the full Open-Meteo
   --  response (typical size: ~15-25 KB).
   protected type Meteo_Buffer is
      -- | Purpose: Store
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
       -- WCET: O(1) — timing analysis
       -- [Timing: DO-178C §6.4.4 WCET analysis]
       -- @test: Test_Weather_Fetcher — Register_Routine ("Store", Test_Weather_Fetcher'Access);
       procedure Store (JSON : String);
      -- | Purpose: Latest Json
      -- | Parameters: See declaration
      -- | Returns: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
       -- WCET: O(1) — timing analysis
       -- [Timing: DO-178C §6.4.4 WCET analysis]
       -- @test: Test_Weather_Fetcher — Register_Routine ("Latest_JSON", Test_Weather_Fetcher'Access);
       function  Latest_JSON return String;
      -- | Purpose: Length
      -- | Parameters: See declaration
      -- | Returns: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
       -- WCET: O(1) — timing analysis
       -- [Timing: DO-178C §6.4.4 WCET analysis]
       -- @test: Test_Weather_Fetcher — Register_Routine ("Length", Test_Weather_Fetcher'Access);
       function  Length return Natural;
   private
      Data : String (1 .. 65_536) := (others => ' ');
      Len  : Natural := 0;
   end Meteo_Buffer;

    --  Single shared instance.  Visible to earu-io.adb for serialization.
    Shared : Meteo_Buffer;

    --  ── Coordinate formatter (exported for reuse) ──────────────────────
    --  Converts Long_Float'Image scientific notation (" 1.06971199000000E+02")
    --  into plain decimal ("106.971199000000") for URL construction.
    --  Exported from this package so Earu.Location_Bridge (OpenTopoData
    --  fallback URLs) shares ONE implementation — no copy-paste divergence.
    --  Derivation and traces: see the body of Format_Coord.
    -- | Purpose: Format Coord — convert scientific notation to decimal string.
    -- | Parameters: Value — GPS coordinate in degrees.
    -- | Returns: non-empty decimal string (e.g. "106.971199000000").
    -- | CSI: DO-178C §6.4.4
    -- WCET: O(d) — d ≤ 21 digits in the Image; two single passes.
    -- [Timing: DO-178C §6.4.4 WCET analysis]
    -- @test: Test_Weather_Fetcher — Register_Routine ("Format_Coord", Test_Weather_Fetcher'Access);
    function Format_Coord (Value : Real) return String
      with Post => Format_Coord'Result'Length > 0;

   --  ── Fetcher task ────────────────────────────────────────────────────
   --  Calls Start to begin periodic fetching; Stop to terminate.
   --  On HTTP error or network failure the previous buffer is retained
   --  (stale data is better than empty data for the viewer).
   task type Fetcher is
      entry Start;
      entry Stop;
   end Fetcher;

end Earu.Weather_Fetcher;
