package body Earu.BCG_Shared is

   protected body BCG_Buffer is

      procedure Push (Ax, Ay, Az : Float) is
      begin
         Earu.BCG_Detection.Push_Sample (State, Ax, Ay, Az);
      end Push;

      procedure Compute_Results
        (Entities  : out Earu.BCG_Detection.Entity_Result_Array;
         Count     : out Natural;
         Dominant  : out Earu.BCG_Detection.Entity_Result)
      is
      begin
         Earu.BCG_Detection.Compute (State, Entities, Count, Dominant);
      end Compute_Results;

      function Is_Ready return Boolean is
      begin
         return Earu.BCG_Detection.Ready (State);
      end Is_Ready;

      function Buffered return Natural is
      begin
         return Earu.BCG_Detection.Samples_Buffered (State);
      end Buffered;

   end BCG_Buffer;

end Earu.BCG_Shared;
