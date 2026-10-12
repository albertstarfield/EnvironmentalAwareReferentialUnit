--  ==========================================================================
--  test_shm_map.adb
--  Regression proof that Create_And_Map_Generic actually MAPS a Darwin
--  POSIX shared-memory object, on both of the branches it can take.
--
--  WHAT THIS TEST PREVENTS (incident 2026-10-12)
--  ----------------------------------------------
--  A previous revision of earu-shm.adb sized segments with lseek(2).
--  On Darwin lseek CANNOT seek a shared-memory descriptor: it fails
--  every time with ESPIPE (errno 29), while fstat(2) on the same
--  descriptor succeeds. That revision read "size query failed" as
--  "segment unusable" and returned System.Null_Address for every
--  segment. The live daemon then published ZEROS for accel, gyro,
--  orientation, lid and als while still logging normally.
--
--  The eight-suite gate stayed GREEN while that defect existed, because
--  no other test ever called Create_And_Map_Generic. That coverage hole
--  is what let it reach a running daemon, and it is exactly what this
--  file closes.
--
--  WHAT IS PROVEN HERE
--  -------------------
--    AXIOM T1  A freshly shm_open'd object reports st_size = 0, below
--              Size, so the "genuinely short -> ftruncate" branch runs.
--              It must yield a non-null mapping.
--    AXIOM T2  An object that already exists reports a quantum-rounded
--              length >= Size (16384 for a 328-byte record), so the
--              "already long enough -> skip ftruncate" branch runs. It
--              must ALSO yield a non-null mapping. This is the branch a
--              failed query previously turned into a refusal, and it is
--              the steady state on every daemon restart.
--    AXIOM T3  The returned access value must dereference. Reading back
--              through it distinguishes a real mapping from a
--              Null_Address and from a page that faults on touch.
--    AXIOM T4  Records of three different sizes (328, 16 and 12 bytes)
--              all map, so the sizing logic is not tuned to one length.
--
--  RULE R1 (enforced here, stated in earu-shm.adb): a size query that
--  FAILS must never refuse a mapping. Refusal is only correct when a
--  TRUSTED length proves the segment shorter than requested.
--
--  SCOPE: segments owned by the live root daemon are not opened -- an
--  unprivileged run gets EACCES on them. Each case creates a privately
--  named object and unlinks it before and after, so the test is
--  self-contained, repeatable, and safe to run beside a live daemon.
--
--  Citation: POSIX shm_open(3), shm_unlink(3), fstat(2), ftruncate(2).
--  Based on: probes /tmp/ft3.c and /tmp/ft4.c on this host -- lseek ->
--            ESPIPE 29, fstat -> 0, sizeof(struct stat)=144 with
--            st_size at offset 96, quantum rounding to a multiple of
--            16384 (328->16384, 20000->32768, 273408->278528).
--  ==========================================================================

with Ada.Command_Line;
with Ada.Text_IO; use Ada.Text_IO;
with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings; use Interfaces.C.Strings;
with System; use type System.Address;
with System.Address_To_Access_Conversions;

with Earu.Shm;
--  Equality on the returned access values needs their operators visible
--  (RM 4.5.2); without these the compiler reports "operator for type
--  ... is not directly visible".
use type Earu.Shm.Memory_Health_SHM_Ptr;
use type Earu.Shm.DR_SHM_Ptr;
use type Earu.Shm.Lid_SHM_Ptr;

procedure Test_Shm_Map is

   --  ------------------------------------------------------------------
   --  Purpose: Shm_Unlink -- remove a POSIX shm object so the next
   --          Create_* call observes a genuinely fresh (size 0) object.
   --  Parameters: Name -- NUL-terminated object name.
   --  Returns: 0 on success, -1 on failure; ENOENT is expected and
   --          harmless when the object does not exist yet.
   --  Citation: POSIX shm_unlink(3).
   --  ------------------------------------------------------------------
   function Shm_Unlink (Name : chars_ptr) return int;
   pragma Import (C, Shm_Unlink, "shm_unlink");

   package U32_Conv is new System.Address_To_Access_Conversions (Unsigned_32);

   subtype Check_Count is Natural range 0 .. 1_000;
   Pass : Check_Count := 0;
   Fail : Check_Count := 0;

   N_MH : constant String := "/earu_tsm_mh";
   N_DR : constant String := "/earu_tsm_dr";
   N_LI : constant String := "/earu_tsm_lid";

   --  ------------------------------------------------------------------
   --  Purpose: Check -- record one assertion verdict.
   --  Parameters: Label -- what is being proven; Ok -- verdict.
   --  Returns: none; increments Pass or Fail and prints the result.
   --  ------------------------------------------------------------------
   procedure Check (Label : String; Ok : Boolean) is
   begin
      if Ok then
         Pass := Pass + 1;
         Put_Line ("  [ok]   " & Label);
      else
         Fail := Fail + 1;
         Put_Line ("  [FAIL] " & Label);
      end if;
   end Check;

   --  ------------------------------------------------------------------
   --  Purpose: Fresh -- forget any object of this name so the following
   --          Create_* call takes the fresh-create branch (AXIOM T1).
   --  Parameters: N -- shm object name.
   --  Returns: none.
   --  ------------------------------------------------------------------
   procedure Fresh (N : String) is
      R : int;
   begin
      R := Shm_Unlink (New_String (N));
      pragma Unreferenced (R);
   end Fresh;

   --  ------------------------------------------------------------------
   --  Purpose: Prove_Dereference -- read 4 bytes through a mapped
   --          address to prove it is present, mapped memory.
   --  Parameters: Label -- case name; Addr -- address returned by a
   --          successful Create_* call.
   --  Returns: none; records one assertion.
   --  AXIOM T3: a Null_Address, or a page mapped shorter than the
   --  record, faults here rather than returning -- so reaching the
   --  verdict proves the mapping is real.
   --  Citation: ISO/IEC 8652:2012(A) 13.5.3 selected components.
   --  ------------------------------------------------------------------
   procedure Prove_Dereference (Label : String; Addr : System.Address) is
      P : U32_Conv.Object_Pointer;
      V : Unsigned_32;
   begin
      if Addr = System.Null_Address then
         Check (Label, False);
         return;
      end if;
      P := U32_Conv.To_Pointer (Addr);
      V := P.all;
      pragma Unreferenced (V);
      Check (Label, True);
   exception
      when others =>
         Check (Label, False);
   end Prove_Dereference;

begin
   Put_Line ("test_shm_map: Create_And_Map_Generic branch coverage");
   Put_Line ("  incident 2026-10-12: lseek ESPIPE -> Null_Address -> zeros");

   --  Force every case onto the fresh-create branch first.
   Fresh (N_MH);
   Fresh (N_DR);
   Fresh (N_LI);

   declare
      P_MH1 : Earu.Shm.Memory_Health_SHM_Ptr;
      P_MH2 : Earu.Shm.Memory_Health_SHM_Ptr;
      P_DR1 : Earu.Shm.DR_SHM_Ptr;
      P_DR2 : Earu.Shm.DR_SHM_Ptr;
      P_LI1 : Earu.Shm.Lid_SHM_Ptr;
      P_LI2 : Earu.Shm.Lid_SHM_Ptr;
   begin
      --  ---- 328-byte record ------------------------------------------
      P_MH1 := Earu.Shm.Create_Memory_Health_SHM (N_MH);
      Check ("Memory_Health 328 B: fresh create (T1) maps", P_MH1 /= null);
      P_MH2 := Earu.Shm.Create_Memory_Health_SHM (N_MH);
      Check ("Memory_Health 328 B: reopen steady-state (T2) maps",
             P_MH2 /= null);

      --  ---- 16-byte record -------------------------------------------
      P_DR1 := Earu.Shm.Create_DR_SHM (N_DR);
      Check ("DR_SHM 16 B: fresh create (T1) maps", P_DR1 /= null);
      P_DR2 := Earu.Shm.Create_DR_SHM (N_DR);
      Check ("DR_SHM 16 B: reopen steady-state (T2) maps", P_DR2 /= null);

      --  ---- 12-byte record -------------------------------------------
      P_LI1 := Earu.Shm.Create_Lid_SHM (N_LI);
      Check ("Lid_SHM 12 B: fresh create (T1) maps", P_LI1 /= null);
      P_LI2 := Earu.Shm.Create_Lid_SHM (N_LI);
      Check ("Lid_SHM 12 B: reopen steady-state (T2) maps", P_LI2 /= null);

      --  AXIOM T3: the steady-state mapping must be live memory. This is
      --  the branch the incident turned into a refusal.
      if P_MH2 /= null then
         Prove_Dereference ("Memory_Health: steady-state mapping reads back",
                            P_MH2.all'Address);
      else
         Prove_Dereference ("Memory_Health: steady-state mapping reads back",
                            System.Null_Address);
      end if;

      if P_LI2 /= null then
         Prove_Dereference ("Lid_SHM: steady-state mapping reads back",
                            P_LI2.all'Address);
      else
         Prove_Dereference ("Lid_SHM: steady-state mapping reads back",
                            System.Null_Address);
      end if;
   end;

   --  Leave no objects behind for the next run or the live daemon.
   Fresh (N_MH);
   Fresh (N_DR);
   Fresh (N_LI);

   Put_Line ("");
   Put_Line ("=== Results:" & Check_Count'Image (Pass) & " passed,"
             & Check_Count'Image (Fail) & " failed ===");

   if Fail > 0 then
      Put_Line ("test_shm_map: FAILED - see earu-shm.adb [INCIDENT 2026-10-12]");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   else
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   end if;
end Test_Shm_Map;
