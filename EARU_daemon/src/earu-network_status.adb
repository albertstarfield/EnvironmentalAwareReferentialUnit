package body Earu.Network_Status is

   protected body Shared_Status is

      procedure Set (Index : Positive; Status : Service_Status) is
      begin
         if Index <= 13 then
            Current_Statuses (Index) := Status;
         end if;
      end Set;

      function Get (Index : Positive) return Service_Status is
      begin
         if Index <= 13 then
            return Current_Statuses (Index);
         else
            return Unavailable;
         end if;
      end Get;

      function Get_All return Status_Array is
      begin
         return Current_Statuses;
      end Get_All;
   end Shared_Status;

end Earu.Network_Status;
