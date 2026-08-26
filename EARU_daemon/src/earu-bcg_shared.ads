--  earu-bcg_shared.ads — Shared BCG State Between Tasks
--
--  Provides a protected wrapper around BCG_Detection.BCG_State so the 800Hz
--  IMU task can push samples while the Monitor task reads results.

with Earu.BCG_Detection;

package Earu.BCG_Shared is

   protected BCG_Buffer is
      procedure Push (Ax, Ay, Az : Float);
      procedure Compute_Results
        (Entities  : out Earu.BCG_Detection.Entity_Result_Array;
         Count     : out Natural;
         Dominant  : out Earu.BCG_Detection.Entity_Result);
      function Is_Ready return Boolean;
      function Buffered return Natural;
   private
      State : Earu.BCG_Detection.BCG_State;
   end BCG_Buffer;

end Earu.BCG_Shared;
