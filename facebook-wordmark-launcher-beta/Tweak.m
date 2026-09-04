#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static const void *IQFWBRecognizerKey = &IQFWBRecognizerKey;
static IMP IQFWBOriginalNavigationLayout = NULL;
static BOOL IQFWBNavigationHookInstalled = NO;
static BOOL IQFWBLongPressDisabled = NO;
static NSInteger IQFWBAttempts = 0;

typedef void (*IQFWBLauncherFunction)(void);

static IQFWBLauncherFunction IQFWBFindLauncher(void) {
    IQFWBLauncherFunction launcher = (IQFWBLauncherFunction)dlsym(RTLD_DEFAULT, "IQFPresentLauncherMenu");
    if (launcher == NULL) {
        launcher = (IQFWBLauncherFunction)dlsym(RTLD_DEFAULT, "_IQFPresentLauncherMenu");
    }
    return launcher;
}

static UIViewController *IQFWBTopViewController(UIViewController *controller) {
    if (controller == nil) return nil;
    if (controller.presentedViewController != nil && !controller.presentedViewController.isBeingDismissed) {
        return IQFWBTopViewController(controller.presentedViewController);
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return IQFWBTopViewController(((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return IQFWBTopViewController(((UITabBarController *)controller).selectedViewController);
    }
    return controller;
}

@interface IQFWBTarget : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handleTap:(UITapGestureRecognizer *)recognizer;
@end

@implementation IQFWBTarget

+ (instancetype)shared {
    static IQFWBTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [IQFWBTarget new];
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

    IQFWBLauncherFunction launcher = IQFWBFindLauncher();
    if (launcher != NULL) {
        dispatch_async(dispatch_get_main_queue(), ^{
            launcher();
        });
        return;
    }

    UIWindow *window = recognizer.view.window;
    UIViewController *presenter = IQFWBTopViewController(window.rootViewController);
    if (presenter == nil || presenter.presentedViewController != nil) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"iQFaceEnhancer Beta"
                                                                   message:@"IQFPresentLauncherMenu não foi encontrado."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

@end

static BOOL IQFWBLooksLikeWordmarkContainer(UIView *view, UIView *navigationBar) {
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

static UIView *IQFWBFindWordmarkContainer(UIView *root, UIView *navigationBar) {
    UIView *best = nil;
    for (UIView *subview in root.subviews) {
        if (IQFWBLooksLikeWordmarkContainer(subview, navigationBar)) {
            best = subview;
        }
        UIView *nested = IQFWBFindWordmarkContainer(subview, navigationBar);
        if (nested != nil) {
            best = nested;
        }
    }
    return best;
}

static void IQFWBAttachRecognizerIfNeeded(UIView *navigationBar) {
    UIView *target = IQFWBFindWordmarkContainer(navigationBar, navigationBar);
    if (target == nil || objc_getAssociatedObject(target, IQFWBRecognizerKey) != nil) return;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:IQFWBTarget.shared
                                                                         action:@selector(handleTap:)];
    tap.numberOfTapsRequired = 1;
    tap.numberOfTouchesRequired = 1;
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    tap.delaysTouchesEnded = NO;
    tap.delegate = IQFWBTarget.shared;
    [target addGestureRecognizer:tap];
    objc_setAssociatedObject(target, IQFWBRecognizerKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void IQFWBNavigationBarLayoutSubviews(id self, SEL _cmd) {
    if (IQFWBOriginalNavigationLayout != NULL) {
        ((void (*)(id, SEL))IQFWBOriginalNavigationLayout)(self, _cmd);
    }
    if ([self isKindOfClass:UIView.class]) {
        IQFWBAttachRecognizerIfNeeded((UIView *)self);
    }
}

static BOOL IQFWBInstallNavigationHook(void) {
    if (IQFWBNavigationHookInstalled) return YES;

    Class cls = NSClassFromString(@"FBNavigationBar");
    if (cls == Nil) return NO;

    Method method = class_getInstanceMethod(cls, @selector(layoutSubviews));
    if (method == NULL) return NO;

    IMP current = method_getImplementation(method);
    if (current == (IMP)&IQFWBNavigationBarLayoutSubviews) {
        IQFWBNavigationHookInstalled = YES;
        return YES;
    }

    IQFWBOriginalNavigationLayout = method_setImplementation(method, (IMP)&IQFWBNavigationBarLayoutSubviews);
    IQFWBNavigationHookInstalled = (IQFWBOriginalNavigationLayout != NULL);
    return IQFWBNavigationHookInstalled;
}

static void IQFWBNoLongPress(id self, SEL _cmd, id recognizer) {
    (void)self;
    (void)_cmd;
    (void)recognizer;
}

static BOOL IQFWBDisableEnhancerLongPress(void) {
    if (IQFWBLongPressDisabled) return YES;

    Class targetClass = NSClassFromString(@"IQFEnhancerGestureTarget");
    if (targetClass == Nil) return NO;

    Method method = class_getInstanceMethod(targetClass, NSSelectorFromString(@"handleLongPress:"));
    if (method == NULL) return NO;

    method_setImplementation(method, (IMP)&IQFWBNoLongPress);
    IQFWBLongPressDisabled = YES;
    return YES;
}

static void IQFWBTryInstall(void) {
    IQFWBAttempts += 1;
    BOOL navReady = IQFWBInstallNavigationHook();
    BOOL oldActivationDisabled = IQFWBDisableEnhancerLongPress();

    if (navReady && oldActivationDisabled) return;
    if (IQFWBAttempts >= 160) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IQFWBTryInstall();
    });
}

__attribute__((constructor))
static void IQFWBInitialize(void) {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleID isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            IQFWBTryInstall();
        });
    }
}
