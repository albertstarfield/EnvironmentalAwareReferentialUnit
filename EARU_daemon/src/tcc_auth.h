/* ========================================================================== */
/*  tcc_auth.h — Authoritative macOS privacy-authorization probe (C callable)  */
/* ========================================================================== */
/*                                                                            */
/*  WHY THIS EXISTS                                                            */
/*  Reading the TCC database (util/earu_tcc.py) is a PROXY. It reports what  */
/*  the database holds, which is not what the framework will do. Worse,       */
/*  CBManager.authorization is a PROCESS-SCOPED answer: only the process that */
/*  would actually call CoreBluetooth can answer for itself. A separate       */
/*  interpreter reading the same database therefore cannot answer the question */
/*  that matters, no matter how carefully it parses.                          */
/*                                                                            */
/*  This bridge asks the framework directly, from inside the daemon, which is  */
/*  the only vantage point where the answer is meaningful.                    */
/*                                                                            */
/*  SCOPE                                                                      */
/*  Bluetooth and Location-as-seen-by-this-process. Both are in-process calls  */
/*  (src/bluetooth_scanner.mm -> CoreBluetooth; src/corewlan_scanner.mm ->     */
/*  CoreWLAN), so the daemon is the TCC principal for both and only it can      */
/*  answer for them.                                                          */
/*                                                                            */
/*  Location is reported here for a reason that is easy to get backwards: the   */
/*  COORDINATE fetch is a different principal (CoreLocationCLI, spawned via    */
/*  `launchctl asuser`, which is what util/earu_tcc.py probes). But on macOS   */
/*  the SSID part of an in-process CoreWLAN scan is gated behind Location      */
/*  Services, so THIS process's location authorization is exactly what decides  */
/*  whether WiFi network names resolve or read "<Hidden SSID>".               */
/*                                                                            */
/*  Full Disk Access needs no bundle (it is keyed to a client PATH) and is    */
/*  likewise not reported here.                                                */
/* ========================================================================== */

#ifndef TCC_AUTH_H
#define TCC_AUTH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*  CBManagerAuthorization values (CoreBluetooth, macOS 11+).                   */
/* These are the framework's own enum values, mirrored here so C and Ada can  */
/* both use them without importing the framework headers.                     */
/* ------------------------------------------------------------------------- */
#define EARU_BT_AUTH_NOT_DETERMINED 0
#define EARU_BT_AUTH_RESTRICTED     1
#define EARU_BT_AUTH_DENIED         2
#define EARU_BT_AUTH_ALLOWED        3

/* 1 if the framework reports authorization as granted, else 0.               */
int32_t tcc_bt_authorization_granted(void);

/*  The raw CBManagerAuthorization value (see the EARU_BT_AUTH_* macros).     */
/*  Returns EARU_BT_AUTH_NOT_DETERMINED when the platform predates the       */
/*  CBManager class property (macOS < 11), which is reported rather than     */
/*  guessed, so the caller can distinguish "unknown" from "denied".           */
int32_t tcc_bt_authorization(void);

/*  1 when this probe could query the framework at all, else 0. Lets the      */
/*  caller tell "no grant" apart from "cannot tell", which the binary          */
/*  database proxy cannot distinguish.                                        */
int32_t tcc_probe_available(void);

/* ------------------------------------------------------------------------- */
/* CLAuthorizationStatus values (CoreLocation).                                */
/* ------------------------------------------------------------------------- */
#define EARU_LOC_AUTH_NOT_DETERMINED       0
#define EARU_LOC_AUTH_RESTRICTED           1
#define EARU_LOC_AUTH_DENIED               2
#define EARU_LOC_AUTH_AUTHORIZED_ALWAYS    3
#define EARU_LOC_AUTH_AUTHORIZED_WHEN_IN_USE 4

/*  Location authorization AS SEEN BY THIS PROCESS.
 *
 *  This is NOT the location principal used for coordinates: those come from
 *  CoreLocationCLI spawned via `launchctl asuser`, and that process is the
 *  principal for the coordinate fetch. See tcc_auth.h's header comment.
 *
 *  It IS the principal that matters for WiFi: this process calls CoreWLAN
 *  in-process (src/corewlan_scanner.mm), and on macOS the SSID portion of a
 *  CoreWLAN scan is gated behind Location Services. So this value is what
 *  decides whether scanned networks show their real names or "<Hidden SSID>".
 *
 *  Returns EARU_LOC_AUTH_NOT_DETERMINED when the status cannot be determined,
 *  reported honestly rather than mapped to denied.                            */
int32_t tcc_location_authorization(void);

/*  1 when location authorization is either Always or WhenInUse.             */
int32_t tcc_location_granted(void);

/*  1 when the location query is available at all, else 0.                    */
int32_t tcc_location_probe_available(void);

#ifdef __cplusplus
}
#endif

#endif /* TCC_AUTH_H */