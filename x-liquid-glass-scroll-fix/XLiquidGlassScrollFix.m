#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdatomic.h>

static NSString *const kXSFVersion = @"0.1";

static IMP gNextSetEffect = NULL;
static BOOL gInstalled = NO;
static _Atomic(uint64_t) gRelevantCalls = 0;
static _Atomic(uint64_t) gSuppressedCalls = 0;

static char kXSFStateKey;

@interface XSFEffectState : NSObject
@property (nonatomic, strong) UIVisualEffect *lastIncomingEffect;
@property (nonatomic, strong) UIVisualEffect *lastResultEffect;
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic, assign) UIUserInterfaceStyle interfaceStyle;
@property (nonatomic, assign) UIAccessibilityContrast accessibilityContrast;
@property (nonatomic, assign) UIUserInterfaceLevel interfaceLevel;
@end

@implementation XSFEffectState
@end

static NSString *XSFImageForIMP(IMP imp) {
    if (!imp) return @"-";
    Dl_info info = {0};
    if (!dladdr((const void *)imp, &info) || !info.dli_fname) return @"-";
    return [NSString stringWithUTF8String:info.dli_fname] ?: @"-";
}

static BOOL XSFStringContainsAny(NSString *value, NSArray<NSString *> *fragments) {
    if (!value.length) return NO;
    NSString *lower = value.lowercaseString;
    for (NSString *fragment in fragments) {
        if ([lower containsString:fragment.lowercaseString]) return YES;
    }
    return NO;
}

static BOOL XSFViewIsInLiquidGlassScrollPath(UIVisualEffectView *view) {
    if (!view) return NO;

    static NSArray<NSString *> *fragments;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fragments = @[
            @"XDSBlur",
            @"XDSGlass",
            @"ScrollEdgeEffectView",
            @"ScrollEdgeTreatment",
            @"LiquidLens",
            @"BackdropView"
        ];
    });

    UIView *cursor = view;
    for (NSUInteger depth = 0; cursor && depth < 10; depth++, cursor = cursor.superview) {
        NSString *className = NSStringFromClass(cursor.class);
        if (XSFStringContainsAny(className, fragments)) return YES;
    }

    UIResponder *responder = view.nextResponder;
    for (NSUInteger depth = 0; responder && depth < 5; depth++, responder = responder.nextResponder) {
        NSString *className = NSStringFromClass(responder.class);
        if (XSFStringContainsAny(className, fragments)) return YES;
    }

    return NO;
}

static XSFEffectState *XSFStateForView(UIVisualEffectView *view, BOOL create) {
    XSFEffectState *state = objc_getAssociatedObject(view, &kXSFStateKey);
    if (!state && create) {
        state = [XSFEffectState new];
        objc_setAssociatedObject(view,
                                 &kXSFStateKey,
                                 state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static BOOL XSFTraitsMatchState(UIVisualEffectView *view, XSFEffectState *state) {
    if (!view || !state) return NO;
    UITraitCollection *traits = view.traitCollection;
    return state.window == view.window &&
           state.interfaceStyle == traits.userInterfaceStyle &&
           state.accessibilityContrast == traits.accessibilityContrast &&
           state.interfaceLevel == traits.userInterfaceLevel;
}

static void XSFStoreState(UIVisualEffectView *view,
                          XSFEffectState *state,
                          UIVisualEffect *incoming) {
    if (!view || !state) return;
    UITraitCollection *traits = view.traitCollection;
    state.lastIncomingEffect = incoming;
    state.lastResultEffect = view.effect;
    state.window = view.window;
    state.interfaceStyle = traits.userInterfaceStyle;
    state.accessibilityContrast = traits.accessibilityContrast;
    state.interfaceLevel = traits.userInterfaceLevel;
}

static void XSFSetEffect(UIVisualEffectView *self,
                         SEL cmd,
                         UIVisualEffect *effect) {
    IMP next = gNextSetEffect;
    if (!next) return;

    if (!XSFViewIsInLiquidGlassScrollPath(self)) {
        ((void(*)(id,SEL,id))next)(self, cmd, effect);
        return;
    }

    atomic_fetch_add(&gRelevantCalls, 1);

    XSFEffectState *state = XSFStateForView(self, YES);

    // Strongest no-op case: UIKit is being asked to set the exact effect object
    // that is already installed. There is no visual state transition to perform.
    if (effect == self.effect && XSFTraitsMatchState(self, state)) {
        atomic_fetch_add(&gSuppressedCalls, 1);
        XSFStoreState(self, state, effect);
        return;
    }

    // Preserve the existing XLiquidGlass hook semantics. We suppress only when
    // the exact same input has already gone through that hook and the view still
    // has the exact result produced by that prior invocation, under the same
    // window + relevant trait environment.
    if (state.lastIncomingEffect == effect &&
        state.lastResultEffect == self.effect &&
        XSFTraitsMatchState(self, state)) {
        atomic_fetch_add(&gSuppressedCalls, 1);
        return;
    }

    ((void(*)(id,SEL,id))next)(self, cmd, effect);
    XSFStoreState(self, state, effect);
}

static BOOL XSFCurrentOwnerIsXLiquidGlass(IMP imp) {
    NSString *image = XSFImageForIMP(imp).lastPathComponent.lowercaseString;
    if (!image.length) return NO;
    if ([image containsString:@"xliquidglassscrollfix"]) return NO;
    return [image isEqualToString:@"xliquidglass.dylib"] ||
           [image containsString:@"xliquidglass"];
}

static void XSFInstallIfReady(void) {
    Class cls = UIVisualEffectView.class;
    SEL selector = @selector(setEffect:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;

    IMP current = class_getMethodImplementation(cls, selector);
    if (current == (IMP)XSFSetEffect) {
        gInstalled = YES;
        return;
    }

    // Do not hook UIKit directly and do not replace unrelated tweaks. This
    // overlay activates only after the existing XLiquidGlass hook is present.
    if (!XSFCurrentOwnerIsXLiquidGlass(current)) return;

    const char *types = method_getTypeEncoding(method);
    if (!types) return;

    gNextSetEffect = current;
    class_replaceMethod(cls, selector, (IMP)XSFSetEffect, types);
    gInstalled = class_getMethodImplementation(cls, selector) == (IMP)XSFSetEffect;

    if (gInstalled) {
        NSLog(@"[XLiquidGlassScrollFix] %@ installed above %@",
              kXSFVersion,
              XSFImageForIMP(gNextSetEffect).lastPathComponent ?: @"-");
    }
}

static void XSFLogSummary(void) {
    uint64_t relevant = atomic_load(&gRelevantCalls);
    uint64_t suppressed = atomic_load(&gSuppressedCalls);
    double percent = relevant ? (100.0 * (double)suppressed / (double)relevant) : 0.0;
    NSLog(@"[XLiquidGlassScrollFix] relevant=%llu suppressed=%llu (%.1f%%) installed=%d",
          (unsigned long long)relevant,
          (unsigned long long)suppressed,
          percent,
          gInstalled);
}

static void XSFScheduleInstall(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        XSFInstallIfReady();
    });
}

__attribute__((constructor))
static void XLiquidGlassScrollFixInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlassScrollFix] %@ loaded (conservative setEffect dedupe)",
              kXSFVersion);

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *notification) {
            XSFLogSummary();
        }];

        XSFInstallIfReady();
        XSFScheduleInstall(0.05);
        XSFScheduleInstall(0.20);
        XSFScheduleInstall(0.50);
        XSFScheduleInstall(1.00);
        XSFScheduleInstall(2.00);
        XSFScheduleInstall(4.00);
        XSFScheduleInstall(8.00);
    }
}
