pragma Warnings (Off);
pragma Ada_95;
with System;
with System.Parameters;
with System.Secondary_Stack;
package ada_main is

   gnat_argc : Integer;
   gnat_argv : System.Address;
   gnat_envp : System.Address;

   pragma Import (C, gnat_argc);
   pragma Import (C, gnat_argv);
   pragma Import (C, gnat_envp);

   gnat_exit_status : Integer;
   pragma Import (C, gnat_exit_status);

   GNAT_Version : constant String :=
                    "GNAT Version: 15.0.1 20250418 (prerelease)" & ASCII.NUL;
   pragma Export (C, GNAT_Version, "__gnat_version");

   GNAT_Version_Address : constant System.Address := GNAT_Version'Address;
   pragma Export (C, GNAT_Version_Address, "__gnat_version_address");

   Ada_Main_Program_Name : constant String := "_ada_test_sensor" & ASCII.NUL;
   pragma Export (C, Ada_Main_Program_Name, "__gnat_ada_main_program_name");

   procedure adainit;
   pragma Export (C, adainit, "adainit");

   procedure adafinal;
   pragma Export (C, adafinal, "adafinal");

   function main
     (argc : Integer;
      argv : System.Address;
      envp : System.Address)
      return Integer;
   pragma Export (C, main, "main");

   type Version_32 is mod 2 ** 32;
   u00001 : constant Version_32 := 16#4c980614#;
   pragma Export (C, u00001, "test_sensorB");
   u00002 : constant Version_32 := 16#b2cfab41#;
   pragma Export (C, u00002, "system__standard_libraryB");
   u00003 : constant Version_32 := 16#6278fccd#;
   pragma Export (C, u00003, "system__standard_libraryS");
   u00004 : constant Version_32 := 16#76789da1#;
   pragma Export (C, u00004, "adaS");
   u00005 : constant Version_32 := 16#a201b8c5#;
   pragma Export (C, u00005, "ada__strings__text_buffersB");
   u00006 : constant Version_32 := 16#a7cfd09b#;
   pragma Export (C, u00006, "ada__strings__text_buffersS");
   u00007 : constant Version_32 := 16#e6d4fa36#;
   pragma Export (C, u00007, "ada__stringsS");
   u00008 : constant Version_32 := 16#70765b54#;
   pragma Export (C, u00008, "systemS");
   u00009 : constant Version_32 := 16#45e1965e#;
   pragma Export (C, u00009, "system__exception_tableB");
   u00010 : constant Version_32 := 16#fd5d2d4d#;
   pragma Export (C, u00010, "system__exception_tableS");
   u00011 : constant Version_32 := 16#7fa0a598#;
   pragma Export (C, u00011, "system__soft_linksB");
   u00012 : constant Version_32 := 16#a3fdee7d#;
   pragma Export (C, u00012, "system__soft_linksS");
   u00013 : constant Version_32 := 16#d0b087d0#;
   pragma Export (C, u00013, "system__secondary_stackB");
   u00014 : constant Version_32 := 16#debd0a58#;
   pragma Export (C, u00014, "system__secondary_stackS");
   u00015 : constant Version_32 := 16#33a162cd#;
   pragma Export (C, u00015, "ada__exceptionsB");
   u00016 : constant Version_32 := 16#00870947#;
   pragma Export (C, u00016, "ada__exceptionsS");
   u00017 : constant Version_32 := 16#85bf25f7#;
   pragma Export (C, u00017, "ada__exceptions__last_chance_handlerB");
   u00018 : constant Version_32 := 16#a028f72d#;
   pragma Export (C, u00018, "ada__exceptions__last_chance_handlerS");
   u00019 : constant Version_32 := 16#42d3e466#;
   pragma Export (C, u00019, "system__exceptionsS");
   u00020 : constant Version_32 := 16#c367aa24#;
   pragma Export (C, u00020, "system__exceptions__machineB");
   u00021 : constant Version_32 := 16#ec13924a#;
   pragma Export (C, u00021, "system__exceptions__machineS");
   u00022 : constant Version_32 := 16#7706238d#;
   pragma Export (C, u00022, "system__exceptions_debugB");
   u00023 : constant Version_32 := 16#40780307#;
   pragma Export (C, u00023, "system__exceptions_debugS");
   u00024 : constant Version_32 := 16#52e91815#;
   pragma Export (C, u00024, "system__img_intS");
   u00025 : constant Version_32 := 16#f2c63a02#;
   pragma Export (C, u00025, "ada__numericsS");
   u00026 : constant Version_32 := 16#174f5472#;
   pragma Export (C, u00026, "ada__numerics__big_numbersS");
   u00027 : constant Version_32 := 16#8a5c240d#;
   pragma Export (C, u00027, "system__unsigned_typesS");
   u00028 : constant Version_32 := 16#bca88fbc#;
   pragma Export (C, u00028, "system__storage_elementsS");
   u00029 : constant Version_32 := 16#5c7d9c20#;
   pragma Export (C, u00029, "system__tracebackB");
   u00030 : constant Version_32 := 16#f6ecafe9#;
   pragma Export (C, u00030, "system__tracebackS");
   u00031 : constant Version_32 := 16#5f6b6486#;
   pragma Export (C, u00031, "system__traceback_entriesB");
   u00032 : constant Version_32 := 16#b86ae4d8#;
   pragma Export (C, u00032, "system__traceback_entriesS");
   u00033 : constant Version_32 := 16#65d5266b#;
   pragma Export (C, u00033, "system__traceback__symbolicB");
   u00034 : constant Version_32 := 16#140ceb78#;
   pragma Export (C, u00034, "system__traceback__symbolicS");
   u00035 : constant Version_32 := 16#701f9d88#;
   pragma Export (C, u00035, "ada__exceptions__tracebackB");
   u00036 : constant Version_32 := 16#26ed0985#;
   pragma Export (C, u00036, "ada__exceptions__tracebackS");
   u00037 : constant Version_32 := 16#f9910acc#;
   pragma Export (C, u00037, "system__address_imageB");
   u00038 : constant Version_32 := 16#d19ac66e#;
   pragma Export (C, u00038, "system__address_imageS");
   u00039 : constant Version_32 := 16#45c8b1f1#;
   pragma Export (C, u00039, "system__img_address_32S");
   u00040 : constant Version_32 := 16#9111f9c1#;
   pragma Export (C, u00040, "interfacesS");
   u00041 : constant Version_32 := 16#68e81073#;
   pragma Export (C, u00041, "system__img_address_64S");
   u00042 : constant Version_32 := 16#fd158a37#;
   pragma Export (C, u00042, "system__wch_conB");
   u00043 : constant Version_32 := 16#a9757837#;
   pragma Export (C, u00043, "system__wch_conS");
   u00044 : constant Version_32 := 16#5c289972#;
   pragma Export (C, u00044, "system__wch_stwB");
   u00045 : constant Version_32 := 16#84645436#;
   pragma Export (C, u00045, "system__wch_stwS");
   u00046 : constant Version_32 := 16#7cd63de5#;
   pragma Export (C, u00046, "system__wch_cnvB");
   u00047 : constant Version_32 := 16#afb5b247#;
   pragma Export (C, u00047, "system__wch_cnvS");
   u00048 : constant Version_32 := 16#e538de43#;
   pragma Export (C, u00048, "system__wch_jisB");
   u00049 : constant Version_32 := 16#1a02d06d#;
   pragma Export (C, u00049, "system__wch_jisS");
   u00050 : constant Version_32 := 16#a43efea2#;
   pragma Export (C, u00050, "system__parametersB");
   u00051 : constant Version_32 := 16#45e1a745#;
   pragma Export (C, u00051, "system__parametersS");
   u00052 : constant Version_32 := 16#0286ce9f#;
   pragma Export (C, u00052, "system__soft_links__initializeB");
   u00053 : constant Version_32 := 16#ac2e8b53#;
   pragma Export (C, u00053, "system__soft_links__initializeS");
   u00054 : constant Version_32 := 16#8599b27b#;
   pragma Export (C, u00054, "system__stack_checkingB");
   u00055 : constant Version_32 := 16#b7294e42#;
   pragma Export (C, u00055, "system__stack_checkingS");
   u00056 : constant Version_32 := 16#8b7604c4#;
   pragma Export (C, u00056, "ada__strings__utf_encodingB");
   u00057 : constant Version_32 := 16#c9e86997#;
   pragma Export (C, u00057, "ada__strings__utf_encodingS");
   u00058 : constant Version_32 := 16#bb780f45#;
   pragma Export (C, u00058, "ada__strings__utf_encoding__stringsB");
   u00059 : constant Version_32 := 16#b85ff4b6#;
   pragma Export (C, u00059, "ada__strings__utf_encoding__stringsS");
   u00060 : constant Version_32 := 16#d1d1ed0b#;
   pragma Export (C, u00060, "ada__strings__utf_encoding__wide_stringsB");
   u00061 : constant Version_32 := 16#5678478f#;
   pragma Export (C, u00061, "ada__strings__utf_encoding__wide_stringsS");
   u00062 : constant Version_32 := 16#c2b98963#;
   pragma Export (C, u00062, "ada__strings__utf_encoding__wide_wide_stringsB");
   u00063 : constant Version_32 := 16#d7af3358#;
   pragma Export (C, u00063, "ada__strings__utf_encoding__wide_wide_stringsS");
   u00064 : constant Version_32 := 16#683e3bb7#;
   pragma Export (C, u00064, "ada__tagsB");
   u00065 : constant Version_32 := 16#4ff764f3#;
   pragma Export (C, u00065, "ada__tagsS");
   u00066 : constant Version_32 := 16#3548d972#;
   pragma Export (C, u00066, "system__htableB");
   u00067 : constant Version_32 := 16#f1af03bf#;
   pragma Export (C, u00067, "system__htableS");
   u00068 : constant Version_32 := 16#1f1abe38#;
   pragma Export (C, u00068, "system__string_hashB");
   u00069 : constant Version_32 := 16#56ea83c0#;
   pragma Export (C, u00069, "system__string_hashS");
   u00070 : constant Version_32 := 16#e7d0da5b#;
   pragma Export (C, u00070, "system__val_lluS");
   u00071 : constant Version_32 := 16#238798c9#;
   pragma Export (C, u00071, "system__sparkS");
   u00072 : constant Version_32 := 16#a571a4dc#;
   pragma Export (C, u00072, "system__spark__cut_operationsB");
   u00073 : constant Version_32 := 16#629c0fb7#;
   pragma Export (C, u00073, "system__spark__cut_operationsS");
   u00074 : constant Version_32 := 16#365e21c1#;
   pragma Export (C, u00074, "system__val_utilB");
   u00075 : constant Version_32 := 16#f3b10aca#;
   pragma Export (C, u00075, "system__val_utilS");
   u00076 : constant Version_32 := 16#b98923bf#;
   pragma Export (C, u00076, "system__case_utilB");
   u00077 : constant Version_32 := 16#bf658c01#;
   pragma Export (C, u00077, "system__case_utilS");
   u00078 : constant Version_32 := 16#27ac21ac#;
   pragma Export (C, u00078, "ada__text_ioB");
   u00079 : constant Version_32 := 16#60f53344#;
   pragma Export (C, u00079, "ada__text_ioS");
   u00080 : constant Version_32 := 16#b228eb1e#;
   pragma Export (C, u00080, "ada__streamsB");
   u00081 : constant Version_32 := 16#613fe11c#;
   pragma Export (C, u00081, "ada__streamsS");
   u00082 : constant Version_32 := 16#367911c4#;
   pragma Export (C, u00082, "ada__io_exceptionsS");
   u00083 : constant Version_32 := 16#05222263#;
   pragma Export (C, u00083, "system__put_imagesB");
   u00084 : constant Version_32 := 16#6cd85c4b#;
   pragma Export (C, u00084, "system__put_imagesS");
   u00085 : constant Version_32 := 16#22b9eb9f#;
   pragma Export (C, u00085, "ada__strings__text_buffers__utilsB");
   u00086 : constant Version_32 := 16#89062ac3#;
   pragma Export (C, u00086, "ada__strings__text_buffers__utilsS");
   u00087 : constant Version_32 := 16#1cacf006#;
   pragma Export (C, u00087, "interfaces__c_streamsB");
   u00088 : constant Version_32 := 16#d07279c2#;
   pragma Export (C, u00088, "interfaces__c_streamsS");
   u00089 : constant Version_32 := 16#fb523cdb#;
   pragma Export (C, u00089, "system__crtlS");
   u00090 : constant Version_32 := 16#ec2f4d1e#;
   pragma Export (C, u00090, "system__file_ioB");
   u00091 : constant Version_32 := 16#16390e12#;
   pragma Export (C, u00091, "system__file_ioS");
   u00092 : constant Version_32 := 16#c34b231e#;
   pragma Export (C, u00092, "ada__finalizationS");
   u00093 : constant Version_32 := 16#d00f339c#;
   pragma Export (C, u00093, "system__finalization_rootB");
   u00094 : constant Version_32 := 16#7a0a6580#;
   pragma Export (C, u00094, "system__finalization_rootS");
   u00095 : constant Version_32 := 16#ef3c5c6f#;
   pragma Export (C, u00095, "system__finalization_primitivesB");
   u00096 : constant Version_32 := 16#f622319e#;
   pragma Export (C, u00096, "system__finalization_primitivesS");
   u00097 : constant Version_32 := 16#9cd38c2c#;
   pragma Export (C, u00097, "system__os_locksS");
   u00098 : constant Version_32 := 16#401f6fd6#;
   pragma Export (C, u00098, "interfaces__cB");
   u00099 : constant Version_32 := 16#3dbcc8ee#;
   pragma Export (C, u00099, "interfaces__cS");
   u00100 : constant Version_32 := 16#8f29e754#;
   pragma Export (C, u00100, "system__os_constantsS");
   u00101 : constant Version_32 := 16#c04dcb27#;
   pragma Export (C, u00101, "system__os_libB");
   u00102 : constant Version_32 := 16#f51dc4c4#;
   pragma Export (C, u00102, "system__os_libS");
   u00103 : constant Version_32 := 16#94d23d25#;
   pragma Export (C, u00103, "system__atomic_operations__test_and_setB");
   u00104 : constant Version_32 := 16#57acee8e#;
   pragma Export (C, u00104, "system__atomic_operations__test_and_setS");
   u00105 : constant Version_32 := 16#b7152171#;
   pragma Export (C, u00105, "system__atomic_operationsS");
   u00106 : constant Version_32 := 16#553a519e#;
   pragma Export (C, u00106, "system__atomic_primitivesB");
   u00107 : constant Version_32 := 16#78a6d0b7#;
   pragma Export (C, u00107, "system__atomic_primitivesS");
   u00108 : constant Version_32 := 16#256dbbe5#;
   pragma Export (C, u00108, "system__stringsB");
   u00109 : constant Version_32 := 16#ebf45b4c#;
   pragma Export (C, u00109, "system__stringsS");
   u00110 : constant Version_32 := 16#fa03c63e#;
   pragma Export (C, u00110, "system__file_control_blockS");
   u00111 : constant Version_32 := 16#d1e616aa#;
   pragma Export (C, u00111, "earuS");
   u00112 : constant Version_32 := 16#b6f1599c#;
   pragma Export (C, u00112, "earu__ioB");
   u00113 : constant Version_32 := 16#7d1bdb74#;
   pragma Export (C, u00113, "earu__ioS");
   u00114 : constant Version_32 := 16#edf015bc#;
   pragma Export (C, u00114, "ada__numerics__aux_floatS");
   u00115 : constant Version_32 := 16#effcb9fc#;
   pragma Export (C, u00115, "ada__numerics__aux_linker_optionsS");
   u00116 : constant Version_32 := 16#8272e858#;
   pragma Export (C, u00116, "ada__numerics__aux_long_floatS");
   u00117 : constant Version_32 := 16#d273669e#;
   pragma Export (C, u00117, "ada__numerics__aux_long_long_floatS");
   u00118 : constant Version_32 := 16#33fcdf18#;
   pragma Export (C, u00118, "ada__numerics__aux_short_floatS");
   u00119 : constant Version_32 := 16#460c9176#;
   pragma Export (C, u00119, "ada__streams__stream_ioB");
   u00120 : constant Version_32 := 16#5dc4c9e4#;
   pragma Export (C, u00120, "ada__streams__stream_ioS");
   u00121 : constant Version_32 := 16#5de653db#;
   pragma Export (C, u00121, "system__communicationB");
   u00122 : constant Version_32 := 16#dfc2bd67#;
   pragma Export (C, u00122, "system__communicationS");
   u00123 : constant Version_32 := 16#96a20755#;
   pragma Export (C, u00123, "ada__strings__fixedB");
   u00124 : constant Version_32 := 16#11b694ce#;
   pragma Export (C, u00124, "ada__strings__fixedS");
   u00125 : constant Version_32 := 16#203d5282#;
   pragma Export (C, u00125, "ada__strings__mapsB");
   u00126 : constant Version_32 := 16#6feaa257#;
   pragma Export (C, u00126, "ada__strings__mapsS");
   u00127 : constant Version_32 := 16#b451a498#;
   pragma Export (C, u00127, "system__bit_opsB");
   u00128 : constant Version_32 := 16#bd85f768#;
   pragma Export (C, u00128, "system__bit_opsS");
   u00129 : constant Version_32 := 16#5b4659fa#;
   pragma Export (C, u00129, "ada__charactersS");
   u00130 : constant Version_32 := 16#cde9ea2d#;
   pragma Export (C, u00130, "ada__characters__latin_1S");
   u00131 : constant Version_32 := 16#d053aba9#;
   pragma Export (C, u00131, "ada__strings__searchB");
   u00132 : constant Version_32 := 16#97fe4a15#;
   pragma Export (C, u00132, "ada__strings__searchS");
   u00133 : constant Version_32 := 16#4259a79c#;
   pragma Export (C, u00133, "ada__strings__unboundedB");
   u00134 : constant Version_32 := 16#b40332b4#;
   pragma Export (C, u00134, "ada__strings__unboundedS");
   u00135 : constant Version_32 := 16#b3c38977#;
   pragma Export (C, u00135, "system__return_stackS");
   u00136 : constant Version_32 := 16#52627794#;
   pragma Export (C, u00136, "system__atomic_countersB");
   u00137 : constant Version_32 := 16#ac6eb497#;
   pragma Export (C, u00137, "system__atomic_countersS");
   u00138 : constant Version_32 := 16#756a1fdd#;
   pragma Export (C, u00138, "system__stream_attributesB");
   u00139 : constant Version_32 := 16#cc7d5f1e#;
   pragma Export (C, u00139, "system__stream_attributesS");
   u00140 : constant Version_32 := 16#1c617d0b#;
   pragma Export (C, u00140, "system__stream_attributes__xdrB");
   u00141 : constant Version_32 := 16#e4218e58#;
   pragma Export (C, u00141, "system__stream_attributes__xdrS");
   u00142 : constant Version_32 := 16#b3448438#;
   pragma Export (C, u00142, "system__fat_fltS");
   u00143 : constant Version_32 := 16#95768d35#;
   pragma Export (C, u00143, "system__fat_lfltS");
   u00144 : constant Version_32 := 16#efa623df#;
   pragma Export (C, u00144, "system__fat_llfS");
   u00145 : constant Version_32 := 16#5e511f79#;
   pragma Export (C, u00145, "ada__text_io__generic_auxB");
   u00146 : constant Version_32 := 16#d2ac8a2d#;
   pragma Export (C, u00146, "ada__text_io__generic_auxS");
   u00147 : constant Version_32 := 16#83535fbc#;
   pragma Export (C, u00147, "earu__shmB");
   u00148 : constant Version_32 := 16#8c613f3a#;
   pragma Export (C, u00148, "earu__shmS");
   u00149 : constant Version_32 := 16#3c9c2ae7#;
   pragma Export (C, u00149, "interfaces__c__stringsB");
   u00150 : constant Version_32 := 16#bd4557ce#;
   pragma Export (C, u00150, "interfaces__c__stringsS");
   u00151 : constant Version_32 := 16#ab03779d#;
   pragma Export (C, u00151, "earu__typesS");
   u00152 : constant Version_32 := 16#b5988c27#;
   pragma Export (C, u00152, "gnatS");
   u00153 : constant Version_32 := 16#c083f050#;
   pragma Export (C, u00153, "gnat__sha256B");
   u00154 : constant Version_32 := 16#eb515513#;
   pragma Export (C, u00154, "gnat__sha256S");
   u00155 : constant Version_32 := 16#d96208db#;
   pragma Export (C, u00155, "gnat__secure_hashesB");
   u00156 : constant Version_32 := 16#739931ba#;
   pragma Export (C, u00156, "gnat__secure_hashesS");
   u00157 : constant Version_32 := 16#1538efc3#;
   pragma Export (C, u00157, "gnat__secure_hashes__sha2_32B");
   u00158 : constant Version_32 := 16#ebdefe7d#;
   pragma Export (C, u00158, "gnat__secure_hashes__sha2_32S");
   u00159 : constant Version_32 := 16#0668360c#;
   pragma Export (C, u00159, "gnat__byte_swappingB");
   u00160 : constant Version_32 := 16#613cc14a#;
   pragma Export (C, u00160, "gnat__byte_swappingS");
   u00161 : constant Version_32 := 16#fc33d47d#;
   pragma Export (C, u00161, "system__byte_swappingS");
   u00162 : constant Version_32 := 16#25a43d5d#;
   pragma Export (C, u00162, "gnat__secure_hashes__sha2_commonB");
   u00163 : constant Version_32 := 16#21653399#;
   pragma Export (C, u00163, "gnat__secure_hashes__sha2_commonS");
   u00164 : constant Version_32 := 16#ca878138#;
   pragma Export (C, u00164, "system__concat_2B");
   u00165 : constant Version_32 := 16#c58d28a3#;
   pragma Export (C, u00165, "system__concat_2S");
   u00166 : constant Version_32 := 16#752a67ed#;
   pragma Export (C, u00166, "system__concat_3B");
   u00167 : constant Version_32 := 16#fa0c42f6#;
   pragma Export (C, u00167, "system__concat_3S");
   u00168 : constant Version_32 := 16#bcc987d2#;
   pragma Export (C, u00168, "system__concat_4B");
   u00169 : constant Version_32 := 16#438e046a#;
   pragma Export (C, u00169, "system__concat_4S");
   u00170 : constant Version_32 := 16#ebb39bbb#;
   pragma Export (C, u00170, "system__concat_5B");
   u00171 : constant Version_32 := 16#30ef8a8f#;
   pragma Export (C, u00171, "system__concat_5S");
   u00172 : constant Version_32 := 16#ada38524#;
   pragma Export (C, u00172, "system__concat_7B");
   u00173 : constant Version_32 := 16#798b1acb#;
   pragma Export (C, u00173, "system__concat_7S");
   u00174 : constant Version_32 := 16#63bad2e6#;
   pragma Export (C, u00174, "system__concat_9B");
   u00175 : constant Version_32 := 16#2499933f#;
   pragma Export (C, u00175, "system__concat_9S");
   u00176 : constant Version_32 := 16#6b279574#;
   pragma Export (C, u00176, "system__exn_lfltS");
   u00177 : constant Version_32 := 16#b981d8aa#;
   pragma Export (C, u00177, "system__img_biuS");
   u00178 : constant Version_32 := 16#7f4ba8ed#;
   pragma Export (C, u00178, "system__img_fltS");
   u00179 : constant Version_32 := 16#1b28662b#;
   pragma Export (C, u00179, "system__float_controlB");
   u00180 : constant Version_32 := 16#908a1868#;
   pragma Export (C, u00180, "system__float_controlS");
   u00181 : constant Version_32 := 16#19ff6eea#;
   pragma Export (C, u00181, "system__img_unsS");
   u00182 : constant Version_32 := 16#1efd3382#;
   pragma Export (C, u00182, "system__img_utilB");
   u00183 : constant Version_32 := 16#076fffed#;
   pragma Export (C, u00183, "system__img_utilS");
   u00184 : constant Version_32 := 16#d56ce2ec#;
   pragma Export (C, u00184, "system__powten_fltS");
   u00185 : constant Version_32 := 16#a232d262#;
   pragma Export (C, u00185, "system__img_lfltS");
   u00186 : constant Version_32 := 16#e0664740#;
   pragma Export (C, u00186, "system__img_lluS");
   u00187 : constant Version_32 := 16#dc7e099c#;
   pragma Export (C, u00187, "system__powten_lfltS");
   u00188 : constant Version_32 := 16#f4df1f74#;
   pragma Export (C, u00188, "system__img_llbS");
   u00189 : constant Version_32 := 16#e9e2f50e#;
   pragma Export (C, u00189, "system__img_llfS");
   u00190 : constant Version_32 := 16#ebefb317#;
   pragma Export (C, u00190, "system__powten_llfS");
   u00191 : constant Version_32 := 16#3ab08e6e#;
   pragma Export (C, u00191, "system__img_lliS");
   u00192 : constant Version_32 := 16#832eea06#;
   pragma Export (C, u00192, "system__img_lllbS");
   u00193 : constant Version_32 := 16#c9d8ed88#;
   pragma Export (C, u00193, "system__img_llliS");
   u00194 : constant Version_32 := 16#895af30a#;
   pragma Export (C, u00194, "system__img_lllwS");
   u00195 : constant Version_32 := 16#a8ed6a7f#;
   pragma Export (C, u00195, "system__img_llwS");
   u00196 : constant Version_32 := 16#865b6398#;
   pragma Export (C, u00196, "system__img_wiuS");
   u00197 : constant Version_32 := 16#a7e38293#;
   pragma Export (C, u00197, "system__val_fltS");
   u00198 : constant Version_32 := 16#d56674ad#;
   pragma Export (C, u00198, "system__exn_fltS");
   u00199 : constant Version_32 := 16#ce5f50f9#;
   pragma Export (C, u00199, "system__val_intS");
   u00200 : constant Version_32 := 16#39f8db91#;
   pragma Export (C, u00200, "system__val_unsS");
   u00201 : constant Version_32 := 16#424fcc62#;
   pragma Export (C, u00201, "system__val_lfltS");
   u00202 : constant Version_32 := 16#e2987e2f#;
   pragma Export (C, u00202, "system__val_llfS");
   u00203 : constant Version_32 := 16#46895504#;
   pragma Export (C, u00203, "system__exn_llfS");
   u00204 : constant Version_32 := 16#111e58d8#;
   pragma Export (C, u00204, "system__val_lliS");
   u00205 : constant Version_32 := 16#c1a0d3c0#;
   pragma Export (C, u00205, "system__val_llliS");
   u00206 : constant Version_32 := 16#7a141c22#;
   pragma Export (C, u00206, "system__val_llluS");
   u00207 : constant Version_32 := 16#0ddbd91f#;
   pragma Export (C, u00207, "system__memoryB");
   u00208 : constant Version_32 := 16#68e2c74e#;
   pragma Export (C, u00208, "system__memoryS");

   --  BEGIN ELABORATION ORDER
   --  ada%s
   --  ada.characters%s
   --  ada.characters.latin_1%s
   --  interfaces%s
   --  system%s
   --  system.atomic_operations%s
   --  system.byte_swapping%s
   --  system.float_control%s
   --  system.float_control%b
   --  system.parameters%s
   --  system.parameters%b
   --  system.crtl%s
   --  interfaces.c_streams%s
   --  interfaces.c_streams%b
   --  system.powten_flt%s
   --  system.powten_lflt%s
   --  system.powten_llf%s
   --  system.spark%s
   --  system.spark.cut_operations%s
   --  system.spark.cut_operations%b
   --  system.storage_elements%s
   --  system.img_address_32%s
   --  system.img_address_64%s
   --  system.return_stack%s
   --  system.stack_checking%s
   --  system.stack_checking%b
   --  system.string_hash%s
   --  system.string_hash%b
   --  system.htable%s
   --  system.htable%b
   --  system.strings%s
   --  system.strings%b
   --  system.traceback_entries%s
   --  system.traceback_entries%b
   --  system.unsigned_types%s
   --  system.img_biu%s
   --  system.img_llb%s
   --  system.img_lllb%s
   --  system.img_lllw%s
   --  system.img_llw%s
   --  system.img_wiu%s
   --  system.wch_con%s
   --  system.wch_con%b
   --  system.wch_jis%s
   --  system.wch_jis%b
   --  system.wch_cnv%s
   --  system.wch_cnv%b
   --  system.concat_2%s
   --  system.concat_2%b
   --  system.concat_3%s
   --  system.concat_3%b
   --  system.concat_4%s
   --  system.concat_4%b
   --  system.concat_5%s
   --  system.concat_5%b
   --  system.concat_7%s
   --  system.concat_7%b
   --  system.concat_9%s
   --  system.concat_9%b
   --  system.exn_flt%s
   --  system.exn_lflt%s
   --  system.exn_llf%s
   --  system.traceback%s
   --  system.traceback%b
   --  system.secondary_stack%s
   --  system.standard_library%s
   --  ada.exceptions%s
   --  system.exceptions_debug%s
   --  system.exceptions_debug%b
   --  system.soft_links%s
   --  system.wch_stw%s
   --  system.wch_stw%b
   --  ada.exceptions.last_chance_handler%s
   --  ada.exceptions.last_chance_handler%b
   --  ada.exceptions.traceback%s
   --  ada.exceptions.traceback%b
   --  system.address_image%s
   --  system.address_image%b
   --  system.exception_table%s
   --  system.exception_table%b
   --  ada.numerics%s
   --  ada.numerics.big_numbers%s
   --  system.exceptions%s
   --  system.exceptions.machine%s
   --  system.exceptions.machine%b
   --  system.img_int%s
   --  system.memory%s
   --  system.memory%b
   --  system.secondary_stack%b
   --  system.soft_links.initialize%s
   --  system.soft_links.initialize%b
   --  system.soft_links%b
   --  system.standard_library%b
   --  system.traceback.symbolic%s
   --  system.traceback.symbolic%b
   --  ada.exceptions%b
   --  ada.io_exceptions%s
   --  ada.numerics.aux_linker_options%s
   --  ada.numerics.aux_float%s
   --  ada.numerics.aux_long_float%s
   --  ada.numerics.aux_long_long_float%s
   --  ada.numerics.aux_short_float%s
   --  ada.strings%s
   --  ada.strings.utf_encoding%s
   --  ada.strings.utf_encoding%b
   --  ada.strings.utf_encoding.strings%s
   --  ada.strings.utf_encoding.strings%b
   --  ada.strings.utf_encoding.wide_strings%s
   --  ada.strings.utf_encoding.wide_strings%b
   --  ada.strings.utf_encoding.wide_wide_strings%s
   --  ada.strings.utf_encoding.wide_wide_strings%b
   --  gnat%s
   --  gnat.byte_swapping%s
   --  gnat.byte_swapping%b
   --  interfaces.c%s
   --  interfaces.c%b
   --  interfaces.c.strings%s
   --  interfaces.c.strings%b
   --  system.atomic_primitives%s
   --  system.atomic_primitives%b
   --  system.atomic_counters%s
   --  system.atomic_counters%b
   --  system.atomic_operations.test_and_set%s
   --  system.atomic_operations.test_and_set%b
   --  system.case_util%s
   --  system.case_util%b
   --  system.fat_flt%s
   --  system.fat_lflt%s
   --  system.fat_llf%s
   --  system.os_constants%s
   --  system.os_lib%s
   --  system.os_lib%b
   --  system.os_locks%s
   --  system.finalization_primitives%s
   --  system.finalization_primitives%b
   --  system.val_util%s
   --  system.val_util%b
   --  system.val_flt%s
   --  system.val_lflt%s
   --  system.val_llf%s
   --  system.val_lllu%s
   --  system.val_llli%s
   --  system.val_llu%s
   --  ada.tags%s
   --  ada.tags%b
   --  ada.strings.text_buffers%s
   --  ada.strings.text_buffers%b
   --  ada.strings.text_buffers.utils%s
   --  ada.strings.text_buffers.utils%b
   --  system.put_images%s
   --  system.put_images%b
   --  ada.streams%s
   --  ada.streams%b
   --  system.communication%s
   --  system.communication%b
   --  system.file_control_block%s
   --  system.finalization_root%s
   --  system.finalization_root%b
   --  ada.finalization%s
   --  system.file_io%s
   --  system.file_io%b
   --  ada.streams.stream_io%s
   --  ada.streams.stream_io%b
   --  system.stream_attributes%s
   --  system.stream_attributes.xdr%s
   --  system.stream_attributes.xdr%b
   --  system.stream_attributes%b
   --  system.val_lli%s
   --  system.val_uns%s
   --  system.val_int%s
   --  ada.text_io%s
   --  ada.text_io%b
   --  ada.text_io.generic_aux%s
   --  ada.text_io.generic_aux%b
   --  gnat.secure_hashes%s
   --  gnat.secure_hashes%b
   --  gnat.secure_hashes.sha2_common%s
   --  gnat.secure_hashes.sha2_common%b
   --  gnat.secure_hashes.sha2_32%s
   --  gnat.secure_hashes.sha2_32%b
   --  gnat.sha256%s
   --  gnat.sha256%b
   --  system.bit_ops%s
   --  system.bit_ops%b
   --  ada.strings.maps%s
   --  ada.strings.maps%b
   --  ada.strings.search%s
   --  ada.strings.search%b
   --  ada.strings.fixed%s
   --  ada.strings.fixed%b
   --  ada.strings.unbounded%s
   --  ada.strings.unbounded%b
   --  system.img_lli%s
   --  system.img_llli%s
   --  system.img_llu%s
   --  system.img_uns%s
   --  system.img_util%s
   --  system.img_util%b
   --  system.img_flt%s
   --  system.img_lflt%s
   --  system.img_llf%s
   --  earu%s
   --  earu.shm%s
   --  earu.shm%b
   --  earu.types%s
   --  earu.io%s
   --  earu.io%b
   --  test_sensor%b
   --  END ELABORATION ORDER

end ada_main;
