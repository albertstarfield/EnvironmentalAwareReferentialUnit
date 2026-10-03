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
/*  Bluetooth only. That is deliberate: CoreBluetooth is linked into this    */
/*  process (see src/bluetooth_scanner.mm) and the daemon calls it itself,   */
/*  so the daemon IS the TCC principal for that service.                      */
/*                                                                            */
/*  Location is NOT reported here, on purpose. Location is fetched by         */
/*  spawning /opt/homebrew/bin/CoreLocationCLI through `launchctl asuser`, so */
/*  CoreLocationCLI — not this process — is the TCC principal for it. Reading */
/*  CLLocationManager.authorizationStatus here would report the status of the  */
/*  wrong process, which is the exact error this header exists to avoid.     */
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

/* ------------------------------------------------------------------------- */
/* CBManagerAuthorization values (CoreBluetooth, macOS 11+).                   */
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

#ifdef __cplusplus
}
#endif

#endif /* TCC_AUTH_H */