#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern void IQFOpenSettings(void);

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
    dispatch_once(&onceToken, ^{
        target = [IQFWordmarkTarget new];
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
    if (recognizer.state != UIGestureRecognizerStateEnded) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        IQFOpenSettings();
    });
}

@end

static BOOL IQFLooksLikeFacebookWordmarkContainer(UIView *view, UIView *navigationBar) {
    if (view == nil || navigationBar == nil || view == navigationBar) {
        return NO;
    }
    if (![NSStringFromClass(view.class) isEqualToString:@"UIView"]) {
        return NO;
    }
    if (view.hidden || view.alpha < 0.01 || !view.userInteractionEnabled) {
        return NO;
    }

    CGRect rect = [view convertRect:view.bounds toView:navigationBar];
    CGFloat navWidth = CGRectGetWidth(navigationBar.bounds);
    CGFloat navHeight = CGRectGetHeight(navigationBar.bounds);
    if (navWidth <= 0.0 || navHeight <= 0.0) {
        return NO;
    }

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
        if (nested != nil) {
            best = nested;
        }
        if (IQFLooksLikeFacebookWordmarkContainer(subview, navigationBar)) {
            best = subview;
        }
    }
    return best;
}

static void IQFAttachWordmarkTapIfNeeded(UIView *navigationBar) {
    UIView *target = IQFFindFacebookWordmarkContainer(navigationBar, navigationBar);
    if (target == nil || objc_getAssociatedObject(target, IQFWordmarkRecognizerKey) != nil) {
        return;
    }

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
    objc_setAssociatedObject(target,
                             IQFWordmarkRecognizerKey,
                             recognizer,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void IQFWordmarkNavigationBarLayoutSubviews(id self, SEL command) {
    if (IQFWordmarkOriginalLayoutSubviews != NULL) {
        ((void (*)(id, SEL))IQFWordmarkOriginalLayoutSubviews)(self, command);
    }
    if ([self isKindOfClass:UIView.class]) {
        IQFAttachWordmarkTapIfNeeded((UIView *)self);
    }
}

static BOOL IQFTryInstallWordmarkHook(void) {
    if (IQFWordmarkHookInstalled) {
        return YES;
    }

    Class navigationBarClass = NSClassFromString(@"FBNavigationBar");
    if (navigationBarClass == Nil) {
        return NO;
    }

    Method method = class_getInstanceMethod(navigationBarClass, @selector(layoutSubviews));
    if (method == NULL) {
        return NO;
    }

    IMP current = method_getImplementation(method);
    if (current == (IMP)&IQFWordmarkNavigationBarLayoutSubviews) {
        IQFWordmarkHookInstalled = YES;
        return YES;
    }

    IQFWordmarkOriginalLayoutSubviews = method_setImplementation(method, (IMP)&IQFWordmarkNavigationBarLayoutSubviews);
    IQFWordmarkHookInstalled = (IQFWordmarkOriginalLayoutSubviews != NULL);
    return IQFWordmarkHookInstalled;
}

static void IQFScheduleWordmarkHook(void) {
    IQFWordmarkHookAttempts += 1;
    if (IQFTryInstallWordmarkHook() || IQFWordmarkHookAttempts >= 120) {
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IQFScheduleWordmarkHook();
    });
}

__attribute__((constructor))
static void IQFWordmarkInitialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            IQFScheduleWordmarkHook();
        });
    }
}
