#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const void *FBWPRecognizerKey = &FBWPRecognizerKey;

@interface FBWPProbeTarget : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handleTap:(UITapGestureRecognizer *)recognizer;
@end

static NSString *FBWPSafeString(id value) {
    if (value == nil) return @"";
    NSString *s = [value description];
    return s ?: @"";
}

static NSString *FBWPDescribeView(UIView *view, UIWindow *window, NSInteger depth) {
    if (view == nil) return @"";

    CGRect frame = [view.superview convertRect:view.frame toView:window];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%ld. %@  frame=(%.0f,%.0f %.0fx%.0f)",
                      (long)depth,
                      NSStringFromClass(view.class),
                      frame.origin.x, frame.origin.y,
                      frame.size.width, frame.size.height]];

    NSString *label = FBWPSafeString(view.accessibilityLabel);
    if (label.length) [parts addObject:[NSString stringWithFormat:@"   a11yLabel=%@", label]];

    NSString *identifier = FBWPSafeString(view.accessibilityIdentifier);
    if (identifier.length) [parts addObject:[NSString stringWithFormat:@"   a11yId=%@", identifier]];

    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = ((UILabel *)view).text ?: @"";
        if (text.length) [parts addObject:[NSString stringWithFormat:@"   text=%@", text]];
    }

    if ([view isKindOfClass:UIImageView.class]) {
        UIImage *image = ((UIImageView *)view).image;
        if (image) {
            [parts addObject:[NSString stringWithFormat:@"   image=%.0fx%.0f scale=%.1f",
                              image.size.width, image.size.height, image.scale]];
        }
    }

    return [parts componentsJoinedByString:@"\n"];
}

static UIViewController *FBWPTopViewController(UIViewController *controller) {
    if (controller.presentedViewController) {
        return FBWPTopViewController(controller.presentedViewController);
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return FBWPTopViewController(((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return FBWPTopViewController(((UITabBarController *)controller).selectedViewController);
    }
    return controller;
}

@implementation FBWPProbeTarget

+ (instancetype)shared {
    static FBWPProbeTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [FBWPProbeTarget new]; });
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

    UIWindow *window = (UIWindow *)recognizer.view;
    if (![window isKindOfClass:UIWindow.class]) return;

    CGPoint point = [recognizer locationInView:window];
    CGFloat width = CGRectGetWidth(window.bounds);
    CGFloat height = CGRectGetHeight(window.bounds);

    // Only inspect the area where the Facebook wordmark normally lives.
    if (point.y > height * 0.24 || point.x > width * 0.62) return;

    UIView *hit = [window hitTest:point withEvent:nil];
    if (hit == nil) return;

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"Tap: (%.0f, %.0f)", point.x, point.y]];
    [lines addObject:[NSString stringWithFormat:@"Top VC: %@", NSStringFromClass(FBWPTopViewController(window.rootViewController).class)]];
    [lines addObject:@""];

    UIView *current = hit;
    NSInteger depth = 0;
    while (current != nil && depth < 12) {
        [lines addObject:FBWPDescribeView(current, window, depth)];
        current = current.superview;
        depth += 1;
    }

    NSString *report = [lines componentsJoinedByString:@"\n"];
    NSLog(@"[FacebookWordmarkProbe]\n%@", report);

    UIViewController *presenter = FBWPTopViewController(window.rootViewController);
    if (presenter == nil || presenter.presentedViewController != nil) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Facebook Wordmark Probe"
                                                                   message:report
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copiar"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = report;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Fechar"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

@end

static void FBWPAttachToWindow(UIWindow *window) {
    if (window == nil || objc_getAssociatedObject(window, FBWPRecognizerKey) != nil) return;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:FBWPProbeTarget.shared
                                                                         action:@selector(handleTap:)];
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    tap.delaysTouchesEnded = NO;
    tap.delegate = FBWPProbeTarget.shared;
    [window addGestureRecognizer:tap];
    objc_setAssociatedObject(window, FBWPRecognizerKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void FBWPScanWindows(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!window.hidden && window.alpha > 0.01) {
            FBWPAttachToWindow(window);
        }
    }
}

static void FBWPApplicationDidBecomeActive(__unused NSNotification *notification) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FBWPScanWindows();
    });
}

__attribute__((constructor))
static void FBWPInitialize(void) {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleID isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            FBWPApplicationDidBecomeActive(note);
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            FBWPScanWindows();
        });
    }
}
