#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

__attribute__((visibility("default"))) NSString * const IQFEnhancerVersion = @"2.0";

typedef void (*IQFPresentSettingsFunction)(void);
typedef BOOL (*IQFSettingsVisibleFunction)(void);

static NSTimeInterval IQFLastPresentationTime = 0;
static BOOL IQFScannerStarted = NO;

#pragma mark - iQFace settings

static void *IQFFindSymbol(const char *name) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol != NULL) return symbol;

    char underscored[128] = {0};
    underscored[0] = '_';
    strlcpy(underscored + 1, name, sizeof(underscored) - 1);
    return dlsym(RTLD_DEFAULT, underscored);
}

static BOOL IQFSettingsAreVisible(void) {
    IQFSettingsVisibleFunction visible = (IQFSettingsVisibleFunction)IQFFindSymbol("IQFSettingsVisible");
    return visible != NULL && visible();
}

static void IQFOpenSettings(void) {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - IQFLastPresentationTime < 0.9 || IQFSettingsAreVisible()) return;

    IQFPresentSettingsFunction present = (IQFPresentSettingsFunction)IQFFindSymbol("IQFPresentSettings");
    if (present == NULL) return;

    IQFLastPresentationTime = now;
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];
    present();
}

#pragma mark - Proven iQFace button scanner

static BOOL IQFIsTopSettingsButton(UIView *view) {
    if (![view isKindOfClass:UIButton.class]) return NO;

    UIButton *button = (UIButton *)view;
    if (![button.accessibilityLabel isEqualToString:@"iQFace"]) return NO;

    for (id target in button.allTargets) {
        NSArray<NSString *> *actions = [button actionsForTarget:target forControlEvent:UIControlEventTouchUpInside];
        if ([actions containsObject:@"iqf_tapped"]) return YES;
    }
    return NO;
}

static void IQFSafeScanView(UIView *view) {
    if (view == nil) return;

    for (UIView *subview in view.subviews.copy) {
        if (IQFIsTopSettingsButton(subview)) {
            [subview removeFromSuperview];
            continue;
        }
        IQFSafeScanView(subview);
    }
}

static void IQFSafeScanWindows(void) {
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        IQFSafeScanView(window);
    }
}

static void IQFScheduleSafeScan(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IQFSafeScanWindows();
        IQFScheduleSafeScan();
    });
}

static void IQFStartSafeScanner(void) {
    if (IQFScannerStarted) return;
    IQFScannerStarted = YES;
    IQFSafeScanWindows();
    IQFScheduleSafeScan();
}

#pragma mark - Facebook wordmark activation

static const void *IQFWordmarkRecognizerKey = &IQFWordmarkRecognizerKey;
static IMP IQFWordmarkOriginalLayoutSubviews = NULL;
static BOOL IQFWordmarkHookInstalled = NO;
static NSInteger IQFWordmarkHookAttempts = 0;

@interface IQFWordmarkTarget : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedTarget;
- (void)handleTap:(UITapGestureRecognizer *)recognizer;
@end

@implementation IQFWordmarkTarget

+ (instancetype)sharedTarget {
    static IQFWordmarkTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [IQFWordmarkTarget new]; });
    return target;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return YES;
}

- (void)handleTap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded) return;
    dispatch_async(dispatch_get_main_queue(), ^{ IQFOpenSettings(); });
}

@end

static BOOL IQFLooksLikeFacebookWordmarkContainer(UIView *view, UIView *navigationBar) {
    if (view == nil || navigationBar == nil || view == navigationBar) return NO;
    if (![NSStringFromClass(view.class) isEqualToString:@"UIView"]) return NO;
    if (view.hidden || view.alpha < 0.01 || !view.userInteractionEnabled) return NO;

    CGRect rect = [view convertRect:view.bounds toView:navigationBar];
    CGFloat navWidth = CGRectGetWidth(navigationBar.bounds);
    CGFloat navHeight = CGRectGetHeight(navigationBar.bounds);
    if (navWidth <= 0.0 || navHeight <= 0.0) return NO;

    BOOL leftRegion = rect.origin.x >= 28.0 && rect.origin.x <= 64.0;
    BOOL topAligned = fabs(rect.origin.y) <= 3.0;
    BOOL expectedWidth = rect.size.width >= 95.0 && rect.size.width <= 180.0;
    BOOL fullHeight = rect.size.height >= navHeight * 0.82 && rect.size.height <= navHeight * 1.18;
    return leftRegion && topAligned && expectedWidth && fullHeight;
}

static UIView *IQFFindFacebookWordmarkContainer(UIView *root, UIView *navigationBar) {
    UIView *best = nil;
    for (UIView *subview in root.subviews) {
        UIView *nested = IQFFindFacebookWordmarkContainer(subview, navigationBar);
        if (nested != nil) best = nested;
        if (IQFLooksLikeFacebookWordmarkContainer(subview, navigationBar)) best = subview;
    }
    return best;
}

static void IQFAttachWordmarkTapIfNeeded(UIView *navigationBar) {
    UIView *target = IQFFindFacebookWordmarkContainer(navigationBar, navigationBar);
    if (target == nil || objc_getAssociatedObject(target, IQFWordmarkRecognizerKey) != nil) return;

    UITapGestureRecognizer *recognizer = [[UITapGestureRecognizer alloc]
        initWithTarget:IQFWordmarkTarget.sharedTarget
                action:@selector(handleTap:)];
    recognizer.numberOfTapsRequired = 1;
    recognizer.numberOfTouchesRequired = 1;
    recognizer.cancelsTouchesInView = NO;
    recognizer.delaysTouchesBegan = NO;
    recognizer.delaysTouchesEnded = NO;
    recognizer.delegate = IQFWordmarkTarget.sharedTarget;
    [target addGestureRecognizer:recognizer];
    objc_setAssociatedObject(target, IQFWordmarkRecognizerKey, recognizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void IQFWordmarkNavigationBarLayoutSubviews(id self, SEL command) {
    if (IQFWordmarkOriginalLayoutSubviews != NULL) {
        ((void (*)(id, SEL))IQFWordmarkOriginalLayoutSubviews)(self, command);
    }
    if ([self isKindOfClass:UIView.class]) IQFAttachWordmarkTapIfNeeded((UIView *)self);
}

static BOOL IQFTryInstallWordmarkHook(void) {
    if (IQFWordmarkHookInstalled) return YES;

    Class navigationBarClass = NSClassFromString(@"FBNavigationBar");
    if (navigationBarClass == Nil) return NO;

    Method method = class_getInstanceMethod(navigationBarClass, @selector(layoutSubviews));
    if (method == NULL) return NO;

    IMP current = method_getImplementation(method);
    if (current == (IMP)&IQFWordmarkNavigationBarLayoutSubviews) {
        IQFWordmarkHookInstalled = YES;
        return YES;
    }

    IQFWordmarkOriginalLayoutSubviews = method_setImplementation(method, (IMP)&IQFWordmarkNavigationBarLayoutSubviews);
    IQFWordmarkHookInstalled = IQFWordmarkOriginalLayoutSubviews != NULL;
    return IQFWordmarkHookInstalled;
}

static void IQFScheduleWordmarkHook(void) {
    IQFWordmarkHookAttempts += 1;
    if (IQFTryInstallWordmarkHook() || IQFWordmarkHookAttempts >= 120) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ IQFScheduleWordmarkHook(); });
}

static void IQFApplicationDidBecomeActive(NSNotification *notification) {
    (void)notification;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ IQFSafeScanWindows(); });
}

__attribute__((constructor))
static void IQFEnhancerInitialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) return;

        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *notification) {
            IQFApplicationDidBecomeActive(notification);
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            IQFStartSafeScanner();
            IQFScheduleWordmarkHook();
        });
    }
}
