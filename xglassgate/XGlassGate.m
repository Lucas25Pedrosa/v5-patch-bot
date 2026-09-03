#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

static IMP gOriginalInstallGate = NULL;
static BOOL gHookInstalled = NO;

static void XGGInstallGateReplacement(id self, SEL _cmd, BOOL redesignEnabled) {
    NSLog(@"[XGlassGate] %@ requested=%@ -> forced=YES",
          NSStringFromSelector(_cmd),
          redesignEnabled ? @"YES" : @"NO");

    if (gOriginalInstallGate) {
        ((void (*)(id, SEL, BOOL))gOriginalInstallGate)(self, _cmd, YES);
    }
}

static BOOL XGGTryInstallHook(void) {
    if (gHookInstalled) {
        return YES;
    }

    Class installerClass = objc_getClass("T1LiquidGlassGateInstaller");
    if (!installerClass) {
        NSLog(@"[XGlassGate] T1LiquidGlassGateInstaller not available yet");
        return NO;
    }

    SEL selector = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    Method method = class_getClassMethod(installerClass, selector);

    if (!method) {
        // Defensive fallback in case a future build changes it from a class
        // method to an instance method while retaining the selector.
        method = class_getInstanceMethod(installerClass, selector);
    }

    if (!method) {
        NSLog(@"[XGlassGate] selector %@ not found", NSStringFromSelector(selector));
        return NO;
    }

    IMP current = method_getImplementation(method);
    if (current == (IMP)XGGInstallGateReplacement) {
        gHookInstalled = YES;
        return YES;
    }

    gOriginalInstallGate = method_setImplementation(method, (IMP)XGGInstallGateReplacement);
    gHookInstalled = (gOriginalInstallGate != NULL);

    NSLog(@"[XGlassGate] hook %@ for %@",
          gHookInstalled ? @"installed" : @"FAILED",
          NSStringFromSelector(selector));

    return gHookInstalled;
}

static void XGGScheduleRetry(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        XGGTryInstallHook();
    });
}

__attribute__((constructor))
static void XGlassGateInit(void) {
    @autoreleasepool {
        NSLog(@"[XGlassGate] 0.1.0 loaded");

        // Normally T1Twitter.framework is already registered by the time
        // injected tweak constructors run. Retry briefly for load-order safety.
        if (!XGGTryInstallHook()) {
            XGGScheduleRetry(0.0);
            XGGScheduleRetry(0.05);
            XGGScheduleRetry(0.20);
            XGGScheduleRetry(1.00);
        }
    }
}
