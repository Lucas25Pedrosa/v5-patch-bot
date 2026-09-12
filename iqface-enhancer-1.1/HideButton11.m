#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// iQFace 1.1 button hider.
// Keeps the old Wordmark activation untouched and only hides controls that
// positively identify themselves as iQFace / IQF actions.

__attribute__((used, visibility("default"))) NSString * const IQFEnhancerHideButtonVersion = @"1.1-hide-button";
static dispatch_source_t IQF11HideTimer = nil;

static BOOL IQF11ContainsIQF(NSString *value) {
    if (value.length == 0) return NO;
    NSString *lower = value.lowercaseString;
    return [lower containsString:@"iqface"] || [lower containsString:@"iqf"];
}

static BOOL IQF11ControlLooksLikeIQFace(UIControl *control) {
    if (control == nil) return NO;

    if (IQF11ContainsIQF(control.accessibilityLabel) ||
        IQF11ContainsIQF(control.accessibilityIdentifier)) {
        return YES;
    }

    for (id target in control.allTargets) {
        NSArray<NSString *> *actions = [control actionsForTarget:target
                                                 forControlEvent:UIControlEventTouchUpInside];
        for (NSString *action in actions) {
            if (IQF11ContainsIQF(action)) return YES;
        }
    }
    return NO;
}

static BOOL IQF11BarItemLooksLikeIQFace(UIBarButtonItem *item) {
    if (item == nil) return NO;

    if (IQF11ContainsIQF(item.title) ||
        IQF11ContainsIQF(item.accessibilityLabel) ||
        IQF11ContainsIQF(item.accessibilityIdentifier)) {
        return YES;
    }

    if (item.action != NULL && IQF11ContainsIQF(NSStringFromSelector(item.action))) {
        return YES;
    }

    UIView *custom = item.customView;
    if ([custom isKindOfClass:UIControl.class] && IQF11ControlLooksLikeIQFace((UIControl *)custom)) {
        return YES;
    }

    return NO;
}

static NSArray<UIBarButtonItem *> *IQF11FilterBarItems(NSArray<UIBarButtonItem *> *items) {
    if (items.count == 0) return items;
    NSMutableArray<UIBarButtonItem *> *result = [NSMutableArray arrayWithCapacity:items.count];
    for (UIBarButtonItem *item in items) {
        if (!IQF11BarItemLooksLikeIQFace(item)) [result addObject:item];
    }
    return result;
}

static void IQF11HideFromController(UIViewController *controller) {
    if (controller == nil) return;

    UINavigationItem *item = controller.navigationItem;

    NSArray<UIBarButtonItem *> *left = item.leftBarButtonItems;
    NSArray<UIBarButtonItem *> *leftFiltered = IQF11FilterBarItems(left);
    if (leftFiltered.count != left.count) item.leftBarButtonItems = leftFiltered;

    NSArray<UIBarButtonItem *> *right = item.rightBarButtonItems;
    NSArray<UIBarButtonItem *> *rightFiltered = IQF11FilterBarItems(right);
    if (rightFiltered.count != right.count) item.rightBarButtonItems = rightFiltered;

    if (IQF11BarItemLooksLikeIQFace(item.leftBarButtonItem)) item.leftBarButtonItem = nil;
    if (IQF11BarItemLooksLikeIQFace(item.rightBarButtonItem)) item.rightBarButtonItem = nil;

    for (UIViewController *child in controller.childViewControllers.copy) {
        IQF11HideFromController(child);
    }
    if (controller.presentedViewController != nil) {
        IQF11HideFromController(controller.presentedViewController);
    }
}

static void IQF11HideFromView(UIView *view) {
    if (view == nil) return;

    for (UIView *subview in view.subviews.copy) {
        if ([subview isKindOfClass:UIControl.class] &&
            IQF11ControlLooksLikeIQFace((UIControl *)subview)) {
            subview.hidden = YES;
            subview.alpha = 0.0;
            subview.userInteractionEnabled = NO;
            continue;
        }
        IQF11HideFromView(subview);
    }
}

static void IQF11HideNow(void) {
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows.copy) {
                IQF11HideFromController(window.rootViewController);
                IQF11HideFromView(window);
            }
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *window in UIApplication.sharedApplication.windows.copy) {
            IQF11HideFromController(window.rootViewController);
            IQF11HideFromView(window);
        }
#pragma clang diagnostic pop
    }
}

static void IQF11StartHideTimer(void) {
    if (IQF11HideTimer != nil) return;

    IQF11HideNow();

    IQF11HideTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(IQF11HideTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                              (uint64_t)(0.50 * NSEC_PER_SEC),
                              (uint64_t)(0.05 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(IQF11HideTimer, ^{
        IQF11HideNow();
    });
    dispatch_resume(IQF11HideTimer);
}

static void IQF11DidBecomeActive(NSNotification *note) {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{
        IQF11HideNow();
    });
}

__attribute__((constructor))
static void IQFEnhancerHideButton11Initialize(void) {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleID isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) return;

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *note) {
            IQF11DidBecomeActive(note);
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            IQF11StartHideTimer();
        });
    }
}
