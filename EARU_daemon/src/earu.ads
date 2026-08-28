package Earu is
   --  NOTE (audit W8 fix): inner "pragma SPARK_Mode (On);" removed - an
   --  Off -> On transition is illegal now that config/earu_spark.adc sets
   --  the project-wide default to Off. Proven child packages opt back in
   --  via explicit `with SPARK_Mode => On` aspects.
end Earu;
