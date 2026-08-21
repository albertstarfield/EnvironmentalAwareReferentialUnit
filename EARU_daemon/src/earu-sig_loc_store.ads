--  Significant Location persistence for the EARU daemon.
--
--  Owns the JSON file at BASE_PATH/save_state/significant_locations.json.
--  This replaces the Python sidecar's file I/O: detection happens in Python
--  (in-memory cache), packing into shared memory happens in Python, but
--  durable read/write of the JSON file is done here in Ada for:
--    1. Atomic writes (no partial JSON on crash)
--    2. Single owner (no race between Python write and Ada read)
--    3. Startup recovery (load cached locations from last session)
--
--  JSON format (array of objects):
--  [
--    {
--      "timestamp": "2026-05-15T10:30:00Z",
--      "lat": 12.3456,
--      "lon": 78.9012,
--      "alt": 100.0
--    }
--  ]

package Earu.Sig_Loc_Store is

   SIG_LOC_JSON_PATH : constant String :=
     "/usr/local/EnvironmentalAwareReferentialUnit/save_state/significant_locations.json";

   --  Load significant locations from JSON file into State.
   --  Called once on daemon startup.
   procedure Load_Sig_Locs;

   --  Save current significant locations from State to JSON file.
   --  Called after each ML cycle when Sig_Loc_Count > 0.
   procedure Save_Sig_Locs;

end Earu.Sig_Loc_Store;
