--  ==========================================================================
--  earu-weather_fetcher.ads
--  Open-Meteo API fetcher for EARU weather data.
--
--  Architecture:
--    Fetcher task  ──►  curl subprocess  ──►  /tmp/earu_meteo.json
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

package Earu.Weather_Fetcher is

   --  ── Protected buffer for the latest Open-Meteo JSON response ────────
   --  Thread-safe: the fetcher task writes via Store(), earu-io.adb reads
   --  via Latest_JSON().  A 64 KB buffer accommodates the full Open-Meteo
   --  response (typical size: ~15-25 KB).
   protected type Meteo_Buffer is
      procedure Store (JSON : String);
      function  Latest_JSON return String;
      function  Length return Natural;
   private
      Data : String (1 .. 65_536) := (others => ' ');
      Len  : Natural := 0;
   end Meteo_Buffer;

   --  Single shared instance.  Visible to earu-io.adb for serialization.
   Shared : Meteo_Buffer;

   --  ── Fetcher task ────────────────────────────────────────────────────
   --  Calls Start to begin periodic fetching; Stop to terminate.
   --  On HTTP error or network failure the previous buffer is retained
   --  (stale data is better than empty data for the viewer).
   task type Fetcher is
      entry Start;
      entry Stop;
   end Fetcher;

end Earu.Weather_Fetcher;
