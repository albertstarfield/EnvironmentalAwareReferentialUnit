-- Purpose: Significant Location persistence for the EARU daemon.
--          Owns the JSON file at BASE_PATH/save_state/significant_locations.json.
--          This replaces the Python sidecar's file I/O: detection happens in Python
--          (in-memory cache), packing into shared memory happens in Python, but
--          durable read/write of the JSON file is done here in Ada for:
--            1. Atomic writes (no partial JSON on crash)
--            2. Single owner (no race between Python write and Ada read)
--            3. Startup recovery (load cached locations from last session)
--
-- JSON format (array of objects):
-- [
--   {
--     "timestamp": "2026-05-15T10:30:00Z",
--     "lat": 12.3456,
--     "lon": 78.9012,
--     "alt": 100.0
--   }
-- ]

with Earu.IO;
package Earu.Sig_Loc_Store is

   -- Purpose: Return the filesystem path to the significant_locations JSON file.
   -- Returns: String containing the full path to the JSON persistence file.
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Sig_Loc_Store — Register_Routine ("Sig_Loc_Json_Path", Test_Sig_Loc_Store'Access);
   -- pre => True — Project_Root constant join; total function.
   -- post => True — non-empty path ending in significant_locations.json.
   function Sig_Loc_Json_Path return String;

   -- Purpose: Load significant locations from the JSON file into the
   --          daemon's in-memory state buffer. Called once on daemon startup.
   -- Returns: None (procedure, populates State_Buffer via Load_Sig_Loc).
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Sig_Loc_Store — Register_Routine ("Load_Sig_Locs", Test_Sig_Loc_Store'Access);
   -- pre => True — idempotent startup load; missing file is a documented no-op.
   -- post => True — buffer holds up to 10 entries (or unchanged on read error).
   procedure Load_Sig_Locs;

   -- Purpose: Save the current significant locations from the daemon's
   --          in-memory state buffer to the JSON file. Called after each ML
   --          cycle when Sig_Loc_Count > 0.
   -- Returns: None (procedure, writes to disk atomically).
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Sig_Loc_Store — Register_Routine ("Save_Sig_Locs", Test_Sig_Loc_Store'Access);
   -- pre => True — Count = 0 short-circuits; otherwise ≤ 10 objects written.
   -- post => True — file contains the snapshot, or prior file survives on error.
   procedure Save_Sig_Locs;

end Earu.Sig_Loc_Store;
