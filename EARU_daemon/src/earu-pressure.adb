------------------------------------------------------------------------------
--  earu-pressure.adb                                                      --
------------------------------------------------------------------------------
--  Body of Earu.Pressure.  See the spec for the AXIOM/THEORY record.
--
--  Citation: ISO 2533:1975 - Standard Atmosphere (P0 = 1013.25 hPa)
--
--  PROVABILITY NOTE (T2): the body is two `return` statements, one guarded
--  by a boolean expression, one returning a constant.  There is no division,
--  no float-to-integer conversion, no exception handler and no elaboration
--  order dependency.  The Post contract of Sanitize is therefore discharged
--  by a single range-analysis obligation per branch, and Is_Envelope is
--  expressed directly as an expression function so it cannot drift from the
--  documented predicate.
------------------------------------------------------------------------------

pragma SPARK_Mode (On);

package body Earu.Pressure is

   ---------------------------------------------------------------------------
   -- Sanitize                                                              --
   ---------------------------------------------------------------------------
   function Sanitize (P : Earu.Types.Real; Src_Ok : Boolean) return Earu.Types.Real is
   begin
      --  T1: BOTH conditions are required.  Src_Ok alone would admit a
      --  rejected/garbled value; Is_Envelope alone would erase a real
      --  vacuum (A4).  Together they separate "no sensor" from "vacuum".
      if Src_Ok and then Is_Envelope (P) then
         --  Live, in-envelope reading: Earth normal, high/low extreme, or
         --  a genuine vacuum.  Adopt it unchanged.
         return P;
      else
         --  Absent channel (Src_Ok), out-of-envelope value, NaN, negative,
         --  or oversized.  Substitute the documented ISA standard (A3).
         return Sea_Level_Std_HPa;
      end if;
   end Sanitize;

end Earu.Pressure;
