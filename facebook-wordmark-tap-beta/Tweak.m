#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const void *FBWTapRecognizerKey = &FBWTapRecognizerKey;
static IMP FBWOriginalLayoutSubviews = NULL;
static BOOL FBWHookInstalled = NO;
static NSInteger FBWHookAttempts = 0;

@interface FBWTarget : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handleTap:(UITapGestureRecognizer *)recognizer;
@end

static UIViewController *FBWTopViewController(UIViewController *controller) {
    if (controller == nil) return nil;
    if (controller.presentedViewController != nil) {
        return FBWTopViewController(controller.presentedViewController);
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return FBWTopViewController(((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return FBWTopViewController(((UITabBarController *)controller).selectedViewController);
    }
    return controller;
}

@implementation FBWTarget

+ (instancetype)shared {
    static FBWTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [FBWTarget new];
    });
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

    UIWindow *window = recognizer.view.window;
    if (window == nil) return;

    UIViewController *presenter = FBWTopViewController(window.rootViewController);
    if (presenter == nil || presenter.presentedViewController != nil) return;

    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"iQFaceEnhancer Beta"
                                                                   message:@"Toque no wordmark do Facebook detectado com sucesso."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

@end

static BOOL FBWLooksLikeWordmarkContainer(UIView *view, UIView *navigationBar) {
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

static UIView *FBWFindWordmarkContainer(UIView *root, UIView *navigationBar) {
    UIView *best = nil;

    for (UIView *subview in root.subviews) {
        UIView *nested = FBWFindWordmarkContainer(subview, navigationBar);
        if (nested != nil) {
            best = nested;
        }

        if (FBWLooksLikeWordmarkContainer(subview, navigationBar)) {
            // Prefer the deepest matching plain UIView. The probe showed two
            // nested UIViews with the same ~128x52 frame; the deepest one is
            // the actual hit-test target for the Facebook wordmark.
            best = subview;
        }
    }

    return best;
}

static void FBWAttachRecognizerIfNeeded(UIView *navigationBar) {
    UIView *target = FBWFindWordmarkContainer(navigationBar, navigationBar);
    if (target == nil || objc_getAssociatedObject(target, FBWTapRecognizerKey) != nil) return;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:FBWTarget.shared
                                                                         action:@selector(handleTap:)];
    tap.numberOfTapsRequired = 1;
    tap.numberOfTouchesRequired = 1;
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    tap.delaysTouchesEnded = NO;
    tap.delegate = FBWTarget.shared;

    [target addGestureRecognizer:tap];
    objc_setAssociatedObject(target, FBWTapRecognizerKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void FBWNavigationBarLayoutSubviews(id self, SEL _cmd) {
    if (FBWOriginalLayoutSubviews != NULL) {
        ((void (*)(id, SEL))FBWOriginalLayoutSubviews)(self, _cmd);
    }

    if ([self isKindOfClass:UIView.class]) {
        FBWAttachRecognizerIfNeeded((UIView *)self);
    }
}

static BOOL FBWTryInstallHook(void) {
    if (FBWHookInstalled) return YES;

    Class navigationBarClass = NSClassFromString(@"FBNavigationBar");
    if (navigationBarClass == Nil) return NO;

    SEL selector = @selector(layoutSubviews);
    Method method = class_getInstanceMethod(navigationBarClass, selector);
    if (method == NULL) return NO;

    IMP current = method_getImplementation(method);
    if (current == (IMP)&FBWNavigationBarLayoutSubviews) {
        FBWHookInstalled = YES;
        return YES;
    }

    FBWOriginalLayoutSubviews = method_setImplementation(method, (IMP)&FBWNavigationBarLayoutSubviews);
    FBWHookInstalled = (FBWOriginalLayoutSubviews != NULL);
    return FBWHookInstalled;
}

static void FBWScheduleHookAttempt(void) {
    FBWHookAttempts += 1;
    if (FBWTryInstallHook()) return;
    if (FBWHookAttempts >= 120) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FBWScheduleHookAttempt();
    });
}

__attribute__((constructor))
static void FBWInitialize(void) {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleID isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            FBWScheduleHookAttempt();
        });
    }
}
