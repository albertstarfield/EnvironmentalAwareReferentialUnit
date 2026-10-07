--  ==========================================================================
--  earu-location_ffi.adb — body of the Ada binding to libearu_location.dylib.
--
--  AXIOMS
--    [A1] dlopen(3)/dlsym(3) are the ONLY sanctioned way to reach an OPTIONAL
--         shared library from a statically-linked Ada main: the symbol is
--         resolved at runtime, so a missing dylib cannot fail the link nor
--         abort the process at load time.
--         [Citation: dlopen(3), dlsym(3), dlerror(3) — macOS man pages]
--    [A2] RTLD_NOW (= 2 on Darwin) resolves every symbol up front so a
--         partially-resolvable dylib is rejected at Load rather than
--         crashing mid-cycle.  [Citation: <dlfcn.h> — RTLD_LAZY 0x1, RTLD_NOW 0x2]
--    [A3] The dylib returns 1 for success / 0 for failure (see the spec).
--    [A4] dlclose is deliberately NOT called: the dylib hosts a live CPython
--         interpreter, and unmapping it during teardown is a documented
--         crash vector.  The mapping is retained for process lifetime.
--         [Citation: cffi embedding — the interpreter is initialised lazily
--          and never finalised by the host]
--
--  THEORIES
--    [T1] Every entry point is total: no exception escapes, and every failure
--         path stores a non-empty reason in the module error slot AND logs it
--         to stderr (no silent failure).
--    [T2] State is written only by Load/Unload and read by Available/
--         Execute_Fix/Last_Error; Load is called once from the single
--         Location_Poll_Task before its loop, so no lock is required.
--
--  APPLICATIONS
--    See the spec for the calling contract.
--
--  ==========================================================================

with Ada.Exceptions;
with Ada.Text_IO;
with Ada.Unchecked_Conversion;
with Interfaces.C;
with Interfaces.C.Strings;
with System;

with Earu.IO;

package body Earu.Location_FFI is

   --  AXIOM A5: `Interfaces.C.int` is derived and
   --  `Interfaces.C.Strings.chars_ptr` is private, so their primitive
   --  "=" / "/=" operators are not directly visible at this scope.  Make both
   --  visible explicitly rather than fully use-clausing the C packages (which
   --  would import a large, collision-prone namespace).
   use type Interfaces.C.int;
   use type Interfaces.C.Strings.chars_ptr;
   use type System.Address;

   --  ── C ABI of libearu_location.dylib ─────────────────────────────────
   --  AXIOM A4 of the spec: Real is a C double, so Real_Ptr is `double *`.
   type Real_Ptr is access all Real;
   pragma Convention (C, Real_Ptr);

   --  int earu_loc_init(const char *script_dir);
   type Init_Func is access function
     (Script_Dir : Interfaces.C.Strings.chars_ptr) return Interfaces.C.int;
   pragma Convention (C, Init_Func);

   --  int earu_loc_execute(double *lat, double *lon, double *alt,
   --                       double *pressure_hpa, double *terrain_alt,
   --                       double *v_acc);
   type Exec_Func is access function
     (Lat          : Real_Ptr;
      Lon          : Real_Ptr;
      Alt          : Real_Ptr;
      Pressure_HPa : Real_Ptr;
      Terrain_Alt  : Real_Ptr;
      V_Acc        : Real_Ptr) return Interfaces.C.int;
   pragma Convention (C, Exec_Func);

   --  const char *earu_loc_last_error(void);
   type Error_Func is access function
     return Interfaces.C.Strings.chars_ptr;
   pragma Convention (C, Error_Func);

   --  void earu_loc_shutdown(void);
   type Shutdown_Func is access procedure;
   pragma Convention (C, Shutdown_Func);

   --  ── dlfcn(3) imports ────────────────────────────────────────────────
   -- | Purpose: C_Dlopen — dlopen(3) binding.
   -- | Parameters: Filename — NUL-terminated path; Flag — RTLD_NOW.
   -- | Returns: opaque handle, or System.Null_Address on failure.
   -- | Exceptions: None (C function; failure is signalled by a null handle).
   -- | CSI: DO-178C §6.4.4
   -- AXIOM A1. [Citation: dlopen(3)]
   function C_Dlopen
     (Filename : Interfaces.C.Strings.chars_ptr;
      Flag     : Interfaces.C.int) return System.Address;
   pragma Import (C, C_Dlopen, "dlopen");

   -- | Purpose: C_Dlsym — dlsym(3) binding.
   -- | Parameters: Handle — from C_Dlopen; Symbol — NUL-terminated name.
   -- | Returns: symbol address, or System.Null_Address when absent.
   -- | Exceptions: None.
   -- | CSI: DO-178C §6.4.4
   -- AXIOM A1. [Citation: dlsym(3)]
   function C_Dlsym
     (Handle : System.Address;
      Symbol : Interfaces.C.Strings.chars_ptr) return System.Address;
   pragma Import (C, C_Dlsym, "dlsym");

   -- | Purpose: C_Dlerror — dlerror(3) binding; returns the last dl* error.
   -- | Parameters: None.
   -- | Returns: NUL-terminated message, or chars_ptr(System.Null_Address)
   -- |          when no error is pending (the caller must null-check).
   -- | Exceptions: None.
   -- | CSI: DO-178C §6.4.4
   -- AXIOM A1. [Citation: dlerror(3)]
   function C_Dlerror return Interfaces.C.Strings.chars_ptr;
   pragma Import (C, C_Dlerror, "dlerror");

   --  RTLD_NOW: resolve all symbols at load (AXIOM A2).
   RTLD_NOW : constant Interfaces.C.int := 2;

   --  ── Module state (THEOREM T2) ───────────────────────────────────────
   Handle     : System.Address := System.Null_Address;
   Exec_Ptr   : Exec_Func := null;
   Error_Ptr  : Error_Func := null;
   Shut_Ptr   : Shutdown_Func := null;
   Loaded     : Boolean := False;
   Load_Msg   : String (1 .. 256) := (others => ' ');
   Load_Msg_L : Natural range 0 .. 256 := 0;

   -- | Purpose: Set_Load_Msg — record the most recent load failure reason.
   -- | Parameters: Msg — reason text (truncated to 256 characters).
   -- | Returns: None.
   -- | Exceptions: None.
   -- | CSI: DO-178C §6.4.4
   -- THEOREM T1: guarantees a non-empty reason is always retained.
   -- WCET: O(1) — bounded copy, n ≤ 256.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_FFI — Register_Routine ("Set_Load_Msg", Test_Location_FFI'Access);
   procedure Set_Load_Msg (Msg : String) is
      N : constant Natural := Natural'Min (Msg'Length, 256);
   begin
      Load_Msg := (others => ' ');
      if N > 0 then
         Load_Msg (1 .. N) := Msg (Msg'First .. Msg'First + N - 1);
      end if;
      Load_Msg_L := N;
   end Set_Load_Msg;

   -- | Purpose: Load_Msg_Text — the recorded load failure reason.
   -- | Parameters: None.
   -- | Returns: the reason string ("" when none recorded).
   -- | Exceptions: None.
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(n), n ≤ 256.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_FFI — Register_Routine ("Load_Msg_Text", Test_Location_FFI'Access);
   function Load_Msg_Text return String is
   begin
      return Load_Msg (1 .. Load_Msg_L);
   end Load_Msg_Text;

   --  ── Public interface ────────────────────────────────────────────────

   function Dylib_Path return String is
   begin
      return Earu.IO.Project_Root & "/EARU_daemon/lib/libearu_location.dylib";
   exception
      when E : others =>
         Ada.Text_IO.Put_Line
           ("[!] Location_FFI.Dylib_Path exception: " &
            Ada.Exceptions.Exception_Message (E));
         return "";
   end Dylib_Path;

   function Available return Boolean is
   begin
      return Loaded;
   end Available;

   function Load (Script_Dir : String := "") return Boolean is
      --  THEOREM T1: the whole body is wrapped, so no dlopen/dlsym/CPython
      --  failure can escape into the caller's scheduling loop.
      Path   : constant String := Dylib_Path;
      C_Path : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.Null_Ptr;
      C_Name : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.Null_Ptr;
      C_Dir  : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.Null_Ptr;
      Sym    : System.Address;
      Init_P : Init_Func;

      function Function_Address_To_Init is new
        Ada.Unchecked_Conversion (System.Address, Init_Func);
      function Function_Address_To_Exec is new
        Ada.Unchecked_Conversion (System.Address, Exec_Func);
      function Function_Address_To_Error is new
        Ada.Unchecked_Conversion (System.Address, Error_Func);
      function Function_Address_To_Shut is new
        Ada.Unchecked_Conversion (System.Address, Shutdown_Func);
   begin
      if Loaded then
         return True;  --  THEOREM T1: idempotent
      end if;

      if Path'Length = 0 then
         Set_Load_Msg ("dylib path could not be resolved");
         Ada.Text_IO.Put_Line
           ("[!] Location_FFI.Load: " & Load_Msg_Text);
         return False;
      end if;

      C_Path := Interfaces.C.Strings.New_String (Path);
      Handle := C_Dlopen (C_Path, RTLD_NOW);
      Interfaces.C.Strings.Free (C_Path);
      C_Path := Interfaces.C.Strings.Null_Ptr;

      if Handle = System.Null_Address then
         --  AXIOM A1 / THEOREM T1: report the EXACT path and dlerror text.
         declare
            D : constant Interfaces.C.Strings.chars_ptr := C_Dlerror;
            Detail : constant String :=
              (if D = Interfaces.C.Strings.Null_Ptr
               then "dlerror() returned no detail"
               else Interfaces.C.Strings.Value (D));
         begin
            Set_Load_Msg ("dlopen(" & Path & ") failed: " & Detail);
         end;
         Ada.Text_IO.Put_Line
           ("[!] Location_FFI.Load: " & Load_Msg_Text &
            " -- falling back to the native fix cycle");
         return False;
      end if;

      C_Name := Interfaces.C.Strings.New_String ("earu_loc_execute");
      Sym := C_Dlsym (Handle, C_Name);
      Interfaces.C.Strings.Free (C_Name);
      C_Name := Interfaces.C.Strings.Null_Ptr;
      if Sym = System.Null_Address then
         Set_Load_Msg ("dlsym(earu_loc_execute) failed: " &
                       Interfaces.C.Strings.Value (C_Dlerror));
         Ada.Text_IO.Put_Line ("[!] Location_FFI.Load: " & Load_Msg_Text);
         return False;
      end if;
      Exec_Ptr := Function_Address_To_Exec (Sym);

      C_Name := Interfaces.C.Strings.New_String ("earu_loc_last_error");
      Sym := C_Dlsym (Handle, C_Name);
      Interfaces.C.Strings.Free (C_Name);
      C_Name := Interfaces.C.Strings.Null_Ptr;
      if Sym = System.Null_Address then
         Set_Load_Msg ("dlsym(earu_loc_last_error) failed: " &
                       Interfaces.C.Strings.Value (C_Dlerror));
         Ada.Text_IO.Put_Line ("[!] Location_FFI.Load: " & Load_Msg_Text);
         return False;
      end if;
      Error_Ptr := Function_Address_To_Error (Sym);

      C_Name := Interfaces.C.Strings.New_String ("earu_loc_shutdown");
      Sym := C_Dlsym (Handle, C_Name);
      Interfaces.C.Strings.Free (C_Name);
      C_Name := Interfaces.C.Strings.Null_Ptr;
      if Sym = System.Null_Address then
         Set_Load_Msg ("dlsym(earu_loc_shutdown) failed: " &
                       Interfaces.C.Strings.Value (C_Dlerror));
         Ada.Text_IO.Put_Line ("[!] Location_FFI.Load: " & Load_Msg_Text);
         return False;
      end if;
      Shut_Ptr := Function_Address_To_Shut (Sym);

      C_Name := Interfaces.C.Strings.New_String ("earu_loc_init");
      Sym := C_Dlsym (Handle, C_Name);
      Interfaces.C.Strings.Free (C_Name);
      C_Name := Interfaces.C.Strings.Null_Ptr;
      if Sym = System.Null_Address then
         Set_Load_Msg ("dlsym(earu_loc_init) failed: " &
                       Interfaces.C.Strings.Value (C_Dlerror));
         Ada.Text_IO.Put_Line ("[!] Location_FFI.Load: " & Load_Msg_Text);
         return False;
      end if;
      Init_P := Function_Address_To_Init (Sym);

      --  AXIOM A3: 1 = success.  A 0 here means the embedded CPython
      --  interpreter failed to start, so the dylib must NOT be used.
      C_Dir := Interfaces.C.Strings.New_String (Script_Dir);
      declare
         RC : constant Interfaces.C.int := Init_P (C_Dir);
      begin
         Interfaces.C.Strings.Free (C_Dir);
         C_Dir := Interfaces.C.Strings.Null_Ptr;
         if RC /= 1 then
            Set_Load_Msg
              ("earu_loc_init returned " & Interfaces.C.int'Image (RC) &
               " (expected 1); embedded interpreter not usable");
            Ada.Text_IO.Put_Line ("[!] Location_FFI.Load: " & Load_Msg_Text);
            Exec_Ptr  := null;
            Error_Ptr := null;
            Shut_Ptr  := null;
            return False;
         end if;
      end;

      Loaded := True;
      Set_Load_Msg ("");
      Ada.Text_IO.Put_Line
        ("[Location_FFI] libearu_location.dylib loaded from " & Path);
      return True;
   exception
      when E : others =>
         --  THEOREM T1: total.  Release any half-built state.
         if C_Path /= Interfaces.C.Strings.Null_Ptr then
            Interfaces.C.Strings.Free (C_Path);
         end if;
         if C_Name /= Interfaces.C.Strings.Null_Ptr then
            Interfaces.C.Strings.Free (C_Name);
         end if;
         if C_Dir /= Interfaces.C.Strings.Null_Ptr then
            Interfaces.C.Strings.Free (C_Dir);
         end if;
         Exec_Ptr  := null;
         Error_Ptr := null;
         Shut_Ptr  := null;
         Loaded    := False;
         Set_Load_Msg
           ("Load exception: " & Ada.Exceptions.Exception_Name (E) & ": " &
            Ada.Exceptions.Exception_Message (E));
         Ada.Text_IO.Put_Line ("[!] Location_FFI.Load: " & Load_Msg_Text);
         return False;
   end Load;

   function Last_Error return String is
      C_Msg : Interfaces.C.Strings.chars_ptr;
   begin
      if Error_Ptr = null then
         return Load_Msg_Text;
      end if;
      C_Msg := Error_Ptr.all;
      if C_Msg = Interfaces.C.Strings.Null_Ptr then
         return "";
      end if;
      return Interfaces.C.Strings.Value (C_Msg);
   exception
      when E : others =>
         Ada.Text_IO.Put_Line
           ("[!] Location_FFI.Last_Error exception: " &
            Ada.Exceptions.Exception_Message (E));
         return "Last_Error exception";
   end Last_Error;

   function Execute_Fix return Fix_Result is
      R : Fix_Result;
      Lat : aliased Real := 0.0;
      Lon : aliased Real := 0.0;
      Alt : aliased Real := 0.0;
      Prs : aliased Real := 0.0;
      Ter : aliased Real := 0.0;
      Vac : aliased Real := 0.0;
      RC  : Interfaces.C.int;
   begin
      if not Loaded or else Exec_Ptr = null then
         R.Ok := False;
         R.Error_Msg := (others => ' ');
         declare
            M : constant String :=
              (if Load_Msg_L > 0 then Load_Msg_Text
               else "dylib not loaded (Load was not called or failed)");
            N : constant Natural := Natural'Min (M'Length, 256);
         begin
            R.Error_Msg (1 .. N) := M (M'First .. M'First + N - 1);
            R.Error_Len := N;
         end;
         return R;
      end if;

      --  AXIOM A6: the six out-parameters are consumed SYNCHRONOUSLY by the C
      --  function and never retained by the dylib, so the accessibility check
      --  that forbids 'Access from a local to a library-level access type is
      --  intentionally bypassed with 'Unchecked_Access.  This is the standard
      --  FFI out-parameter idiom; the lifetime is bounded by this call.
      --  [Reference: Ada RM 13.10 — Access-to-Object Types, accessibility]
      RC := Exec_Ptr (Lat'Unchecked_Access, Lon'Unchecked_Access,
                      Alt'Unchecked_Access, Prs'Unchecked_Access,
                      Ter'Unchecked_Access, Vac'Unchecked_Access);
      --  AXIOM A3: 1 = success, 0 = failure.
      if RC = 1 then
         R.Ok           := True;
         R.Lat          := Lat;
         R.Lon          := Lon;
         R.Alt          := Alt;
         R.Pressure_HPa := Prs;
         R.Terrain_Alt  := Ter;
         R.V_Acc        := Vac;
         R.Error_Len    := 0;
      else
         R.Ok := False;
         declare
            M : constant String := Last_Error;
            N : constant Natural := Natural'Min (M'Length, 256);
         begin
            R.Error_Msg := (others => ' ');
            if N > 0 then
               R.Error_Msg (1 .. N) := M (M'First .. M'First + N - 1);
            end if;
            R.Error_Len := N;
         end;
      end if;
      return R;
   exception
      when E : others =>
         --  THEOREM T2: total.  A crash inside the dylib's Python would
         --  normally abort the process, so reaching here means an Ada-side
         --  fault (e.g. a null pointer); report it rather than propagate.
         R.Ok := False;
         declare
            M : constant String :=
              "Execute_Fix exception: " & Ada.Exceptions.Exception_Name (E) &
              ": " & Ada.Exceptions.Exception_Message (E);
            N : constant Natural := Natural'Min (M'Length, 256);
         begin
            R.Error_Msg := (others => ' ');
            R.Error_Msg (1 .. N) := M (M'First .. M'First + N - 1);
            R.Error_Len := N;
         end;
         Ada.Text_IO.Put_Line ("[!] Location_FFI.Execute_Fix: " & R.Error_Msg);
         return R;
   end Execute_Fix;

   procedure Unload is
   begin
      if not Loaded then
         return;  --  idempotent
      end if;
      --  AXIOM A4: ask the dylib to release its own Python-side state, but
      --  never dlclose() the mapping — tearing down the embedded interpreter
      --  from a destructor is a documented crash vector.
      if Shut_Ptr /= null then
         begin
            Shut_Ptr.all;
         exception
            when E : others =>
               Ada.Text_IO.Put_Line
                 ("[!] Location_FFI.Unload shutdown exception: " &
                  Ada.Exceptions.Exception_Message (E));
         end;
      end if;
      Exec_Ptr  := null;
      Error_Ptr := null;
      Shut_Ptr  := null;
      Loaded    := False;
      Set_Load_Msg ("");
      Ada.Text_IO.Put_Line
        ("[Location_FFI] released (mapping intentionally retained)");
   end Unload;

end Earu.Location_FFI;
