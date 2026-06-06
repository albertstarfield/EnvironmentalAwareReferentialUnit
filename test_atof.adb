with Ada.Text_IO;
with Interfaces.C;

procedure Test_Atof is
   function C_Atof (Str : Interfaces.C.char_array) return Interfaces.C.double;
   pragma Import (C, C_Atof, "atof");
   
   S : constant String := "1327522226";
   C_Str : constant Interfaces.C.char_array := Interfaces.C.To_C (S);
   Val : constant Interfaces.C.double := C_Atof (C_Str);
begin
   Ada.Text_IO.Put_Line ("Atof(" & S & ") = " & Val'Img);
end Test_Atof;
