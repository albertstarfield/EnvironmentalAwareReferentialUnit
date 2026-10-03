/* ==========================================================================
 *  tcc_auth.mm — Authoritative macOS privacy-authorization probe
 * ==========================================================================
 *  Asks CoreBluetooth itself whether this process is authorized, rather than
 *  inferring the answer from the TCC database. CBManager.authorization is a
 *  class property, so no CBCentralManager is instantiated and no Bluetooth
 *  hardware is touched — this is a metadata query, safe to call anywhere.
 *
 *  See tcc_auth.h for why Location is deliberately out of scope here.
 * ========================================================================== */

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <CoreLocation/CoreLocation.h>

#include "tcc_auth.h"

extern "C" {

/*  CBManager.authorization is only available on macOS 11+. Resolve it once
 *  through the Objective-C runtime rather than testing the OS version, so the
 *  check is by capability and not by a hardcoded release number. */
static SEL tcc_auth_sel(void) {
    static SEL sel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sel = NSSelectorFromString(@"authorization");
    });
    return sel;
}

int32_t tcc_probe_available(void) {
    Class cb = NSClassFromString(@"CBManager");
    if (cb == nil) return 0;
    if (![cb respondsToSelector:tcc_auth_sel()]) return 0;
    return 1;
}

int32_t tcc_bt_authorization(void) {
    if (!tcc_probe_available()) return EARU_BT_AUTH_NOT_DETERMINED;

    /* Perform the class-property read inside an autorelease pool: this is
     * called from an Ada task that has no Cocoa pool of its own. */
    @autoreleasepool {
        id mgr = [CBManager class];
        id value = [mgr valueForKey: @"authorization"];
        if (value == nil) return EARU_BT_AUTH_NOT_DETERMINED;
        return (int32_t)[value integerValue];
    }
}

int32_t tcc_bt_authorization_granted(void) {
    return tcc_bt_authorization() == EARU_BT_AUTH_ALLOWED ? 1 : 0;
}

/*  ── Location ────────────────────────────────────────────────────────────
 *
 *  Read via the CLLocationManager CLASS method rather than by instantiating a
 *  manager. Instantiating one off the main thread without a run loop provokes
 *  a CoreLocation warning and can start authorization callbacks we do not want
 *  from a monitoring-only query; the class method is a pure state read.
 *
 *  CLLocationManager.authorizationStatus is deprecated from macOS 15 in favour
 *  of an instance property, but it remains the only call that needs neither a
 *  manager instance nor a delegate. Resolved through the Obj-C runtime so a
 *  future SDK removal degrades to "cannot tell" instead of failing to link.
 */
int32_t tcc_location_probe_available(void) {
    Class cls = NSClassFromString(@"CLLocationManager");
    if (cls == nil) return 0;
    if (![cls respondsToSelector:NSSelectorFromString(@"authorizationStatus")]) return 0;
    return 1;
}

int32_t tcc_location_authorization(void) {
    if (!tcc_location_probe_available()) return EARU_LOC_AUTH_NOT_DETERMINED;

    @autoreleasepool {
        Class cls = NSClassFromString(@"CLLocationManager");
        SEL sel = NSSelectorFromString(@"authorizationStatus");
        /* The selector returns an NSInteger, not an object, so it must be
         * invoked through the typed message send rather than valueForKey. */
        NSInteger (*fn)(id, SEL) = (NSInteger (*)(id, SEL))[cls methodForSelector:sel];
        if (fn == NULL) return EARU_LOC_AUTH_NOT_DETERMINED;
        return (int32_t)fn(cls, sel);
    }
}

int32_t tcc_location_granted(void) {
    int32_t s = tcc_location_authorization();
    return (s == EARU_LOC_AUTH_AUTHORIZED_ALWAYS ||
            s == EARU_LOC_AUTH_AUTHORIZED_WHEN_IN_USE) ? 1 : 0;
}

} /* extern "C" */