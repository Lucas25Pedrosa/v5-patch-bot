#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

static IMP gOriginalFeaturesInit = NULL;
static IMP gOriginalInstallGate = NULL;

static BOOL gFeaturesHookInstalled = NO;
static BOOL gGateHookInstalled = NO;

#pragma mark - LiquidGlassRedesignFeatures second factor

static id XGGFeaturesInitReplacement(id self,
                                     SEL _cmd,
                                     id featureSwitches,
                                     BOOL secondFactorSatisfied) {
    NSLog(@"[XGlassGate] %@ secondFactor=%@ -> forced YES",
          NSStringFromSelector(_cmd),
          secondFactorSatisfied ? @"YES" : @"NO");

    if (!gOriginalFeaturesInit) {
        return self;
    }

    return ((id (*)(id, SEL, id, BOOL))gOriginalFeaturesInit)(
        self,
        _cmd,
        featureSwitches,
        YES
    );
}

static BOOL XGGTryInstallFeaturesHook(void) {
    if (gFeaturesHookInstalled) {
        return YES;
    }

    Class cls = objc_getClass("_TtC14T1TwitterSwift27LiquidGlassRedesignFeatures");
    if (!cls) {
        return NO;
    }

    SEL selector = NSSelectorFromString(@"initWithFeatureSwitches:isSecondFactorSatisfied:");
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"[XGlassGate] %@ not found on %s",
              NSStringFromSelector(selector),
              class_getName(cls));
        return NO;
    }

    unsigned int arguments = method_getNumberOfArguments(method);
    const char *types = method_getTypeEncoding(method);

    // self + _cmd + featureSwitches + BOOL = 4 arguments.
    if (arguments != 4) {
        NSLog(@"[XGlassGate] refusing features hook: argc=%u types=%s",
              arguments,
              types ?: "?");
        return NO;
    }

    IMP current = method_getImplementation(method);
    if (current == (IMP)XGGFeaturesInitReplacement) {
        gFeaturesHookInstalled = YES;
        return YES;
    }

    gOriginalFeaturesInit = method_setImplementation(method,
                                                      (IMP)XGGFeaturesInitReplacement);
    gFeaturesHookInstalled = (gOriginalFeaturesInit != NULL);

    NSLog(@"[XGlassGate] second-factor hook %@ (types=%s)",
          gFeaturesHookInstalled ? @"installed" : @"FAILED",
          types ?: "?");

    return gFeaturesHookInstalled;
}

#pragma mark - Native redesign gate

static void XGGInstallGateReplacement(id self, SEL _cmd, BOOL redesignEnabled) {
    NSLog(@"[XGlassGate] %@ requested=%@ -> forced YES",
          NSStringFromSelector(_cmd),
          redesignEnabled ? @"YES" : @"NO");

    if (gOriginalInstallGate) {
        ((void (*)(id, SEL, BOOL))gOriginalInstallGate)(self, _cmd, YES);
    }
}

static BOOL XGGTryInstallGateHook(void) {
    if (gGateHookInstalled) {
        return YES;
    }

    Class installerClass = objc_getClass("T1LiquidGlassGateInstaller");
    if (!installerClass) {
        return NO;
    }

    SEL selector = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    Method method = class_getClassMethod(installerClass, selector);
    if (!method) {
        method = class_getInstanceMethod(installerClass, selector);
    }
    if (!method) {
        return NO;
    }

    IMP current = method_getImplementation(method);
    if (current == (IMP)XGGInstallGateReplacement) {
        gGateHookInstalled = YES;
        return YES;
    }

    gOriginalInstallGate = method_setImplementation(method,
                                                     (IMP)XGGInstallGateReplacement);
    gGateHookInstalled = (gOriginalInstallGate != NULL);

    NSLog(@"[XGlassGate] native gate hook %@",
          gGateHookInstalled ? @"installed" : @"FAILED");

    return gGateHookInstalled;
}

#pragma mark - Load-order retries

static void XGGInstallRuntimeHooks(void) {
    XGGTryInstallFeaturesHook();
    XGGTryInstallGateHook();
}

static void XGGScheduleRetry(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        XGGInstallRuntimeHooks();
    });
}

__attribute__((constructor))
static void XGlassGateInit(void) {
    @autoreleasepool {
        NSLog(@"[XGlassGate] 0.7.0 loaded");

        // Install immediately when T1Twitter is already registered, then retry
        // briefly for framework load-order differences. No Swift function hooks
        // and no executable-memory patches are used in this build.
        XGGInstallRuntimeHooks();
        XGGScheduleRetry(0.0);
        XGGScheduleRetry(0.05);
        XGGScheduleRetry(0.20);
        XGGScheduleRetry(1.00);
        XGGScheduleRetry(3.00);
    }
}
