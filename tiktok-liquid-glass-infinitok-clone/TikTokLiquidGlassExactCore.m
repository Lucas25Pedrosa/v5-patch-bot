#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

// Confirmed from the user's Infinitok 1.0.1 arm64 disassembly:
// TUXLiquidGlassConfiguration -isInteractive returns
// original || [[NSUserDefaults standardUserDefaults] boolForKey:@"liquid_glass_enabled"].

static NSString *const TLGMasterPreferenceKey = @"liquid_glass_enabled";
static IMP gOriginalIsInteractive = NULL;
static BOOL gExactCoreInstalled = NO;

static BOOL TLGExactIsInteractive(id self, SEL _cmd) {
    BOOL original = NO;
    if (gOriginalIsInteractive) {
        original = ((BOOL (*)(id, SEL))gOriginalIsInteractive)(self, _cmd);
    }
    BOOL forced = [[NSUserDefaults standardUserDefaults] boolForKey:TLGMasterPreferenceKey];
    return original || forced;
}

static void InstallExactLiquidGlassCore(void) {
    @synchronized([NSObject class]) {
        if (gExactCoreInstalled) return;

        Class cls = NSClassFromString(@"TUXLiquidGlassConfiguration");
        if (!cls) cls = objc_getClass("TUXLiquidGlassConfiguration");
        if (!cls) return;

        SEL sel = NSSelectorFromString(@"isInteractive");
        Method method = class_getInstanceMethod(cls, sel);
        if (!method) return;

        IMP current = method_getImplementation(method);
        if (!current) return;
        if (current == (IMP)TLGExactIsInteractive) {
            gExactCoreInstalled = YES;
            return;
        }

        gOriginalIsInteractive = current;
        const char *types = method_getTypeEncoding(method);

        // If the method is inherited, create an override on the concrete class.
        // If it belongs to the concrete class, replace its implementation.
        if (!class_addMethod(cls, sel, (IMP)TLGExactIsInteractive, types)) {
            method_setImplementation(method, (IMP)TLGExactIsInteractive);
        }

        gExactCoreInstalled = YES;
        NSLog(@"[TikTokLiquidGlass] exact Infinitok hook installed: TUXLiquidGlassConfiguration.isInteractive");
    }
}

static void ExactCoreImageAdded(const struct mach_header *mh, intptr_t slide) {
    (void)mh;
    (void)slide;
    dispatch_async(dispatch_get_main_queue(), ^{
        InstallExactLiquidGlassCore();
    });
}

__attribute__((constructor))
static void TikTokLiquidGlassExactCoreInit(void) {
    @autoreleasepool {
        InstallExactLiquidGlassCore();
        _dyld_register_func_for_add_image(ExactCoreImageAdded);

        // TUXSwiftBase can finish loading after our constructor in sideloaded builds.
        for (NSNumber *delay in @[@0.02, @0.05, @0.10, @0.20, @0.35, @0.75, @1.5, @3.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                InstallExactLiquidGlassCore();
            });
        }
    }
}
