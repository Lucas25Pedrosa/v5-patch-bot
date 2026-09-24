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

static BOOL XLGEnabled(void) {
    return YES;
}

static BOOL XLGHookMethod(Class cls,
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

static BOOL XLGReturnEnabled(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return XLGEnabled();
}

static BOOL XLGDummyTest1Feature(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return XLGEnabled();
}

static void XLGInstallGateWithRedesignEnabled(id self,
                                               SEL _cmd,
                                               BOOL requestedState) {
    (void)requestedState;

    if (gOrigInstallGate) {
        ((void (*)(id, SEL, BOOL))gOrigInstallGate)(
            self, _cmd, XLGEnabled()
        );
    }
}

static void XLGInstallGateForAccount(id self, SEL _cmd, id account) {
    if (gOrigInstallGateForAccount) {
        ((void (*)(id, SEL, id))gOrigInstallGateForAccount)(
            self, _cmd, account
        );
    }

    SEL gateSEL = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    if ([self respondsToSelector:gateSEL]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            self, gateSEL, XLGEnabled()
        );
    }
}

static void XLGSyncCompatibilityGate(void) {
    [[NSUserDefaults standardUserDefaults]
        setBool:XLGEnabled()
        forKey:@"T1LiquidGlassRedesignPersistedGate"];

    Class compatibility =
        NSClassFromString(@"_TtC17TFSUtilitiesSwift32LiquidGlassCompatibilityOverride");
    SEL applySEL = NSSelectorFromString(@"applyOverrideIfNeeded");

    if (compatibility && [compatibility respondsToSelector:applySEL]) {
        ((void (*)(id, SEL))objc_msgSend)(compatibility, applySEL);
    }
}

static void XLGInstallHooks(void) {
    Class cls = Nil;

    if (!gDebugSettingsHooked) {
        cls = NSClassFromString(@"T1LiquidGlassDebugSettings");
        if (cls) {
            gDebugSettingsHooked =
                XLGHookMethod(cls,
                              NSSelectorFromString(@"useTabBarControllerEnabled"),
                              YES,
                              (IMP)XLGReturnEnabled,
                              NULL);
        }
    }

    if (!gSwiftLiquidGlassHooked) {
        cls = NSClassFromString(@"_TtC17TFSUtilitiesSwift11LiquidGlass");
        if (cls) {
            gSwiftLiquidGlassHooked =
                XLGHookMethod(cls,
                              NSSelectorFromString(@"isEnabled"),
                              YES,
                              (IMP)XLGReturnEnabled,
                              NULL);
        }
    }

    if (!gRedesignFeaturesHooked) {
        cls = NSClassFromString(
            @"_TtC14T1TwitterSwift27LiquidGlassRedesignFeatures"
        );
        if (cls) {
            gRedesignFeaturesHooked =
                XLGHookMethod(cls,
                              NSSelectorFromString(@"isRedesignEnabled"),
                              NO,
                              (IMP)XLGReturnEnabled,
                              NULL);
        }
    }

    cls = NSClassFromString(@"T1LiquidGlassGateInstaller");
    if (cls) {
        if (!gInstallGateHooked) {
            gInstallGateHooked =
                XLGHookMethod(
                    cls,
                    NSSelectorFromString(@"installGateWithRedesignEnabled:"),
                    YES,
                    (IMP)XLGInstallGateWithRedesignEnabled,
                    &gOrigInstallGate
                );
        }

        if (!gInstallGateForAccountHooked) {
            gInstallGateForAccountHooked =
                XLGHookMethod(
                    cls,
                    NSSelectorFromString(@"installGateForAccount:"),
                    YES,
                    (IMP)XLGInstallGateForAccount,
                    &gOrigInstallGateForAccount
                );
        }
    }

    if (!gDummyFeatureHooked) {
        cls = NSClassFromString(@"TFNTwitterAccount");
        if (cls) {
            gDummyFeatureHooked =
                XLGHookMethod(
                    cls,
                    NSSelectorFromString(@"isDummyTest1FeatureEnabled"),
                    NO,
                    (IMP)XLGDummyTest1Feature,
                    NULL
                );
        }
    }

    XLGSyncCompatibilityGate();

    Class installer = NSClassFromString(@"T1LiquidGlassGateInstaller");
    SEL gateSEL = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    if (installer && [installer respondsToSelector:gateSEL]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            installer, gateSEL, XLGEnabled()
        );
    }
}

static void XLGScheduleRetry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            XLGInstallHooks();
        }
    );
}

__attribute__((constructor))
static void XLiquidGlassInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlass] 1.0.0 standalone loaded");

        XLGInstallHooks();
        XLGScheduleRetry(0.00);
        XLGScheduleRetry(0.05);
        XLGScheduleRetry(0.20);
        XLGScheduleRetry(0.50);
        XLGScheduleRetry(1.00);
        XLGScheduleRetry(2.00);
        XLGScheduleRetry(4.00);
    }
}
