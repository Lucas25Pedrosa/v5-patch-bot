#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static UIBarButtonItem *IQTStoredBarItem = nil;
static UIControl *IQTStoredControl = nil;
static UIView *IQTStoredNavView = nil;
static NSTimeInterval IQTLastOpenTime = 0;
static char IQTGestureKey;

static NSString *IQTNormalized(NSString *value) {
    if (value.length == 0) return @"";
    NSString *folded = [value stringByFoldingWithOptions:(NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch)
                                                   locale:NSLocale.currentLocale];
    return folded.lowercaseString;
}

static BOOL IQTActionIsTapped(SEL action) {
    return action != NULL && [NSStringFromSelector(action) isEqualToString:@"iqtTapped"];
}

static BOOL IQTIsSettingsNavView(UIView *view) {
    if (view == nil) return NO;

    Class navClass = NSClassFromString(@"IQTSettingsNavButton");
    if (navClass != Nil && [view isKindOfClass:navClass]) return YES;

    if ([view isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)view;
        for (id target in control.allTargets) {
            NSArray<NSString *> *actions = [control actionsForTarget:target
                                                     forControlEvent:UIControlEventTouchUpInside];
            for (NSString *actionName in actions) {
                if ([actionName isEqualToString:@"iqtTapped"]) return YES;
            }
            if (@available(iOS 14.0, *)) {
                actions = [control actionsForTarget:target
                                    forControlEvent:UIControlEventPrimaryActionTriggered];
                for (NSString *actionName in actions) {
                    if ([actionName isEqualToString:@"iqtTapped"]) return YES;
                }
            }
        }
    }
    return NO;
}

static void IQTCaptureSettingsView(UIView *view) {
    if (view == nil) return;
    IQTStoredNavView = view;
    if ([view isKindOfClass:UIControl.class]) {
        IQTStoredControl = (UIControl *)view;
    }
    view.hidden = YES;
    view.alpha = 0.0;
    view.userInteractionEnabled = NO;
}

static BOOL IQTIsSettingsBarItem(UIBarButtonItem *item) {
    if (item == nil) return NO;
    if (IQTActionIsTapped(item.action)) return YES;
    return IQTIsSettingsNavView(item.customView);
}

static void IQTCaptureBarItem(UIBarButtonItem *item) {
    if (item == nil) return;
    IQTStoredBarItem = item;
    if (item.customView != nil) IQTCaptureSettingsView(item.customView);
}

static NSArray<UIBarButtonItem *> *IQTFilterItems(NSArray<UIBarButtonItem *> *items) {
    if (items.count == 0) return items;
    NSMutableArray<UIBarButtonItem *> *result = [NSMutableArray arrayWithCapacity:items.count];
    for (UIBarButtonItem *item in items) {
        if (IQTIsSettingsBarItem(item)) {
            IQTCaptureBarItem(item);
        } else {
            [result addObject:item];
        }
    }
    return result;
}

static BOOL IQTActivateStoredControl(void) {
    UIControl *control = IQTStoredControl;
    if (control == nil) return NO;

    for (id target in control.allTargets) {
        NSArray<NSString *> *actions = [control actionsForTarget:target
                                                 forControlEvent:UIControlEventTouchUpInside];
        for (NSString *actionName in actions) {
            SEL action = NSSelectorFromString(actionName);
            if (IQTActionIsTapped(action)) {
                return [UIApplication.sharedApplication sendAction:action
                                                                to:target
                                                              from:control
                                                          forEvent:nil];
            }
        }
        if (@available(iOS 14.0, *)) {
            actions = [control actionsForTarget:target
                                forControlEvent:UIControlEventPrimaryActionTriggered];
            for (NSString *actionName in actions) {
                SEL action = NSSelectorFromString(actionName);
                if (IQTActionIsTapped(action)) {
                    return [UIApplication.sharedApplication sendAction:action
                                                                    to:target
                                                                  from:control
                                                              forEvent:nil];
                }
            }
        }
    }

    [control sendActionsForControlEvents:UIControlEventTouchUpInside];
    return YES;
}

static BOOL IQTActivateStoredBarItem(void) {
    UIBarButtonItem *item = IQTStoredBarItem;
    if (item == nil || item.action == NULL) return NO;
    return [UIApplication.sharedApplication sendAction:item.action
                                                    to:item.target
                                                  from:item
                                              forEvent:nil];
}

static BOOL IQTActivateStoredNavView(void) {
    UIView *view = IQTStoredNavView;
    SEL selector = NSSelectorFromString(@"iqtTapped");
    if (view != nil && [view respondsToSelector:selector]) {
        return [UIApplication.sharedApplication sendAction:selector
                                                        to:view
                                                      from:view
                                                  forEvent:nil];
    }
    return NO;
}

static void IQTOpenSettings(void) {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - IQTLastOpenTime < 0.9) return;
    IQTLastOpenTime = now;

    BOOL opened = IQTActivateStoredBarItem();
    if (!opened) opened = IQTActivateStoredControl();
    if (!opened) opened = IQTActivateStoredNavView();

    if (opened) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback prepare];
        [feedback impactOccurred];
    }
}

@interface IQTGestureTarget : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture;
@end

@implementation IQTGestureTarget
+ (instancetype)shared {
    static IQTGestureTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [IQTGestureTarget new]; });
    return target;
}
- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) IQTOpenSettings();
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return YES;
}
@end

static NSString *IQTViewText(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (view.accessibilityIdentifier.length) [parts addObject:view.accessibilityIdentifier];
    if (view.accessibilityLabel.length) [parts addObject:view.accessibilityLabel];
    if (view.accessibilityValue.length) [parts addObject:view.accessibilityValue];
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = ((UILabel *)view).text;
        if (text.length) [parts addObject:text];
    }
    if ([view isKindOfClass:UIButton.class]) {
        NSString *title = [(UIButton *)view titleForState:UIControlStateNormal];
        if (title.length) [parts addObject:title];
    }
    return [parts componentsJoinedByString:@" "];
}

static BOOL IQTLooksLikeSupportRow(UIView *view) {
    NSString *text = IQTNormalized(IQTViewText(view));
    if (text.length == 0) return NO;

    NSArray<NSString *> *needles = @[
        @"settings.support",
        @"ask a question",
        @"fazer uma pergunta",
        @"faca uma pergunta",
        @"pergunte",
        @"perguntar"
    ];
    for (NSString *needle in needles) {
        if ([text containsString:needle]) return YES;
    }
    return NO;
}

static UIView *IQTAnchorViewForCandidate(UIView *view) {
    UIView *current = view;
    UIView *best = view;
    for (NSInteger i = 0; i < 5 && current != nil; i++, current = current.superview) {
        NSString *className = NSStringFromClass(current.class);
        CGFloat h = CGRectGetHeight(current.bounds);
        CGFloat w = CGRectGetWidth(current.bounds);
        if ([className containsString:@"AccessibilityArea"] ||
            (h >= 36.0 && h <= 100.0 && w >= 180.0)) {
            best = current;
            break;
        }
    }
    return best;
}

static void IQTAttachLongPress(UIView *view) {
    UIView *anchor = IQTAnchorViewForCandidate(view);
    if (anchor == nil || objc_getAssociatedObject(anchor, &IQTGestureKey) != nil) return;
    if (IQTIsSettingsNavView(anchor)) return;

    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:IQTGestureTarget.shared
                action:@selector(handleLongPress:)];
    gesture.minimumPressDuration = 0.65;
    gesture.cancelsTouchesInView = NO;
    gesture.delaysTouchesBegan = NO;
    gesture.delegate = IQTGestureTarget.shared;
    anchor.userInteractionEnabled = YES;
    [anchor addGestureRecognizer:gesture];
    objc_setAssociatedObject(anchor, &IQTGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void IQTScanView(UIView *view) {
    if (view == nil) return;

    if (IQTIsSettingsNavView(view)) IQTCaptureSettingsView(view);
    if (IQTLooksLikeSupportRow(view)) IQTAttachLongPress(view);

    for (UIView *subview in view.subviews.copy) IQTScanView(subview);
}

static void IQTScanController(UIViewController *controller) {
    if (controller == nil) return;

    UINavigationItem *item = controller.navigationItem;
    NSArray<UIBarButtonItem *> *left = IQTFilterItems(item.leftBarButtonItems);
    NSArray<UIBarButtonItem *> *right = IQTFilterItems(item.rightBarButtonItems);
    if (left.count != item.leftBarButtonItems.count) item.leftBarButtonItems = left;
    if (right.count != item.rightBarButtonItems.count) item.rightBarButtonItems = right;
    if (IQTIsSettingsBarItem(item.leftBarButtonItem)) {
        IQTCaptureBarItem(item.leftBarButtonItem);
        item.leftBarButtonItem = nil;
    }
    if (IQTIsSettingsBarItem(item.rightBarButtonItem)) {
        IQTCaptureBarItem(item.rightBarButtonItem);
        item.rightBarButtonItem = nil;
    }

    for (UIViewController *child in controller.childViewControllers) IQTScanController(child);
    IQTScanController(controller.presentedViewController);
}

static void IQTScan(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        IQTScanView(window);
        IQTScanController(window.rootViewController);
    }
}

static void (*IQTOriginalAddSubview)(UIView *, SEL, UIView *) = NULL;
static void IQTAddSubview(UIView *self, SEL command, UIView *view) {
    if (IQTIsSettingsNavView(view)) IQTCaptureSettingsView(view);
    IQTOriginalAddSubview(self, command, view);
}

static void (*IQTOriginalSetLeftItem)(UINavigationItem *, SEL, UIBarButtonItem *) = NULL;
static void (*IQTOriginalSetLeftItemAnimated)(UINavigationItem *, SEL, UIBarButtonItem *, BOOL) = NULL;
static void (*IQTOriginalSetRightItem)(UINavigationItem *, SEL, UIBarButtonItem *) = NULL;
static void (*IQTOriginalSetRightItemAnimated)(UINavigationItem *, SEL, UIBarButtonItem *, BOOL) = NULL;
static void (*IQTOriginalSetLeftItems)(UINavigationItem *, SEL, NSArray<UIBarButtonItem *> *) = NULL;
static void (*IQTOriginalSetLeftItemsAnimated)(UINavigationItem *, SEL, NSArray<UIBarButtonItem *> *, BOOL) = NULL;
static void (*IQTOriginalSetRightItems)(UINavigationItem *, SEL, NSArray<UIBarButtonItem *> *) = NULL;
static void (*IQTOriginalSetRightItemsAnimated)(UINavigationItem *, SEL, NSArray<UIBarButtonItem *> *, BOOL) = NULL;

static void IQTSetLeftItem(UINavigationItem *self, SEL command, UIBarButtonItem *item) {
    if (IQTIsSettingsBarItem(item)) { IQTCaptureBarItem(item); item = nil; }
    IQTOriginalSetLeftItem(self, command, item);
}
static void IQTSetLeftItemAnimated(UINavigationItem *self, SEL command, UIBarButtonItem *item, BOOL animated) {
    if (IQTIsSettingsBarItem(item)) { IQTCaptureBarItem(item); item = nil; }
    IQTOriginalSetLeftItemAnimated(self, command, item, animated);
}
static void IQTSetRightItem(UINavigationItem *self, SEL command, UIBarButtonItem *item) {
    if (IQTIsSettingsBarItem(item)) { IQTCaptureBarItem(item); item = nil; }
    IQTOriginalSetRightItem(self, command, item);
}
static void IQTSetRightItemAnimated(UINavigationItem *self, SEL command, UIBarButtonItem *item, BOOL animated) {
    if (IQTIsSettingsBarItem(item)) { IQTCaptureBarItem(item); item = nil; }
    IQTOriginalSetRightItemAnimated(self, command, item, animated);
}
static void IQTSetLeftItems(UINavigationItem *self, SEL command, NSArray<UIBarButtonItem *> *items) {
    IQTOriginalSetLeftItems(self, command, IQTFilterItems(items));
}
static void IQTSetLeftItemsAnimated(UINavigationItem *self, SEL command, NSArray<UIBarButtonItem *> *items, BOOL animated) {
    IQTOriginalSetLeftItemsAnimated(self, command, IQTFilterItems(items), animated);
}
static void IQTSetRightItems(UINavigationItem *self, SEL command, NSArray<UIBarButtonItem *> *items) {
    IQTOriginalSetRightItems(self, command, IQTFilterItems(items));
}
static void IQTSetRightItemsAnimated(UINavigationItem *self, SEL command, NSArray<UIBarButtonItem *> *items, BOOL animated) {
    IQTOriginalSetRightItemsAnimated(self, command, IQTFilterItems(items), animated);
}

static void IQTReplaceMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) return;
    *original = method_setImplementation(method, replacement);
}

static void IQTInstallHooks(void) {
    IQTReplaceMethod(UIView.class, @selector(addSubview:), (IMP)&IQTAddSubview, (IMP *)&IQTOriginalAddSubview);
    IQTReplaceMethod(UINavigationItem.class, @selector(setLeftBarButtonItem:), (IMP)&IQTSetLeftItem, (IMP *)&IQTOriginalSetLeftItem);
    IQTReplaceMethod(UINavigationItem.class, @selector(setLeftBarButtonItem:animated:), (IMP)&IQTSetLeftItemAnimated, (IMP *)&IQTOriginalSetLeftItemAnimated);
    IQTReplaceMethod(UINavigationItem.class, @selector(setRightBarButtonItem:), (IMP)&IQTSetRightItem, (IMP *)&IQTOriginalSetRightItem);
    IQTReplaceMethod(UINavigationItem.class, @selector(setRightBarButtonItem:animated:), (IMP)&IQTSetRightItemAnimated, (IMP *)&IQTOriginalSetRightItemAnimated);
    IQTReplaceMethod(UINavigationItem.class, @selector(setLeftBarButtonItems:), (IMP)&IQTSetLeftItems, (IMP *)&IQTOriginalSetLeftItems);
    IQTReplaceMethod(UINavigationItem.class, @selector(setLeftBarButtonItems:animated:), (IMP)&IQTSetLeftItemsAnimated, (IMP *)&IQTOriginalSetLeftItemsAnimated);
    IQTReplaceMethod(UINavigationItem.class, @selector(setRightBarButtonItems:), (IMP)&IQTSetRightItems, (IMP *)&IQTOriginalSetRightItems);
    IQTReplaceMethod(UINavigationItem.class, @selector(setRightBarButtonItems:animated:), (IMP)&IQTSetRightItemsAnimated, (IMP *)&IQTOriginalSetRightItemsAnimated);
}

__attribute__((constructor)) static void IQTEnhancerInit(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"ph.telegra.Telegraph"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            IQTInstallHooks();
            IQTScan();

            NSTimer *timer = [NSTimer timerWithTimeInterval:0.45
                                                   repeats:YES
                                                     block:^(__unused NSTimer *t) { IQTScan(); }];
            [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];

            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(__unused NSNotification *note) { IQTScan(); }];
        });
    }
}
