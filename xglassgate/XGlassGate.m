#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static IMP gOrigInstallGate = NULL;
static IMP gOrigInstallGateForAccount = NULL;

static BOOL gDebugSettingsHooked = NO;
static BOOL gSwiftLiquidGlassHooked = NO;
static BOOL gRedesignFeaturesHooked = NO;
static BOOL gInstallGateHooked = NO;
static BOOL gInstallGateForAccountHooked = NO;
static BOOL gDummyFeatureHooked = NO;

#pragma mark - Moe Liquid Glass ON state

static BOOL XGGEnableLiquidGlass(void) {
    // This standalone test build represents BHTManager.enableLiquidGlass == YES.
    return YES;
}

#pragma mark - Runtime hook helper

static BOOL XGGHookMethod(Class cls,
                          SEL sel,
                          BOOL classMethod,
                          IMP replacement,
                          IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;

    Method method = classMethod ? class_getClassMethod(cls, sel)
                                : class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    Class target = classMethod ? object_getClass(cls) : cls;
    if (!target) return NO;

    IMP current = class_getMethodImplementation(target, sel);
    if (current == replacement) return YES;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    if (originalOut && !*originalOut) {
        *originalOut = current;
    }

    class_replaceMethod(target, sel, replacement, types);
    return class_getMethodImplementation(target, sel) == replacement;
}

#pragma mark - Exact ON-state replacements observed in Moe/NFB 6.3.1

static BOOL XGGReturnLiquidGlassState(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return XGGEnableLiquidGlass();
}

static BOOL XGGDummyTest1Feature(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;

    // Moe returns YES here whenever Liquid Glass is enabled.
    if (XGGEnableLiquidGlass()) return YES;
    return NO;
}

static void XGGInstallGateWithRedesignEnabled(id self,
                                               SEL _cmd,
                                               BOOL requestedState) {
    (void)requestedState;

    // Moe discards the value requested by X and forwards its own LG state.
    if (gOrigInstallGate) {
        ((void (*)(id, SEL, BOOL))gOrigInstallGate)(
            self, _cmd, XGGEnableLiquidGlass()
        );
    }
}

static void XGGInstallGateForAccount(id self, SEL _cmd, id account) {
    // Moe lets X install the normal account gate first...
    if (gOrigInstallGateForAccount) {
        ((void (*)(id, SEL, id))gOrigInstallGateForAccount)(
            self, _cmd, account
        );
    }

    // ...then immediately re-applies installGateWithRedesignEnabled:
    // using BHTManager.enableLiquidGlass.
    SEL gateSEL = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    if ([self respondsToSelector:gateSEL]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            self, gateSEL, XGGEnableLiquidGlass()
        );
    }
}

#pragma mark - Moe compatibility gate

static void XGGSyncLiquidGlassCompatibilityGate(void) {
    BOOL enabled = XGGEnableLiquidGlass();

    // Exact persisted gate used by Moe and already understood by X.
    [[NSUserDefaults standardUserDefaults]
        setBool:enabled
        forKey:@"T1LiquidGlassRedesignPersistedGate"];

    // Exact X-owned compatibility override called by Moe.
    Class compatibility =
        NSClassFromString(@"_TtC17TFSUtilitiesSwift32LiquidGlassCompatibilityOverride");
    SEL applySEL = NSSelectorFromString(@"applyOverrideIfNeeded");

    if (enabled &&
        compatibility &&
        [compatibility respondsToSelector:applySEL]) {
        ((void (*)(id, SEL))objc_msgSend)(compatibility, applySEL);
    }
}

#pragma mark - Hook installation

static void XGGInstallMoeHooks(void) {
    Class cls = Nil;

    if (!gDebugSettingsHooked) {
        cls = NSClassFromString(@"T1LiquidGlassDebugSettings");
        if (cls) {
            gDebugSettingsHooked =
                XGGHookMethod(cls,
                              NSSelectorFromString(@"useTabBarControllerEnabled"),
                              YES,
                              (IMP)XGGReturnLiquidGlassState,
                              NULL);
            if (gDebugSettingsHooked)
                NSLog(@"[XGlassGateMoe] T1LiquidGlassDebugSettings hooked");
        }
    }

    if (!gSwiftLiquidGlassHooked) {
        cls = NSClassFromString(@"_TtC17TFSUtilitiesSwift11LiquidGlass");
        if (cls) {
            gSwiftLiquidGlassHooked =
                XGGHookMethod(cls,
                              NSSelectorFromString(@"isEnabled"),
                              YES,
                              (IMP)XGGReturnLiquidGlassState,
                              NULL);
            if (gSwiftLiquidGlassHooked)
                NSLog(@"[XGlassGateMoe] TFSUtilitiesSwift.LiquidGlass hooked");
        }
    }

    if (!gRedesignFeaturesHooked) {
        cls = NSClassFromString(
            @"_TtC14T1TwitterSwift27LiquidGlassRedesignFeatures"
        );
        if (cls) {
            gRedesignFeaturesHooked =
                XGGHookMethod(cls,
                              NSSelectorFromString(@"isRedesignEnabled"),
                              NO,
                              (IMP)XGGReturnLiquidGlassState,
                              NULL);
            if (gRedesignFeaturesHooked)
                NSLog(@"[XGlassGateMoe] LiquidGlassRedesignFeatures hooked");
        }
    }

    cls = NSClassFromString(@"T1LiquidGlassGateInstaller");
    if (cls) {
        if (!gInstallGateHooked) {
            gInstallGateHooked =
                XGGHookMethod(
                    cls,
                    NSSelectorFromString(@"installGateWithRedesignEnabled:"),
                    YES,
                    (IMP)XGGInstallGateWithRedesignEnabled,
                    &gOrigInstallGate
                );
            if (gInstallGateHooked)
                NSLog(@"[XGlassGateMoe] installGateWithRedesignEnabled hooked");
        }

        if (!gInstallGateForAccountHooked) {
            gInstallGateForAccountHooked =
                XGGHookMethod(
                    cls,
                    NSSelectorFromString(@"installGateForAccount:"),
                    YES,
                    (IMP)XGGInstallGateForAccount,
                    &gOrigInstallGateForAccount
                );
            if (gInstallGateForAccountHooked)
                NSLog(@"[XGlassGateMoe] installGateForAccount hooked");
        }
    }

    if (!gDummyFeatureHooked) {
        cls = NSClassFromString(@"TFNTwitterAccount");
        if (cls) {
            gDummyFeatureHooked =
                XGGHookMethod(
                    cls,
                    NSSelectorFromString(@"isDummyTest1FeatureEnabled"),
                    NO,
                    (IMP)XGGDummyTest1Feature,
                    NULL
                );
            if (gDummyFeatureHooked)
                NSLog(@"[XGlassGateMoe] TFNTwitterAccount dummy feature hooked");
        }
    }

    XGGSyncLiquidGlassCompatibilityGate();

    // Once the installer exists, explicitly synchronize it to ON.
    Class installer = NSClassFromString(@"T1LiquidGlassGateInstaller");
    SEL gateSEL = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    if (installer && [installer respondsToSelector:gateSEL]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            installer, gateSEL, XGGEnableLiquidGlass()
        );
    }
}

static void XGGScheduleRetry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            XGGInstallMoeHooks();
        }
    );
}

__attribute__((constructor))
static void XGlassGateMoeInit(void) {
    @autoreleasepool {
        NSLog(@"[XGlassGateMoe] 1.0.0 loaded - X 12.28.1 Moe activation path");

        // Moe's targets live in several X frameworks and do not necessarily
        // exist at constructor time. Re-run installation as those images load.
        XGGInstallMoeHooks();
        XGGScheduleRetry(0.00);
        XGGScheduleRetry(0.05);
        XGGScheduleRetry(0.20);
        XGGScheduleRetry(0.50);
        XGGScheduleRetry(1.00);
        XGGScheduleRetry(2.00);
        XGGScheduleRetry(4.00);
    }
}
