#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <limits.h>

static IMP gNextLayoutSubviews = NULL;
static BOOL gHookInstalled = NO;
static _Atomic(uint64_t) gRunLoopGeneration = 1;
static _Atomic(uint64_t) gEligibleCalls = 0;
static _Atomic(uint64_t) gSuppressedCalls = 0;
static _Atomic(uint64_t) gThrottleSuppressed = 0;
static _Atomic(uint64_t) gDuplicateSuppressed = 0;
static CFRunLoopObserverRef gRunLoopObserver = NULL;
static const CFTimeInterval kXCFActiveScrollInterval = (1.0 / 60.0);

@interface XCFLayoutState : NSObject
@property (nonatomic) BOOL hasSignature;
@property (nonatomic) uint64_t generation;
@property (nonatomic) CGRect frame;
@property (nonatomic) CGRect bounds;
@property (nonatomic) CGPoint contentOffset;
@property (nonatomic) CGSize contentSize;
@property (nonatomic) UIEdgeInsets adjustedInset;
@property (nonatomic) CGAffineTransform transform;
@property (nonatomic) CGFloat alpha;
@property (nonatomic) BOOL hidden;
@property (nonatomic) UIUserInterfaceStyle style;
@property (nonatomic) UIAccessibilityContrast contrast;
@property (nonatomic) UIUserInterfaceLevel level;
@property (nonatomic, weak) UIWindow *window;
@property (nonatomic) NSUInteger subviewCount;
@property (nonatomic) CFTimeInterval nextForwardTime;
@end

@implementation XCFLayoutState
@end

static const void *kXCFLayoutStateKey = &kXCFLayoutStateKey;

static NSString *XCFImageForIMP(IMP imp) {
    if (!imp) return @"-";
    Dl_info info = {0};
    if (!dladdr((const void *)imp, &info) || !info.dli_fname) return @"-";
    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
    return path.lastPathComponent ?: path ?: @"-";
}

static BOOL XCFNameEquals(id object, NSString *name) {
    if (!object || !name.length) return NO;
    return [NSStringFromClass([object class]) isEqualToString:name];
}

static BOOL XCFCommentsContext(UIView *target, UIScrollView **scrollOut) {
    if (!target) return NO;

    BOOL hasURT = NO;
    BOOL hasConversation = NO;
    UIResponder *responder = target;
    for (NSUInteger i = 0; responder && i < 32; i++) {
        if ([responder isKindOfClass:UIViewController.class]) {
            NSString *name = NSStringFromClass([responder class]);
            if ([name isEqualToString:@"T1URTViewController"]) hasURT = YES;
            if ([name isEqualToString:@"T1ConversationContainerViewController"]) hasConversation = YES;
        }
        responder = responder.nextResponder;
    }

    UIScrollView *table = nil;
    UIView *cursor = target.superview;
    for (NSUInteger i = 0; cursor && i < 20; i++, cursor = cursor.superview) {
        if ([cursor isKindOfClass:UIScrollView.class] && XCFNameEquals(cursor, @"TFNTableView")) {
            table = (UIScrollView *)cursor;
            break;
        }
    }

    if (scrollOut) *scrollOut = table;
    return hasURT && hasConversation && table != nil;
}

static BOOL XCFInsetsEqual(UIEdgeInsets a, UIEdgeInsets b) {
    return a.top == b.top && a.left == b.left && a.bottom == b.bottom && a.right == b.right;
}

static BOOL XCFStructuralSignatureMatches(XCFLayoutState *state, UIView *target, UIScrollView *scroll) {
    if (!state.hasSignature) return NO;
    if (state.window != target.window) return NO;
    if (!CGRectEqualToRect(state.frame, target.frame)) return NO;
    if (!CGRectEqualToRect(state.bounds, target.bounds)) return NO;
    if (!CGSizeEqualToSize(state.contentSize, scroll.contentSize)) return NO;
    if (!XCFInsetsEqual(state.adjustedInset, scroll.adjustedContentInset)) return NO;
    if (!CGAffineTransformEqualToTransform(state.transform, target.transform)) return NO;
    if (state.alpha != target.alpha || state.hidden != target.hidden) return NO;
    if (state.subviewCount != target.subviews.count) return NO;

    UITraitCollection *traits = target.traitCollection;
    if (state.style != traits.userInterfaceStyle) return NO;
    if (@available(iOS 13.0, *)) {
        if (state.contrast != traits.accessibilityContrast) return NO;
        if (state.level != traits.userInterfaceLevel) return NO;
    }
    return YES;
}

static BOOL XCFExactDuplicateInGeneration(XCFLayoutState *state, UIScrollView *scroll, uint64_t generation) {
    return state.hasSignature &&
           state.generation == generation &&
           CGPointEqualToPoint(state.contentOffset, scroll.contentOffset);
}

static void XCFStoreSignature(XCFLayoutState *state, UIView *target, UIScrollView *scroll, uint64_t generation) {
    state.hasSignature = YES;
    state.generation = generation;
    state.frame = target.frame;
    state.bounds = target.bounds;
    state.contentOffset = scroll.contentOffset;
    state.contentSize = scroll.contentSize;
    state.adjustedInset = scroll.adjustedContentInset;
    state.transform = target.transform;
    state.alpha = target.alpha;
    state.hidden = target.hidden;
    state.window = target.window;
    state.subviewCount = target.subviews.count;

    UITraitCollection *traits = target.traitCollection;
    state.style = traits.userInterfaceStyle;
    if (@available(iOS 13.0, *)) {
        state.contrast = traits.accessibilityContrast;
        state.level = traits.userInterfaceLevel;
    }
}

static void XCFAdvance60HzSchedule(XCFLayoutState *state, CFTimeInterval now) {
    if (state.nextForwardTime <= 0.0 || now - state.nextForwardTime > 0.250) {
        state.nextForwardTime = now + kXCFActiveScrollInterval;
        return;
    }
    do {
        state.nextForwardTime += kXCFActiveScrollInterval;
    } while (state.nextForwardTime <= now);
}

static void XCFLayoutSubviews(id self, SEL cmd) {
    if (![self isKindOfClass:UIView.class] || ![NSThread isMainThread]) {
        if (gNextLayoutSubviews) ((void(*)(id, SEL))gNextLayoutSubviews)(self, cmd);
        return;
    }

    UIView *target = (UIView *)self;
    UIScrollView *scroll = nil;
    if (!XCFCommentsContext(target, &scroll)) {
        if (gNextLayoutSubviews) ((void(*)(id, SEL))gNextLayoutSubviews)(self, cmd);
        return;
    }

    atomic_fetch_add(&gEligibleCalls, 1);
    uint64_t generation = atomic_load(&gRunLoopGeneration);
    XCFLayoutState *state = objc_getAssociatedObject(self, kXCFLayoutStateKey);
    if (!state) {
        state = [XCFLayoutState new];
        objc_setAssociatedObject(self, kXCFLayoutStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    BOOL structuralSame = XCFStructuralSignatureMatches(state, target, scroll);
    BOOL activeScroll = scroll.isTracking || scroll.isDragging || scroll.isDecelerating;
    CFTimeInterval now = CACurrentMediaTime();

    // Beta 2 strategy:
    // - Outside active scrolling, retain the very conservative same-runloop dedupe.
    // - During active comment scrolling, only when geometry/traits/window/subtree
    //   are unchanged, cap this decorative ScrollEdgeTreatment path to an
    //   average of 60 forwards/s. The TFNTableView itself remains untouched and
    //   can continue scrolling at ProMotion rates.
    // - Any structural change bypasses the throttle immediately.
    if (structuralSame) {
        if (activeScroll) {
            if (state.nextForwardTime > 0.0 && now < state.nextForwardTime) {
                atomic_fetch_add(&gSuppressedCalls, 1);
                atomic_fetch_add(&gThrottleSuppressed, 1);
                return;
            }
        } else if (XCFExactDuplicateInGeneration(state, scroll, generation)) {
            atomic_fetch_add(&gSuppressedCalls, 1);
            atomic_fetch_add(&gDuplicateSuppressed, 1);
            return;
        }
    } else {
        // Structural changes must never inherit a stale throttle deadline.
        state.nextForwardTime = 0.0;
    }

    if (gNextLayoutSubviews) ((void(*)(id, SEL))gNextLayoutSubviews)(self, cmd);
    XCFStoreSignature(state, target, scroll, generation);

    if (activeScroll) {
        XCFAdvance60HzSchedule(state, now);
    } else {
        state.nextForwardTime = 0.0;
    }
}

static void XCFRunLoopCallback(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    atomic_fetch_add(&gRunLoopGeneration, 1);
}

static void XCFInstallRunLoopObserver(void) {
    if (gRunLoopObserver || ![NSThread isMainThread]) return;
    CFRunLoopObserverContext context = {0, NULL, NULL, NULL, NULL};
    gRunLoopObserver = CFRunLoopObserverCreate(kCFAllocatorDefault,
                                               kCFRunLoopBeforeWaiting | kCFRunLoopExit,
                                               true,
                                               INT_MAX,
                                               XCFRunLoopCallback,
                                               &context);
    if (gRunLoopObserver) CFRunLoopAddObserver(CFRunLoopGetMain(), gRunLoopObserver, kCFRunLoopCommonModes);
}

static void XCFInstallHook(void) {
    Class cls = NSClassFromString(@"XDesignSystem.ScrollEdgeTreatment");
    if (!cls) return;

    SEL sel = @selector(layoutSubviews);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;

    IMP current = class_getMethodImplementation(cls, sel);
    if (!current) return;
    if (current == (IMP)XCFLayoutSubviews) {
        gHookInstalled = YES;
        return;
    }

    NSString *owner = XCFImageForIMP(current);
    if (![owner containsString:@"XLiquidGlass"] || [owner containsString:@"CommentsScrollFix"]) return;

    gNextLayoutSubviews = current;
    class_replaceMethod(cls, sel, (IMP)XCFLayoutSubviews, method_getTypeEncoding(method));
    gHookInstalled = (class_getMethodImplementation(cls, sel) == (IMP)XCFLayoutSubviews);
    if (gHookInstalled) {
        NSLog(@"[XLiquidGlassCommentsScrollFix] 0.2 Beta 2 installed over %@", owner);
    }
}

static void XCFScheduleInstall(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XCFInstallRunLoopObserver();
        XCFInstallHook();
    });
}

static void XCFLogStats(void) {
    uint64_t eligible = atomic_load(&gEligibleCalls);
    uint64_t suppressed = atomic_load(&gSuppressedCalls);
    uint64_t throttled = atomic_load(&gThrottleSuppressed);
    uint64_t duplicates = atomic_load(&gDuplicateSuppressed);
    double pct = eligible ? (100.0 * (double)suppressed / (double)eligible) : 0.0;
    NSLog(@"[XLiquidGlassCommentsScrollFix] eligible=%llu suppressed=%llu (%.1f%%) throttle=%llu duplicate=%llu",
          (unsigned long long)eligible,
          (unsigned long long)suppressed,
          pct,
          (unsigned long long)throttled,
          (unsigned long long)duplicates);
}

__attribute__((constructor))
static void XLiquidGlassCommentsScrollFixInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlassCommentsScrollFix] 0.2 Beta 2 loaded");
        dispatch_async(dispatch_get_main_queue(), ^{
            XCFInstallRunLoopObserver();
            XCFInstallHook();
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                              object:nil
                                                               queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(__unused NSNotification *note) {
                XCFLogStats();
            }];
        });
        for (NSNumber *delay in @[@0.05, @0.20, @0.50, @1.0, @2.0, @4.0, @8.0]) {
            XCFScheduleInstall(delay.doubleValue);
        }
    }
}
