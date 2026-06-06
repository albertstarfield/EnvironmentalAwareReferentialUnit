with Ada.Text_IO; use Ada.Text_IO;
with Earu.Shm; use Earu.Shm;
procedure Test_Exec is
   Stats : Stats_SHM_Ptr;
   Weather : Weather_SHM_Ptr;
   Accel : IMU_SHM_Ptr;
begin
   Put_Line("Testing SHM creation...");
   Accel := Create_IMU_SHM ("/vib_detect_shm");
   if Accel = null then Put_Line("Accel SHM: FAIL (null)"); else Put_Line("Accel SHM: OK"); end if;
   Stats := Create_Stats_SHM ("/earu_v2_stats_shm");
   if Stats = null then Put_Line("Stats SHM: FAIL (null)"); else Put_Line("Stats SHM: OK"); end if;
   Weather := Create_Weather_SHM ("/earu_v2_weather_shm");
   if Weather = null then Put_Line("Weather SHM: FAIL (null)"); else Put_Line("Weather SHM: OK"); end if;
end Test_Exec;
