#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern void IQFOpenSettings(void);

static const void *IQFWordmark11RecognizerKey = &IQFWordmark11RecognizerKey;
static dispatch_source_t IQFWordmark11Scanner = nil;

@interface IQFWordmarkTarget11 : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedTarget;
- (void)handleTap:(UITapGestureRecognizer *)recognizer;
@end

static BOOL IQFWordmark11CandidateRectForView(UIView *view, UIView *navigationBar, CGRect *outRect) {
    if (view == nil || navigationBar == nil || view == navigationBar || view.hidden || view.alpha < 0.01) {
        return NO;
    }

    CGRect rect = [view convertRect:view.bounds toView:navigationBar];
    CGFloat navWidth = CGRectGetWidth(navigationBar.bounds);
    CGFloat navHeight = CGRectGetHeight(navigationBar.bounds);
    if (navWidth <= 0.0 || navHeight <= 0.0 || CGRectIsEmpty(rect) || CGRectIsNull(rect)) {
        return NO;
    }

    CGRect clipped = CGRectIntersection(rect, navigationBar.bounds);
    if (CGRectIsNull(clipped) || CGRectIsEmpty(clipped)) {
        return NO;
    }

    BOOL leftRegion = CGRectGetMinX(rect) >= 12.0 && CGRectGetMinX(rect) <= 90.0;
    BOOL usefulWidth = CGRectGetWidth(rect) >= 70.0 && CGRectGetWidth(rect) <= 220.0;
    BOOL usefulHeight = CGRectGetHeight(rect) >= navHeight * 0.45 && CGRectGetHeight(rect) <= navHeight * 1.35;
    BOOL verticallyAligned = CGRectGetMidY(rect) >= navHeight * 0.30 && CGRectGetMidY(rect) <= navHeight * 0.70;

    if (!(leftRegion && usefulWidth && usefulHeight && verticallyAligned)) {
        return NO;
    }

    if (outRect != NULL) {
        *outRect = CGRectInset(clipped, -8.0, -6.0);
    }
    return YES;
}

static BOOL IQFWordmark11FindCandidateRect(UIView *root, UIView *navigationBar, CGRect *outRect) {
    if (root == nil || navigationBar == nil) return NO;

    BOOL found = NO;
    CGRect bestRect = CGRectZero;
    CGFloat bestArea = 0.0;

    for (UIView *subview in root.subviews) {
        CGRect nestedRect = CGRectZero;
        if (IQFWordmark11FindCandidateRect(subview, navigationBar, &nestedRect)) {
            CGFloat area = CGRectGetWidth(nestedRect) * CGRectGetHeight(nestedRect);
            if (!found || area > bestArea) {
                found = YES;
                bestRect = nestedRect;
                bestArea = area;
            }
        }

        CGRect candidate = CGRectZero;
        if (IQFWordmark11CandidateRectForView(subview, navigationBar, &candidate)) {
            CGFloat area = CGRectGetWidth(candidate) * CGRectGetHeight(candidate);
            if (!found || area > bestArea) {
                found = YES;
                bestRect = candidate;
                bestArea = area;
            }
        }
    }

    if (found && outRect != NULL) *outRect = bestRect;
    return found;
}

static BOOL IQFWordmark11TapIsInsideWordmark(UITapGestureRecognizer *recognizer) {
    UIView *navigationBar = recognizer.view;
    if (navigationBar == nil) return NO;

    CGPoint point = [recognizer locationInView:navigationBar];
    CGRect candidate = CGRectZero;
    if (IQFWordmark11FindCandidateRect(navigationBar, navigationBar, &candidate)) {
        return CGRectContainsPoint(candidate, point);
    }

    // Conservative fallback for the Facebook wordmark zone if the internal
    // container class/hierarchy changes again.
    CGFloat width = CGRectGetWidth(navigationBar.bounds);
    CGFloat height = CGRectGetHeight(navigationBar.bounds);
    if (width <= 0.0 || height <= 0.0) return NO;

    CGRect fallback = CGRectMake(12.0, 0.0, MIN(190.0, width * 0.52), height);
    return CGRectContainsPoint(fallback, point);
}

@implementation IQFWordmarkTarget11

+ (instancetype)sharedTarget {
    static IQFWordmarkTarget11 *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [IQFWordmarkTarget11 new];
    });
    return target;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    (void)touch;
    if (![gestureRecognizer isKindOfClass:UITapGestureRecognizer.class]) return NO;
    return IQFWordmark11TapIsInsideWordmark((UITapGestureRecognizer *)gestureRecognizer);
}

- (void)handleTap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded) return;
    if (!IQFWordmark11TapIsInsideWordmark(recognizer)) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        IQFOpenSettings();
    });
}

@end

static void IQFWordmark11AttachToNavigationBar(UIView *navigationBar) {
    if (navigationBar == nil || objc_getAssociatedObject(navigationBar, IQFWordmark11RecognizerKey) != nil) {
        return;
    }

    navigationBar.userInteractionEnabled = YES;

    UITapGestureRecognizer *recognizer = [[UITapGestureRecognizer alloc]
        initWithTarget:IQFWordmarkTarget11.sharedTarget
                action:@selector(handleTap:)];
    recognizer.numberOfTapsRequired = 1;
    recognizer.numberOfTouchesRequired = 1;
    recognizer.cancelsTouchesInView = NO;
    recognizer.delaysTouchesBegan = NO;
    recognizer.delaysTouchesEnded = NO;
    recognizer.delegate = IQFWordmarkTarget11.sharedTarget;

    [navigationBar addGestureRecognizer:recognizer];
    objc_setAssociatedObject(navigationBar,
                             IQFWordmark11RecognizerKey,
                             recognizer,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void IQFWordmark11ScanView(UIView *view, Class navigationBarClass) {
    if (view == nil) return;

    if ((navigationBarClass != Nil && [view isKindOfClass:navigationBarClass]) ||
        [NSStringFromClass(view.class) isEqualToString:@"FBNavigationBar"]) {
        IQFWordmark11AttachToNavigationBar(view);
    }

    for (UIView *subview in view.subviews.copy) {
        IQFWordmark11ScanView(subview, navigationBarClass);
    }
}

static void IQFWordmark11ScanWindows(void) {
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;

    Class navigationBarClass = NSClassFromString(@"FBNavigationBar");

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                IQFWordmark11ScanView(window, navigationBarClass);
            }
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            IQFWordmark11ScanView(window, navigationBarClass);
        }
#pragma clang diagnostic pop
    }
}

static void IQFWordmark11StartScanner(void) {
    if (IQFWordmark11Scanner != nil) return;

    IQFWordmark11Scanner = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(IQFWordmark11Scanner,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                              (uint64_t)(0.75 * NSEC_PER_SEC),
                              (uint64_t)(0.10 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(IQFWordmark11Scanner, ^{
        IQFWordmark11ScanWindows();
    });
    dispatch_resume(IQFWordmark11Scanner);
}

__attribute__((constructor))
static void IQFWordmark11Initialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            IQFWordmark11StartScanner();
        });
    }
}
