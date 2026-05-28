with AWS.Server;
with AWS.Response;
with AWS.Status;
with AWS.Config;
with AWS.Config.Set;
with AWS.Net;
with AWS.Messages;
with Earu.State_Store;
with Ada.Text_IO;
with Interfaces; use Interfaces;
with Ada.Streams; use Ada.Streams;
with Ada.Exceptions;
with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Unchecked_Conversion;
with GNAT.Sockets;

package body Earu.Ntrip is

   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);

   function To_U64 is new Ada.Unchecked_Conversion (Integer_64, Unsigned_64);

   procedure LLA_To_ECEF (Lat, Lon, Alt : Real; X, Y, Z : out Real) is
      A  : constant Real := 6378137.0;
      F  : constant Real := 1.0 / 298.257223563;
      E2 : constant Real := 2.0 * F - F**2;
      
      Pi : constant Real := 3.14159265358979323846;
      Lat_Rad : constant Real := Lat * Pi / 180.0;
      Lon_Rad : constant Real := Lon * Pi / 180.0;
      
      Sin_Lat : constant Real := Real_Funcs.Sin (Lat_Rad);
      Cos_Lat : constant Real := Real_Funcs.Cos (Lat_Rad);
      Sin_Lon : constant Real := Real_Funcs.Sin (Lon_Rad);
      Cos_Lon : constant Real := Real_Funcs.Cos (Lon_Rad);
      
      N : constant Real := A / Real_Funcs.Sqrt (1.0 - E2 * Sin_Lat**2);
   begin
      X := (N + Alt) * Cos_Lat * Cos_Lon;
      Y := (N + Alt) * Cos_Lat * Sin_Lon;
      Z := (N * (1.0 - E2) + Alt) * Sin_Lat;
   end LLA_To_ECEF;

   type Bit_Packer is record
      Buffer    : Unsigned_64 := 0;
      Bit_Count : Natural := 0;
      Bytes     : Stream_Element_Array (1 .. 128) := (others => 0);
      Byte_Idx  : Stream_Element_Offset := 0;
   end record;

   procedure Pack (Packer : in out Bit_Packer; Val : Unsigned_64; Bits : Natural) is
      Mask : constant Unsigned_64 := Shift_Left (1, Bits) - 1;
      V    : constant Unsigned_64 := Val and Mask;
   begin
      Packer.Buffer := Shift_Left (Packer.Buffer, Bits) or V;
      Packer.Bit_Count := Packer.Bit_Count + Bits;
      while Packer.Bit_Count >= 8 loop
         Packer.Bit_Count := Packer.Bit_Count - 8;
         Packer.Byte_Idx := Packer.Byte_Idx + 1;
         Packer.Bytes (Packer.Byte_Idx) := Stream_Element (Shift_Right (Packer.Buffer, Packer.Bit_Count) and 16#FF#);
         Packer.Buffer := Packer.Buffer and (Shift_Left (1, Packer.Bit_Count) - 1);
      end loop;
   end Pack;

   procedure Finalize (Packer : in out Bit_Packer) is
   begin
      if Packer.Bit_Count > 0 then
         Pack (Packer, 0, 8 - Packer.Bit_Count);
      end if;
   end Finalize;

   function CRC24Q (Data : Stream_Element_Array) return Unsigned_32 is
      CRC : Unsigned_32 := 0;
   begin
      for I in Data'Range loop
         CRC := CRC xor Shift_Left (Unsigned_32 (Data (I)), 16);
         for J in 1 .. 8 loop
             CRC := Shift_Left (CRC, 1);
             if (CRC and 16#1000000#) /= 0 then
                CRC := CRC xor 16#1864CFB#;
             end if;
          end loop;
       end loop;
       return CRC and 16#FFFFFF#;
    end CRC24Q;

    function Make_RTCM_1005 (Lat, Lon, Alt : Real) return Stream_Element_Array is
       X, Y, Z : Real;
       Packer  : Bit_Packer;
       
       IX, IY, IZ : Integer_64;
    begin
       LLA_To_ECEF (Lat, Lon, Alt, X, Y, Z);
       
       IX := Integer_64 (X * 10000.0);
       IY := Integer_64 (Y * 10000.0);
       IZ := Integer_64 (Z * 10000.0);
       
       Pack (Packer, 1005, 12);
       Pack (Packer, 1, 12);
       Pack (Packer, 0, 6);
       Pack (Packer, 1, 1);
       Pack (Packer, 0, 1);
       Pack (Packer, 0, 1);
       Pack (Packer, 1, 1);
       
       Pack (Packer, To_U64 (IX), 38);
       Pack (Packer, 0, 1);
       Pack (Packer, 0, 1);
       
       Pack (Packer, To_U64 (IY), 38);
       Pack (Packer, 0, 2);
       
       Pack (Packer, To_U64 (IZ), 38);
       Pack (Packer, 0, 2);
      
      Finalize (Packer);
      
      declare
         Len : constant Stream_Element_Offset := Packer.Byte_Idx;
         Frame : Stream_Element_Array (1 .. 3 + Len + 3);
         C : Unsigned_32;
      begin
         Frame (1) := 16#D3#;
         Frame (2) := Stream_Element (Shift_Right (Unsigned_32 (Len), 8) and 3);
         Frame (3) := Stream_Element (Unsigned_32 (Len) and 16#FF#);
         
         Frame (4 .. 3 + Len) := Packer.Bytes (1 .. Len);
         
         C := CRC24Q (Frame (1 .. 3 + Len));
         
         Frame (3 + Len + 1) := Stream_Element (Shift_Right (C, 16) and 16#FF#);
         Frame (3 + Len + 2) := Stream_Element (Shift_Right (C, 8) and 16#FF#);
         Frame (3 + Len + 3) := Stream_Element (C and 16#FF#);
         
         return Frame;
      end;
   end Make_RTCM_1005;

   function NTRIP_Callback (Request : in AWS.Status.Data) return AWS.Response.Data is
      use AWS.Status;
      use AWS.Response;
      use AWS.Messages;
      
      URI : constant String := AWS.Status.URI (Request);
   begin
      if URI = "/" or URI = "" then
         declare
            Source_Table : constant String :=
              "STR;EARU;EARU;RTCM3;1005(1);0;2;GPS;EARU;IDN;0.00;0.00;1;0;EARU;none;B;N;9600;" & ASCII.CR & ASCII.LF &
              "ENDSOURCETABLE" & ASCII.CR & ASCII.LF;
         begin
            return AWS.Response.Build ("text/plain", Source_Table);
         end;
      elsif URI = "/EARU" or URI = "/earu" then
         declare
            use AWS.Net;
            Sock : constant Socket_Access := AWS.Status.Socket (Request);
            Header : constant String := "ICY 200 OK" & ASCII.CR & ASCII.LF &
                                        "Connection: close" & ASCII.CR & ASCII.LF &
                                        ASCII.CR & ASCII.LF;
                                        
            procedure Send_String (S : Socket_Type'Class; Str : String) is
               Data : Stream_Element_Array (1 .. Str'Length);
            begin
               for I in Str'Range loop
                  Data (Stream_Element_Offset (I - Str'First + 1)) := Stream_Element (Character'Pos (Str (I)));
               end loop;
               Send (S, Data);
            end Send_String;
         begin
            Ada.Text_IO.Put_Line ("[*] NTRIP Client connected to mountpoint EARU");
            Send_String (Sock.all, Header);
            
            loop
               declare
                  State : constant Earu_State := Earu.State_Store.State_Buffer.Get_Full_State;
                  RTCM  : constant Stream_Element_Array := Make_RTCM_1005 (State.Location.Lat, State.Location.Lon, State.Location.Alt);
               begin
                  Send (Sock.all, RTCM);
               exception
                  when others =>
                     exit;
               end;
               delay 1.0;
            end loop;
            
            Ada.Text_IO.Put_Line ("[*] NTRIP Client disconnected");
            return AWS.Response.Socket_Taken;
         end;
      else
         return AWS.Response.Acknowledge (S404, "Mountpoint Not Found", "text/plain");
      end if;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("[!] NTRIP Callback error: " & Ada.Exceptions.Exception_Information (E));
         return AWS.Response.Acknowledge (S500, "Internal Server Error", "text/plain");
   end NTRIP_Callback;

   task body NTRIP_Caster_Task is
      WS     : AWS.Server.HTTP;
      Config : AWS.Config.Object := AWS.Config.Get_Current;
      Port   : constant Natural := 2101;
   begin
      delay 5.0;
      Ada.Text_IO.Put_Line ("[*] Starting Ada AWS NTRIP Caster Server on port" & Port'Img);
      AWS.Config.Set.Server_Port (Config, Port);
      
      begin
         AWS.Server.Start (WS, Callback => NTRIP_Callback'Access, Config => Config);
         loop
            delay 1.0;
         end loop;
      exception
         when E : others =>
            Ada.Text_IO.Put_Line ("[!] NTRIP Caster Server failed to start on port" & Port'Img & ": " & Ada.Exceptions.Exception_Information (E));
            
            -- Fallback Port 12101
            declare
               Fallback_Port : constant Natural := 12101;
            begin
               Ada.Text_IO.Put_Line ("[*] Retrying NTRIP Caster Server on fallback port" & Fallback_Port'Img);
               AWS.Config.Set.Server_Port (Config, Fallback_Port);
               AWS.Server.Start (WS, Callback => NTRIP_Callback'Access, Config => Config);
               loop
                  delay 1.0;
               end loop;
            exception
               when E2 : others =>
                  Ada.Text_IO.Put_Line ("[!] NTRIP Caster Server failed to start on fallback port: " & Ada.Exceptions.Exception_Information (E2));
            end;
      end;
   exception
      when others =>
         null;
   end NTRIP_Caster_Task;

    task body Raw_TCP_Server_Task is
       use GNAT.Sockets;
       Receiver   : Socket_Type;
       Address    : Sock_Addr_Type;
       Client     : Socket_Type;
       Client_Addr: Sock_Addr_Type;
       
       Port       : constant Port_Type := 2102;
    begin
       Initialize;
       Create_Socket (Receiver);
       Set_Socket_Option (Receiver, Socket_Level, (Reuse_Address, True));
       Address.Addr := Any_Inet_Addr;
       Address.Port := Port;
       Bind_Socket (Receiver, Address);
       Listen_Socket (Receiver);
       
       Ada.Text_IO.Put_Line ("[*] Starting Raw TCP RTCM Stream Server on port 2102");
       Ada.Text_IO.Flush;
       
       loop
          begin
             Accept_Socket (Receiver, Client, Client_Addr);
             Ada.Text_IO.Put_Line ("[*] Raw TCP Client connected from " & Image (Client_Addr.Addr));
             Ada.Text_IO.Flush;
             
             loop
                declare
                   State : constant Earu_State := Earu.State_Store.State_Buffer.Get_Full_State;
                   RTCM  : constant Stream_Element_Array := Make_RTCM_1005 (State.Location.Lat, State.Location.Lon, State.Location.Alt);
                   Last  : Stream_Element_Offset;
                begin
                   Send_Socket (Client, RTCM, Last);
                exception
                   when others =>
                      exit;
                end;
                delay 1.0;
             end loop;
             Close_Socket (Client);
             Ada.Text_IO.Put_Line ("[*] Raw TCP Client disconnected");
             Ada.Text_IO.Flush;
          exception
             when E : others =>
                Ada.Text_IO.Put_Line ("[!] Raw TCP connection error: " & Ada.Exceptions.Exception_Information (E));
                Ada.Text_IO.Flush;
          end;
       end loop;
    exception
       when others =>
          null;
    end Raw_TCP_Server_Task;

 end Earu.Ntrip;
