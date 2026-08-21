--  Significant Location persistence implementation.
--
--  Minimal JSON parser for the sig loc file.  No GNATCOLL.JSON dependency —
--  uses the same Extract_JSON_Float / string-index pattern as system_bridge.

with Ada.Text_IO;
with Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Ada.Directories;
with Earu.State_Store;
with Earu.Types; use Earu.Types;

package body Earu.Sig_Loc_Store is

   use Ada.Text_IO;
   use Ada.Strings.Unbounded;
   use Ada.Strings.Fixed;

   --  ── Minimal JSON value extractors (same pattern as system_bridge) ─────

   function Extract_Float
     (JSON    : String;
      Key     : String;
      Default : Real := 0.0)
      return Real
   is
      Start_Idx : Natural;
      Colon_Idx : Natural;
      End_Idx   : Natural;
   begin
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
         End_Idx := End_Idx + 1;
      end loop;

      if Colon_Idx + 1 <= End_Idx - 1 then
         return Real'Value (JSON (Colon_Idx + 1 .. End_Idx - 1));
      end if;

      return Default;
   exception
      when others =>
         return Default;
   end Extract_Float;

   function Extract_String
     (JSON    : String;
      Key     : String;
      Default : String := "")
      return String
   is
      Start_Idx : Natural;
      Colon_Idx : Natural;
      Open_Idx  : Natural;
      Close_Idx : Natural;
   begin
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
         return Default;
   end Extract_String;

   --  ── Load ──────────────────────────────────────────────────────────────

   procedure Load_Sig_Locs is
      F       : File_Type;
      Content : Unbounded_String;
   begin
      if not Ada.Directories.Exists (SIG_LOC_JSON_PATH) then
         Put_Line ("[SigLoc] No persistent file found - starting empty");
         return;
      end if;

      begin
         Open (F, In_File, SIG_LOC_JSON_PATH);
         while not End_Of_File (F) loop
            Append (Content, Get_Line (F));
         end loop;
         Close (F);
      exception
         when others =>
            Put_Line ("[SigLoc] Failed to read " & SIG_LOC_JSON_PATH);
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
               Earu.State_Store.State_Buffer.Load_Sig_Loc (Count, Loc);

               Curr := Close_Pos + 1;
            end;
         end loop;

         Put_Line ("[SigLoc] Loaded " & Natural'Image (Count) &
                   " locations from " & SIG_LOC_JSON_PATH);
      end;
   end Load_Sig_Locs;

   --  ── Save ──────────────────────────────────────────────────────────────

   procedure Save_Sig_Locs is
      F : File_Type;
   begin
      declare
         Count : Natural;
      begin
         Earu.State_Store.State_Buffer.Get_Sig_Loc_Count (Count);

         if Count = 0 then
            return;  -- Nothing to persist
         end if;

         --  Ensure directory exists
         begin
            Ada.Directories.Create_Path
              (Ada.Directories.Containing_Directory (SIG_LOC_JSON_PATH));
         exception
            when others => null;  -- Directory likely already exists
         end;

         begin
            Create (F, Out_File, SIG_LOC_JSON_PATH);
            Put_Line (F, "[");

            for I in 1 .. Count loop
               declare
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
                      " locations to " & SIG_LOC_JSON_PATH);
         exception
            when others =>
               Put_Line ("[SigLoc] Failed to write " & SIG_LOC_JSON_PATH);
               if Is_Open (F) then
                  Close (F);
               end if;
         end;
      end;
   end Save_Sig_Locs;

end Earu.Sig_Loc_Store;
