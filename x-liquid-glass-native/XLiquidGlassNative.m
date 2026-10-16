#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

// XLiquidGlassNative
// Intentionally activation-only: no navigation, badge, sidebar, blur,
// tab-label, legacy-host or visual compatibility fixes.

static IMP gOrigInstallGate = NULL;
static IMP gOrigInstallGateForAccount = NULL;

static BOOL gDebugSettingsHooked = NO;
static BOOL gSwiftLiquidGlassHooked = NO;
static BOOL gRedesignFeaturesHooked = NO;
static BOOL gInstallGateHooked = NO;
static BOOL gInstallGateForAccountHooked = NO;
static BOOL gAccountGateHooked = NO;

static BOOL XLGNativeHookMethod(Class cls,
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

#pragma mark - Native Liquid Glass activation gates

static BOOL XLGNativeReturnYES(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return YES;
}

static void XLGNativeInstallGateWithRedesignEnabled(id self,
                                                     SEL _cmd,
                                                     BOOL requestedState) {
    (void)requestedState;

    if (gOrigInstallGate) {
        ((void (*)(id, SEL, BOOL))gOrigInstallGate)(self, _cmd, YES);
    }
}

static void XLGNativeInstallGateForAccount(id self, SEL _cmd, id account) {
    if (gOrigInstallGateForAccount) {
        ((void (*)(id, SEL, id))gOrigInstallGateForAccount)(self, _cmd, account);
    }

    SEL gateSEL = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    if ([self respondsToSelector:gateSEL]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, gateSEL, YES);
    }
}

static void XLGNativeSyncPersistedGate(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"T1LiquidGlassRedesignPersistedGate"];

    Class compatibility =
        NSClassFromString(@"_TtC17TFSUtilitiesSwift32LiquidGlassCompatibilityOverride");
    SEL applySEL = NSSelectorFromString(@"applyOverrideIfNeeded");

    if (compatibility && [compatibility respondsToSelector:applySEL]) {
        ((void (*)(id, SEL))objc_msgSend)(compatibility, applySEL);
    }
}

static void XLGNativeInstallActivationHooks(void) {
    Class cls = Nil;

    if (!gDebugSettingsHooked) {
        cls = NSClassFromString(@"T1LiquidGlassDebugSettings");
        if (cls) {
            gDebugSettingsHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"useTabBarControllerEnabled"),
                YES,
                (IMP)XLGNativeReturnYES,
                NULL
            );
        }
    }

    if (!gSwiftLiquidGlassHooked) {
        cls = NSClassFromString(@"_TtC17TFSUtilitiesSwift11LiquidGlass");
        if (cls) {
            gSwiftLiquidGlassHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"isEnabled"),
                YES,
                (IMP)XLGNativeReturnYES,
                NULL
            );
        }
    }

    if (!gRedesignFeaturesHooked) {
        cls = NSClassFromString(@"_TtC14T1TwitterSwift27LiquidGlassRedesignFeatures");
        if (cls) {
            gRedesignFeaturesHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"isRedesignEnabled"),
                NO,
                (IMP)XLGNativeReturnYES,
                NULL
            );
        }
    }

    cls = NSClassFromString(@"T1LiquidGlassGateInstaller");
    if (cls) {
        if (!gInstallGateHooked) {
            gInstallGateHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"installGateWithRedesignEnabled:"),
                YES,
                (IMP)XLGNativeInstallGateWithRedesignEnabled,
                &gOrigInstallGate
            );
        }

        if (!gInstallGateForAccountHooked) {
            gInstallGateForAccountHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"installGateForAccount:"),
                YES,
                (IMP)XLGNativeInstallGateForAccount,
                &gOrigInstallGateForAccount
            );
        }
    }

    if (!gAccountGateHooked) {
        cls = NSClassFromString(@"TFNTwitterAccount");
        if (cls) {
            gAccountGateHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"isDummyTest1FeatureEnabled"),
                NO,
                (IMP)XLGNativeReturnYES,
                NULL
            );
        }
    }

    XLGNativeSyncPersistedGate();

    Class installer = NSClassFromString(@"T1LiquidGlassGateInstaller");
    SEL gateSEL = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    if (installer && [installer respondsToSelector:gateSEL]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(installer, gateSEL, YES);
    }
}

static void XLGNativeScheduleRetry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            XLGNativeInstallActivationHooks();
        }
    );
}

__attribute__((constructor))
static void XLiquidGlassNativeInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlassNative] 1.0.0 loaded - activation only");

        XLGNativeInstallActivationHooks();
        XLGNativeScheduleRetry(0.00);
        XLGNativeScheduleRetry(0.05);
        XLGNativeScheduleRetry(0.20);
        XLGNativeScheduleRetry(0.50);
        XLGNativeScheduleRetry(1.00);
        XLGNativeScheduleRetry(2.00);
        XLGNativeScheduleRetry(4.00);
    }
}
