package Earu.Ntrip is
   pragma SPARK_Mode (Off);  -- c_binding: NTRIP C socket interop

   task NTRIP_Caster_Task;
   task Raw_TCP_Server_Task;

end Earu.Ntrip;
