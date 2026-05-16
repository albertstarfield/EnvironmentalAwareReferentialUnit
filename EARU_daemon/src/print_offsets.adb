with Ada.Text_IO; use Ada.Text_IO;
with Earu.Shm; use Earu.Shm;
with Interfaces;

procedure Print_Offsets is
   S : Stats_SHM;
   W : Weather_SHM;
begin
   Put_Line ("Stats_SHM Total Size: " & S'Size'Img);
   Put_Line ("Header offset: " & S.Header'Position'Img);
   Put_Line ("CPU_Usage offset: " & S.CPU_Usage'Position'Img);
   Put_Line ("T_CPU_ns offset: " & S.T_CPU_ns'Position'Img);
   Put_Line ("SMC_PSTR offset: " & S.SMC_PSTR'Position'Img);
   Put_Line ("Bat_Design_Wh offset: " & S.Bat_Design_Wh'Position'Img);
   Put_Line ("Load_Avg_1 offset: " & S.Load_Avg_1'Position'Img);
   Put_Line ("HID_Idle_ns offset: " & S.HID_Idle_ns'Position'Img);
   Put_Line ("TS_ISO offset: " & S.TS_ISO'Position'Img);
   Put_Line ("PMSET_Info offset: " & S.PMSET_Info'Position'Img);
   
   Put_Line ("Weather_SHM Total Size: " & W'Size'Img);
   Put_Line ("Grid offset: " & W.Grid'Position'Img);
   Put_Line ("Meteo_JSON offset: " & W.Meteo_JSON'Position'Img);
end Print_Offsets;
