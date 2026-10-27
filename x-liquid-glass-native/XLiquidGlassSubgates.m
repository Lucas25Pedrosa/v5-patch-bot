#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

// GlassX 3.1 Beta 2 — surgical Liquid Glass subgates for X 12.38 build 24.
// Important: never scan every runtime class by selector name. Generic selectors such as
// isRedesignEnabled exist in unrelated X features (Super Follows, Rewards, Drafts).
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

static BOOL XLGHookExactSelector(Class cls,
                                 NSString *logicalClassName,
                                 NSString *selectorName,
                                 BOOL classMethod,
                                 NSUInteger expectedArgumentCount) {
    if (!cls || !selectorName.length) return NO;

    SEL sel = NSSelectorFromString(selectorName);
    Class target = classMethod ? object_getClass(cls) : cls;
    if (!target) return NO;

    Method method = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    if (!XLGMethodReturnsBool(method)) return NO;
    if (method_getNumberOfArguments(method) != expectedArgumentCount) return NO;

    IMP replacement = expectedArgumentCount == 2 ? (IMP)XLGForceYES0 : (IMP)XLGForceYES1;
    IMP current = class_getMethodImplementation(target, sel);
    if (current == replacement) return YES;

    class_replaceMethod(target, sel, replacement, method_getTypeEncoding(method));
    BOOL installed = class_getMethodImplementation(target, sel) == replacement;
    if (installed) {
        NSLog(@"[GlassX] 3.1-beta2 surgical=YES class=%@ runtime=%@ kind=%@ selector=%@",
              logicalClassName ?: @"?",
              NSStringFromClass(cls) ?: @"?",
              classMethod ? @"class" : @"instance",
              selectorName);
    }
    return installed;
}

static Class XLGFirstExistingClass(NSArray<NSString *> *names, NSString **resolvedName) {
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (cls) {
            if (resolvedName) *resolvedName = name;
            return cls;
        }
    }
    if (resolvedName) *resolvedName = nil;
    return Nil;
}

static NSUInteger XLGInstallLiquidGlassFeaturesHooks(void) {
    NSString *resolved = nil;
    Class cls = XLGFirstExistingClass(@[
        @"T1TwitterSwift.LiquidGlassRedesignFeatures",
        @"_TtC14T1TwitterSwift27LiquidGlassRedesignFeatures"
    ], &resolved);
    if (!cls) {
        NSLog(@"[GlassX] 3.1-beta2 class-missing logical=LiquidGlassRedesignFeatures");
        return 0;
    }

    NSUInteger hooked = 0;
    NSArray<NSString *> *noArg = @[
        @"isRedesignEnabled",
        @"isPushChromeSnapEnabled"
    ];
    NSArray<NSString *> *oneArg = @[
        @"isAvatarBadgeEnabledWithFeatureSwitches:",
        @"isQuickComposerEnabledWithFeatureSwitches:",
        @"isQuickComposerEnabledNoImpressionWithFeatureSwitches:"
    ];

    for (NSString *selector in noArg) {
        if (XLGHookExactSelector(cls, resolved, selector, NO, 2)) hooked++;
        if (XLGHookExactSelector(cls, resolved, selector, YES, 2)) hooked++;
    }
    for (NSString *selector in oneArg) {
        if (XLGHookExactSelector(cls, resolved, selector, NO, 3)) hooked++;
        if (XLGHookExactSelector(cls, resolved, selector, YES, 3)) hooked++;
    }
    return hooked;
}

static NSUInteger XLGInstallXChatHooks(void) {
    NSString *resolved = nil;
    Class cls = XLGFirstExistingClass(@[
        @"ChatFeatureSwitches.ChatFeatureSwitchesImpl",
        @"_TtC19ChatFeatureSwitches23ChatFeatureSwitchesImpl"
    ], &resolved);
    if (!cls) {
        NSLog(@"[GlassX] 3.1-beta2 class-missing logical=ChatFeatureSwitchesImpl");
        return 0;
    }

    NSUInteger hooked = 0;
    NSArray<NSString *> *selectors = @[
        @"liquidGlassConvoHeaderEnabled",
        @"isLiquidGlassConvoHeaderEnabled",
        @"liquidGlassRedesignEnabled",
        @"isLiquidGlassRedesignEnabled"
    ];
    for (NSString *selector in selectors) {
        if (XLGHookExactSelector(cls, resolved, selector, NO, 2)) hooked++;
        if (XLGHookExactSelector(cls, resolved, selector, YES, 2)) hooked++;
    }
    return hooked;
}

static void XLGForceKnownSubgateDefaults(void) {
    if (!XLGSubgatesEnabled()) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in XLGKnownSubgateKeys()) {
        [defaults setBool:YES forKey:key];
    }
}

static void XLGInstallSurgicalSubgates(NSString *reason) {
    if (!XLGSubgatesEnabled()) return;

    XLGForceKnownSubgateDefaults();
    NSUInteger liquidGlass = XLGInstallLiquidGlassFeaturesHooks();
    NSUInteger xchat = XLGInstallXChatHooks();

    // Grok: X 12.38 build 24 exposes declaresGlassComposer, but its owning class has not
    // yet been proven. Beta 2 deliberately does NOT globally hook that generic selector.
    // This prevents the Beta 1 class-collision bug from returning under another name.
    NSLog(@"[GlassX] 3.1-beta2 surgical-pass reason=%@ liquidGlass=%lu xchat=%lu grok=owner-unverified",
          reason ?: @"?",
          (unsigned long)liquidGlass,
          (unsigned long)xchat);
}

@interface XLiquidGlassSubgateBootstrap : NSObject
@end

@implementation XLiquidGlassSubgateBootstrap

+ (void)load {
    @autoreleasepool {
        if (!XLGSubgatesEnabled()) return;

        XLGInstallSurgicalSubgates(@"objc-load");

        // Swift classes can materialize after the tweak constructor. Re-check only the
        // exact allowlisted classes; there is no runtime-wide selector scan in Beta 2.
        NSArray<NSNumber *> *delays = @[
            @0.00, @0.05, @0.15, @0.35, @0.70,
            @1.20, @2.00, @3.50, @5.00, @8.00
        ];
        for (NSNumber *delay in delays) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    XLGInstallSurgicalSubgates(
                        [NSString stringWithFormat:@"retry-%.2f", delay.doubleValue]
                    );
                }
            );
        }
    }
}

@end
