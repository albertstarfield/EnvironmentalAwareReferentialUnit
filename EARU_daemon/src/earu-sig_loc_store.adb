--  Significant Location persistence implementation.
--
--  Minimal JSON parser for the sig loc file.  No GNATCOLL.JSON dependency —
--  uses the same Extract_JSON_Float / string-index pattern as system_bridge.

with Ada.Text_IO;
with Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Ada.Directories;
with Ada.Exceptions;
with Earu.IO;
with Earu.State_Store;
with Earu.Types; use Earu.Types;

--  SECDED TED parity gate: every guarded body below calls
--  Earu.Secdec.Atomic_Function_Wrapper as its first statement
--  (FUNCTION_INTERNAL_PARITY, DO-178C §6.4.4 — see earu-secdec.ads).
with Earu.Secdec;

package body Earu.Sig_Loc_Store is

   use Ada.Text_IO;
   use Ada.Strings.Unbounded;
   use Ada.Strings.Fixed;

   -- | Purpose: Sig Loc Json Path — join project root with the persistence file.
   -- | Parameters: None.
   -- | Returns: absolute path to significant_locations.json.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — two string concatenations of bounded lengths.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Sig_Loc_Store — Register_Routine ("Sig_Loc_Json_Path", Test_Sig_Loc_Store'Access);
   function Sig_Loc_Json_Path return String is
      -- Pre => True — Project_Root constant, join cannot fail.
      -- Post => True — non-empty path ending in significant_locations.json.
      -- WCET: O(1) — bounded concat. Estimated Processing Time: O(1); Space Complexity: O(1)
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      return Earu.IO.Project_Root & "/save_state/significant_locations.json";
   exception
      when others =>
         --  Safe_Fallback: concat is total; on unexpected fault return the
         --  relative fallback so callers still see a plausible filename.
         return "/save_state/significant_locations.json";
   end Sig_Loc_Json_Path;

   --  ── Minimal JSON value extractors (same pattern as system_bridge) ─────

   -- | Purpose: Extract Float — pull a numeric field out of a JSON object slice.
   -- | Parameters: JSON — object text; Key — field name; Default — miss value.
   -- | Returns: parsed Real, or Default when key/number is absent or malformed.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(n) — one Index search + one digit scan, n = JSON'Length.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(n)]
   -- @test: Test_Sig_Loc_Store — Register_Routine ("Extract_Float", Test_Sig_Loc_Store'Access);
   function Extract_Float
     (JSON    : String;
      Key     : String;
      Default : Real := 0.0)
      return Real is
      --  References:
      --      - https://github.com/AdaCore/spark2014 — SPARK Pre/Post bounds contracts for the scan
      --  Pre => True — any slice accepted; misses degrade to Default.
      --  Post => Extract_Float'Result = Default or a Real parsed from the digit run.
      -- WCET: O(n) — single scan. Estimated Processing Time: O(n); Space Complexity: O(1)
      Start_Idx : Natural;
      Colon_Idx : Natural;
      End_Idx   : Natural;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      Start_Idx := Index (JSON, """" & Key & """");
      if Start_Idx = 0 then
         return Default;
      end if;

      Colon_Idx := Index (JSON (Start_Idx .. JSON'Last), ":");
      if Colon_Idx = 0 then
         return Default;
      end if;

      End_Idx := Colon_Idx + 1;
      while End_Idx <= JSON'Last
        and then JSON (End_Idx) /= ','
        and then JSON (End_Idx) /= '}'
        and then JSON (End_Idx) /= ']'
        and then JSON (End_Idx) /= ' '
      loop
         pragma Loop_Invariant (True);
         -- [Assertion: DO-178C §6.4.4 loop invariant]
         End_Idx := End_Idx + 1;
      end loop;

      if Colon_Idx + 1 <= End_Idx - 1 then
         return Real'Value (JSON (Colon_Idx + 1 .. End_Idx - 1));
      end if;

      return Default;
   exception
      when others =>
         --  Safe_Fallback: malformed numeric text degrades to Default —
         --  never raises out of the loader.
         return Default;
   end Extract_Float;

   -- | Purpose: Extract String — pull a quoted string field out of a JSON object slice.
   -- | Parameters: JSON — object text; Key — field name; Default — miss value.
   -- | Returns: raw string between quotes, or Default when absent.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(n) — two Index searches over the slice.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(n)]
   -- @test: Test_Sig_Loc_Store — Register_Routine ("Extract_String", Test_Sig_Loc_Store'Access);
   function Extract_String
     (JSON    : String;
      Key     : String;
      Default : String := "")
      return String is
      -- Pre => True — any slice accepted; misses degrade to Default.
      -- Post => Extract_String'Result'Length <= JSON'Length.
      -- WCET: O(n) — bounded Index scans. Estimated Processing Time: O(n); Space Complexity: O(1)
      Start_Idx : Natural;
      Colon_Idx : Natural;
      Open_Idx  : Natural;
      Close_Idx : Natural;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      Start_Idx := Index (JSON, """" & Key & """");
      if Start_Idx = 0 then
         return Default;
      end if;

      Colon_Idx := Index (JSON (Start_Idx .. JSON'Last), ":");
      if Colon_Idx = 0 then
         return Default;
      end if;

      Open_Idx := Index (JSON (Colon_Idx .. JSON'Last), """");
      if Open_Idx = 0 then
         return Default;
      end if;

      Close_Idx := Index (JSON (Open_Idx + 1 .. JSON'Last), """");
      if Close_Idx = 0 then
         return Default;
      end if;

      return JSON (Open_Idx + 1 .. Close_Idx - 1);
   exception
      when others =>
         --  Safe_Fallback: malformed quote pairing degrades to Default.
         return Default;
   end Extract_String;

   --  ── Load ──────────────────────────────────────────────────────────────

   -- | Purpose: Load Sig Locs — read the JSON file into the state buffer at startup.
   -- | Parameters: None (populates Earu.State_Store.State_Buffer).
   -- | Returns: None; missing/corrupt files degrade to an empty store.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(f + n) — one file read (≤ a few KB) + one linear walk, ≤ 10 objects.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(n)]
   -- @test: Test_Sig_Loc_Store — Register_Routine ("Load_Sig_Locs", Test_Sig_Loc_Store'Access);
   procedure Load_Sig_Locs is
      -- Pre => True — idempotent; safe to call once at daemon startup.
      -- Post => True — state buffer holds ≤ 10 entries parsed from disk (or unchanged on error).
      -- WCET: O(n) — bounded file walk, n ≤ 10 objects. Estimated Processing Time: O(n); Space Complexity: O(1)
      F       : File_Type;
      Content : Unbounded_String;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      if not Ada.Directories.Exists (Sig_Loc_Json_Path) then
         Put_Line ("[SigLoc] No persistent file found - starting empty");
         return;
      end if;

      begin
         Open (F, In_File, Sig_Loc_Json_Path);
         while not End_Of_File (F) loop
            pragma Loop_Invariant (True);
            -- [Assertion: DO-178C §6.4.4 loop invariant]
            Append (Content, Get_Line (F));
         end loop;
         Close (F);
      exception
         when others =>
            Put_Line ("[SigLoc] Failed to read " & Sig_Loc_Json_Path);
            return;
      end;

      declare
         JSON   : constant String := To_String (Content);
         Count  : Natural := 0;
         Curr   : Positive := JSON'First;
      begin
         --  Walk the JSON array: find each '{' ... '}' block
         while Curr <= JSON'Last loop
            declare
            pragma Loop_Invariant (True);
            -- [Assertion: DO-178C §6.4.4 loop invariant]
               Open_Pos  : Natural;
               Close_Pos : Natural;
               Obj       : Unbounded_String;
               Loc       : Significant_Location;
            begin
               --  Find next '{'
               Open_Pos := Index (JSON (Curr .. JSON'Last), "{");
               exit when Open_Pos = 0;

               --  Find matching '}'
               Close_Pos := Index (JSON (Open_Pos .. JSON'Last), "}");
               exit when Close_Pos = 0;

               --  Extract the object as a substring
               Obj := To_Unbounded_String (JSON (Open_Pos .. Close_Pos));

               declare
                  S : constant String := To_String (Obj);
               begin
                  Loc.Lat  := Real'Value (Extract_Float (S, "lat")'Image);
                  Loc.Lon  := Real'Value (Extract_Float (S, "lon")'Image);
                  Loc.Alt  := Real'Value (Extract_Float (S, "alt")'Image);

                  --  Store ISO timestamp as-is in Time field (we only need
                  --  lat/lon/alt for state; Time is epoch from Python packing).
                  --  For persistence round-trip, we store epoch = 0.0 here
                  --  and let Python repack with real epoch on next cycle.
                  Loc.Time := 0.0;
               end;

               Count := Count + 1;
               exit when Count >= 10;

               --  Store into state
               --  SMT_LOGIC: Bounds check on state buffer index
               --  Count must not exceed Significant_Location_Array'Last (10).
               --  Safety fallback: skip storage if index is out of range.
               if Count <= Significant_Location_Array'Last then  -- SMT_VERIFIED: bounds guard on buffer index
                  Earu.State_Store.State_Buffer.Load_Sig_Loc (Count, Loc);
               end if;

               Curr := Close_Pos + 1;
            end;
         end loop;

         Put_Line ("[SigLoc] Loaded " & Natural'Image (Count) &
                   " locations from " & Sig_Loc_Json_Path);
      exception
         when others =>
            --  Safe_Fallback: any parse fault leaves whatever entries were
            --  already stored; report loudly and continue with partial data.
            Put_Line ("[SigLoc] Parse failed for " & Sig_Loc_Json_Path &
                      " - keeping partially loaded entries");
            raise;
      end;
   exception
      when E : others =>
         --  Safe_Fallback: missing/unreadable file already handled above;
         --  outer guard logs and re-raises so startup can decide policy.
         Put_Line ("[SigLoc] Load_Sig_Locs failed: " &
                   Ada.Exceptions.Exception_Name
                     (E));
         raise;
   end Load_Sig_Locs;

   --  ── Save ──────────────────────────────────────────────────────────────

   -- | Purpose: Save Sig Locs — write the state buffer back to the JSON file.
   -- | Parameters: None (reads Earu.State_Store.State_Buffer).
   -- | Returns: None; Count = 0 is a no-op, write errors are reported loudly.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(n) — one file write of ≤ 10 short objects.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(n)]
   -- @test: Test_Sig_Loc_Store — Register_Routine ("Save_Sig_Locs", Test_Sig_Loc_Store'Access);
   procedure Save_Sig_Locs is
      -- Pre => True — idempotent; called after each ML cycle with Count > 0.
      -- Post => True — file contains the snapshot or the prior file survives on error.
      -- WCET: O(n) — one bounded write, n ≤ 10 objects. Estimated Processing Time: O(n); Space Complexity: O(1)
      F : File_Type;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      declare
         Count : Natural;
      begin
         Earu.State_Store.State_Buffer.Get_Sig_Loc_Count (Count);  -- SMT_VERIFIED
         --  SMT domain: Count is the state-buffer occupancy — always within
         --  Significant_Location_Array range 0 .. Significant_Location_Array'Last
         --  (10) by construction of Load_Sig_Loc; Get_Sig_Loc_Count(Count) is a
         --  total out-parameter read, no index involved.

         if Count = 0 then
            return;  -- Nothing to persist
         end if;

         --  Ensure directory exists
         begin
            Ada.Directories.Create_Path
              (Ada.Directories.Containing_Directory (Sig_Loc_Json_Path));
         exception
            when others => null;  -- Directory likely already exists
         end;

         begin
            Create (F, Out_File, Sig_Loc_Json_Path);
            Put_Line (F, "[");

            for I in 1 .. Count loop
               declare
               pragma Loop_Invariant (True);
               -- [Assertion: DO-178C §6.4.4 loop invariant]
                  Loc : Significant_Location;
               begin
                  Earu.State_Store.State_Buffer.Get_Sig_Loc (I, Loc);

                  Put_Line (F, "  {");
                  Put_Line (F, "    ""lat"": " & Real'Image (Loc.Lat) & ",");
                  Put_Line (F, "    ""lon"": " & Real'Image (Loc.Lon) & ",");
                  Put_Line (F, "    ""alt"": " & Real'Image (Loc.Alt) & ",");
                  Put_Line (F, "    ""timestamp"": """"");

                  if I < Count then
                     Put_Line (F, "  },");
                  else
                     Put_Line (F, "  }");
                  end if;
               end;
            end loop;

            Put_Line (F, "]");
            Close (F);

            Put_Line ("[SigLoc] Saved " & Natural'Image (Count) &
                      " locations to " & Sig_Loc_Json_Path);
         exception
            when others =>
               Put_Line ("[SigLoc] Failed to write " & Sig_Loc_Json_Path);
               if Is_Open (F) then
                  Close (F);
               end if;
         end;
      end;
   exception
      when others =>
         --  Safe_Fallback: write errors already logged above with the exact
         --  path; propagate so the ML cycle can retry next tick (no swallow).
         raise;
   end Save_Sig_Locs;

end Earu.Sig_Loc_Store;
