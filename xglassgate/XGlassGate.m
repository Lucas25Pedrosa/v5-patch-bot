#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <string.h>

typedef void (*MSHookMemoryType)(void *target, const void *data, size_t size);

static IMP gOriginalInstallGate = NULL;
static BOOL gGetterPatched = NO;
static BOOL gGateHookInstalled = NO;

#pragma mark - Symbol lookup

static void *XGGFindSymbol(const char *name) {
    if (!name) return NULL;

    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol) return symbol;

    char underscored[256] = {0};
    size_t length = strlen(name);
    if (length + 2 < sizeof(underscored)) {
        underscored[0] = '_';
        strlcpy(underscored + 1, name, sizeof(underscored) - 1);
        symbol = dlsym(RTLD_DEFAULT, underscored);
    }

    return symbol;
}

#pragma mark - XAppearance getter patch

static BOOL XGGTryPatchAppearanceGetter(void) {
    if (gGetterPatched) return YES;

    MSHookMemoryType hookMemory = (MSHookMemoryType)XGGFindSymbol("MSHookMemory");
    if (!hookMemory) {
        return NO;
    }

    void *getter = XGGFindSymbol("$s11XAppearance10AppearanceC20isLiquidGlassEnabledSbvgZ");
    if (!getter) {
        return NO;
    }

    // X 12.23 / TwitterSPMMigration.framework / offset 0x245F48.
    // Original function prologue:
    //   stp x29, x30, [sp, #-0x10]!
    //   mov x29, sp
    // Replacement:
    //   mov w0, #1
    //   ret
    static const unsigned char expected[8] = {
        0xFD, 0x7B, 0xBF, 0xA9,
        0xFD, 0x03, 0x00, 0x91
    };

    static const unsigned char replacement[8] = {
        0x20, 0x00, 0x80, 0x52,
        0xC0, 0x03, 0x5F, 0xD6
    };

    if (memcmp(getter, replacement, sizeof(replacement)) == 0) {
        gGetterPatched = YES;
        return YES;
    }

    if (memcmp(getter, expected, sizeof(expected)) != 0) {
        const unsigned char *bytes = (const unsigned char *)getter;
        NSLog(@"[XGlassGate] getter bytes mismatch: %02x %02x %02x %02x %02x %02x %02x %02x",
              bytes[0], bytes[1], bytes[2], bytes[3],
              bytes[4], bytes[5], bytes[6], bytes[7]);
        return NO;
    }

    hookMemory(getter, replacement, sizeof(replacement));
    gGetterPatched = (memcmp(getter, replacement, sizeof(replacement)) == 0);

    NSLog(@"[XGlassGate] XAppearance.isLiquidGlassEnabled getter %@",
          gGetterPatched ? @"patched TRUE" : @"patch FAILED");

    return gGetterPatched;
}

#pragma mark - Stable native gate from 0.1.0

static void XGGInstallGateReplacement(id self, SEL _cmd, BOOL redesignEnabled) {
    NSLog(@"[XGlassGate] %@ requested=%@ -> forced YES",
          NSStringFromSelector(_cmd),
          redesignEnabled ? @"YES" : @"NO");

    if (gOriginalInstallGate) {
        ((void (*)(id, SEL, BOOL))gOriginalInstallGate)(self, _cmd, YES);
    }
}

static BOOL XGGTryInstallGateHook(void) {
    if (gGateHookInstalled) return YES;

    Class installerClass = objc_getClass("T1LiquidGlassGateInstaller");
    if (!installerClass) return NO;

    SEL selector = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    Method method = class_getClassMethod(installerClass, selector);
    if (!method) {
        method = class_getInstanceMethod(installerClass, selector);
    }
    if (!method) return NO;

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

#pragma mark - Load order

static void XGGInstall(void) {
    XGGTryPatchAppearanceGetter();
    XGGTryInstallGateHook();
}

static void XGGScheduleRetry(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        XGGInstall();
    });
}

__attribute__((constructor))
static void XGlassGateInit(void) {
    @autoreleasepool {
        NSLog(@"[XGlassGate] 0.8.0 loaded");

        // Equivalent to the physical TwitterSPMMigration patch, but performed
        // in memory. No Swift function trampoline, no T1Twitter patch, no
        // second-factor hook, and no navigation branch patch.
        XGGInstall();
        XGGScheduleRetry(0.00);
        XGGScheduleRetry(0.05);
        XGGScheduleRetry(0.20);
        XGGScheduleRetry(1.00);
    }
}
