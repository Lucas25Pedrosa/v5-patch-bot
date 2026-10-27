#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

// GlassX 3.1 Experimental
// X 12.38 build 24 — force all known Liquid Glass secondary gates.
// The validated global gate remains owned by XLiquidGlass1238Engine.m.

static NSString *const kXLGEnabledKey = @"XLiquidGlassEnabled";

static BOOL XLGSubgatesEnabled(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kXLGEnabledKey];
    return stored ? [stored boolValue] : YES;
}

static NSArray<NSString *> *XLGKnownSubgateKeys(void) {
    return @[
        @"ios_liquid_glass_redesign_enabled",
        @"ios_liquid_glass_redesign_quick_composer_enabled",
        @"ios_liquid_glass_avatar_badge_enabled",
        @"ios_liquid_glass_push_chrome_snap_enabled",
        @"xchat_liquid_glass_convo_header_enabled",
        @"T1LiquidGlassRedesignPersistedGate"
    ];
}

static NSArray<NSString *> *XLGNoArgumentSelectors(void) {
    return @[
        @"isRedesignEnabled",
        @"isPushChromeSnapEnabled",
        @"liquidGlassConvoHeaderEnabled",
        @"isLiquidGlassConvoHeaderEnabled",
        @"liquidGlassRedesignEnabled",
        @"isLiquidGlassRedesignEnabled",
        @"declaresGlassComposer"
    ];
}

static NSArray<NSString *> *XLGOneArgumentSelectors(void) {
    return @[
        @"isAvatarBadgeEnabledWithFeatureSwitches:",
        @"isQuickComposerEnabledWithFeatureSwitches:",
        @"isQuickComposerEnabledNoImpressionWithFeatureSwitches:"
    ];
}

static BOOL XLGForceYES0(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return YES;
}

static BOOL XLGForceYES1(id self, SEL _cmd, id featureSwitches) {
    (void)self;
    (void)_cmd;
    (void)featureSwitches;
    return YES;
}

static BOOL XLGMethodReturnsBool(Method method) {
    if (!method) return NO;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return returnType[0] == 'B' || returnType[0] == 'c' || returnType[0] == 'C';
}

static BOOL XLGSelectorIsKnown(SEL sel, NSArray<NSString *> *names) {
    if (!sel) return NO;
    return [names containsObject:NSStringFromSelector(sel)];
}

static NSUInteger XLGHookMethodList(Class target,
                                    NSString *ownerName,
                                    BOOL classMethods,
                                    NSArray<NSString *> *noArgument,
                                    NSArray<NSString *> *oneArgument) {
    if (!target) return 0;

    unsigned count = 0;
    Method *methods = class_copyMethodList(target, &count);
    if (!methods) return 0;

    NSUInteger hooked = 0;
    for (unsigned i = 0; i < count; i++) {
        Method method = methods[i];
        SEL sel = method_getName(method);
        if (!XLGMethodReturnsBool(method)) continue;

        IMP replacement = NULL;
        if (XLGSelectorIsKnown(sel, noArgument) && method_getNumberOfArguments(method) == 2) {
            replacement = (IMP)XLGForceYES0;
        } else if (XLGSelectorIsKnown(sel, oneArgument) && method_getNumberOfArguments(method) == 3) {
            replacement = (IMP)XLGForceYES1;
        } else {
            continue;
        }

        IMP current = method_getImplementation(method);
        if (current == replacement) continue;

        class_replaceMethod(target, sel, replacement, method_getTypeEncoding(method));
        if (class_getMethodImplementation(target, sel) == replacement) {
            hooked++;
            NSLog(@"[GlassX] 3.1 subgate=YES class=%@ kind=%@ selector=%@",
                  ownerName,
                  classMethods ? @"class" : @"instance",
                  NSStringFromSelector(sel));
        }
    }

    free(methods);
    return hooked;
}

static NSUInteger XLGInstallKnownSubgateHooks(void) {
    if (!XLGSubgatesEnabled()) return 0;

    NSArray<NSString *> *noArgument = XLGNoArgumentSelectors();
    NSArray<NSString *> *oneArgument = XLGOneArgumentSelectors();

    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return 0;

    __unsafe_unretained Class *classes = (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
    if (!classes) return 0;

    classCount = objc_getClassList(classes, classCount);
    NSUInteger hooked = 0;

    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        if (!cls) continue;
        NSString *name = NSStringFromClass(cls) ?: @"?";

        hooked += XLGHookMethodList(cls, name, NO, noArgument, oneArgument);

        Class meta = object_getClass(cls);
        if (meta) hooked += XLGHookMethodList(meta, name, YES, noArgument, oneArgument);
    }

    free(classes);
    return hooked;
}

static void XLGForceKnownSubgateDefaults(void) {
    if (!XLGSubgatesEnabled()) return;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in XLGKnownSubgateKeys()) {
        [defaults setBool:YES forKey:key];
    }
}

static void XLGInstallAllSubgates(NSString *reason) {
    if (!XLGSubgatesEnabled()) return;

    XLGForceKnownSubgateDefaults();
    NSUInteger hooked = XLGInstallKnownSubgateHooks();
    NSLog(@"[GlassX] 3.1 all-subgates pass reason=%@ hooked=%lu",
          reason ?: @"?", (unsigned long)hooked);
}

@interface XLiquidGlassSubgateBootstrap : NSObject
@end

@implementation XLiquidGlassSubgateBootstrap

+ (void)load {
    @autoreleasepool {
        if (!XLGSubgatesEnabled()) return;

        XLGInstallAllSubgates(@"objc-load");

        // XChat/Grok/T1Twitter Swift classes may materialize slightly later.
        NSArray<NSNumber *> *delays = @[
            @0.00, @0.05, @0.15, @0.35, @0.70,
            @1.20, @2.00, @3.50, @5.00
        ];
        for (NSNumber *delay in delays) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    XLGInstallAllSubgates(
                        [NSString stringWithFormat:@"retry-%.2f", delay.doubleValue]
                    );
                }
            );
        }
    }
}

@end
