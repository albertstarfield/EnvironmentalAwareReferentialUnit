with Ada.Text_IO;
with Interfaces.C;

package body Earu.Weather_Fetcher is

   function C_System (Command : Interfaces.C.char_array) return Interfaces.C.int;
   pragma Import (C, C_System, "system");

   task body Fetcher is
      Running : Boolean := False;
      URL : constant String := "https://api.open-meteo.com/v1/forecast?latitude=-6.2&longitude=106.8&current=temperature_2m,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,wind_direction_10m&hourly=temperature_2m,relative_humidity_2m,precipitation_probability,cloud_cover,wind_speed_10m,wind_direction_10m&daily=temperature_2m_max,temperature_2m_min,precipitation_sum&timezone=auto&timeformat=unixtime";
      Command_Str : constant String := "/opt/homebrew/anaconda3/bin/python3 -c 'import urllib.request, json; print(json.dumps({""meteo"": json.loads(urllib.request.urlopen(""" & URL & """).read().decode(""utf-8"")), ""wind_map"": {""grid_7x7_10m"": [[[0,[0,0]]]*7]*7}}))' > /usr/local/EnvironmentalAwareReferentialUnit/EARU_WeatherAPIHistory.dat";
      Ret : Interfaces.C.int;
      
   begin
      accept Start do
         Running := True;
      end Start;

      Ret := C_System (Interfaces.C.To_C (Command_Str));

      while Running loop
         select
            accept Stop do
               Running := False;
            end Stop;
         or
            delay 1800.0; -- 30 minutes
         end select;

         if Running then
            Ret := C_System (Interfaces.C.To_C (Command_Str));
         end if;
      end loop;
   end Fetcher;

end Earu.Weather_Fetcher;
