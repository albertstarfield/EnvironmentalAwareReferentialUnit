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

} /* extern "C" */