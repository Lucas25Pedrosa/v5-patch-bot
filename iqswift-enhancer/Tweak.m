#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static char IQSGestureKey;
static BOOL IQSLateAttachDone = NO;
static BOOL IQSASNodeHooksInstalled = NO;
static BOOL IQSNavHooksInstalled = NO;
static BOOL IQSDidLogHiddenLogo = NO;
static BOOL IQSPresentingSettings = NO;

#pragma mark - Process / helpers

static NSString *IQSNormalize(NSString *value) {
    if (value.length == 0) return @"";
    return [[value stringByFoldingWithOptions:(NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch)
                                       locale:NSLocale.currentLocale] lowercaseString];
}

static BOOL IQSIsSwiftgramProcess(void) {
    NSString *exe = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
    NSString *proc = NSProcessInfo.processInfo.processName ?: @"";
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";

    return [exe isEqualToString:@"Swiftgram"] ||
           [proc isEqualToString:@"Swiftgram"] ||
           [bid isEqualToString:@"app.swiftgram.ios"];
}

static id IQSObjectBySelector(id object, NSString *selectorName) {
    if (object == nil) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    id (*send)(id, SEL) = (void *)objc_msgSend;
    return send(object, selector);
}

static UIView *IQSViewForNode(id node) {
    if ([node isKindOfClass:UIView.class]) return (UIView *)node;
    id view = IQSObjectBySelector(node, @"view");
    return [view isKindOfClass:UIView.class] ? view : nil;
}

static BOOL IQSLabelIsActivationRow(NSString *label) {
    NSString *text = IQSNormalize(label);
    if (text.length == 0) return NO;

    NSArray<NSString *> *matches = @[
        @"swiftgram",
        @"settings.support",
        @"settings.sendgift",
        @"ask a question",
        @"pergunte",
        @"fazer uma pergunta",
        @"faca uma pergunta",
        @"hacer una pregunta",
        @"poser une question",
        @"stellen sie eine frage",
        @"fai una domanda",
        @"bir soru sor",
        @"send a gift"
    ];

    for (NSString *candidate in matches) {
        if ([text containsString:candidate]) return YES;
    }
    return NO;
}

#pragma mark - Present iQTele settings

static UIWindow *IQSBestWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:UIWindowScene.class]) continue;

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) return window;
            }
            for (UIWindow *window in windowScene.windows) {
                if (!window.hidden && window.alpha > 0.0 && window.windowLevel == UIWindowLevelNormal) {
                    return window;
                }
            }
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (app.keyWindow != nil) return app.keyWindow;
#pragma clang diagnostic pop

    for (UIWindow *window in app.windows) {
        if (!window.hidden && window.alpha > 0.0) return window;
    }
    return nil;
}

static UIViewController *IQSTopViewController(UIViewController *controller) {
    if (controller == nil) return nil;

    UIViewController *current = controller;
    BOOL advanced = YES;

    while (advanced) {
        advanced = NO;

        if (current.presentedViewController != nil &&
            !current.presentedViewController.isBeingDismissed) {
            current = current.presentedViewController;
            advanced = YES;
            continue;
        }

        if ([current isKindOfClass:UINavigationController.class]) {
            UIViewController *visible = ((UINavigationController *)current).visibleViewController;
            if (visible != nil && visible != current) {
                current = visible;
                advanced = YES;
                continue;
            }
        }

        if ([current isKindOfClass:UITabBarController.class]) {
            UIViewController *selected = ((UITabBarController *)current).selectedViewController;
            if (selected != nil && selected != current) {
                current = selected;
                advanced = YES;
                continue;
            }
        }
    }

    return current;
}

static BOOL IQSPresentSettings(void) {
    if (IQSPresentingSettings) return NO;

    Class settingsClass = NSClassFromString(@"IQTSettingsViewController");
    if (settingsClass == Nil) {
        NSLog(@"[iQSwiftEnhancer] IQTSettingsViewController unavailable");
        return NO;
    }

    id settingsObject = [[settingsClass alloc] init];
    if (![settingsObject isKindOfClass:UIViewController.class]) {
        NSLog(@"[iQSwiftEnhancer] IQTSettingsViewController is not a UIViewController");
        return NO;
    }

    UIWindow *window = IQSBestWindow();
    UIViewController *presenter = IQSTopViewController(window.rootViewController);
    if (presenter == nil) {
        NSLog(@"[iQSwiftEnhancer] presenter unavailable");
        return NO;
    }

    UIViewController *settingsVC = (UIViewController *)settingsObject;
    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:settingsVC];

    IQSPresentingSettings = YES;
    [presenter presentViewController:navigationController
                            animated:YES
                          completion:^{
        IQSPresentingSettings = NO;
        NSLog(@"[iQSwiftEnhancer] iQTele settings presented");
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IQSPresentingSettings = NO;
    });

    return YES;
}

#pragma mark - Hide iQLogo / IQTSettingsNavButton

static BOOL IQSIsSettingsNavButton(id object) {
    if (object == nil) return NO;

    Class cls = NSClassFromString(@"IQTSettingsNavButton");
    if (cls != Nil && [object isKindOfClass:cls]) return YES;

    NSString *name = NSStringFromClass([object class]) ?: @"";
    return [name containsString:@"IQTSettingsNavButton"];
}

static void IQSHideSettingsNavButton(id object) {
    if (!IQSIsSettingsNavButton(object)) return;

    SEL setHidden = NSSelectorFromString(@"setHidden:");
    if ([object respondsToSelector:setHidden]) {
        void (*sendBool)(id, SEL, BOOL) = (void *)objc_msgSend;
        sendBool(object, setHidden, YES);
    }

    SEL setAlpha = NSSelectorFromString(@"setAlpha:");
    if ([object respondsToSelector:setAlpha]) {
        void (*sendFloat)(id, SEL, CGFloat) = (void *)objc_msgSend;
        sendFloat(object, setAlpha, 0.0);
    }

    SEL setInteraction = NSSelectorFromString(@"setUserInteractionEnabled:");
    if ([object respondsToSelector:setInteraction]) {
        void (*sendBool)(id, SEL, BOOL) = (void *)objc_msgSend;
        sendBool(object, setInteraction, NO);
    }

    UIView *view = IQSViewForNode(object);
    if (view != nil) {
        view.hidden = YES;
        view.alpha = 0.0;
        view.userInteractionEnabled = NO;
    }

    if (!IQSDidLogHiddenLogo) {
        IQSDidLogHiddenLogo = YES;
        NSLog(@"[iQSwiftEnhancer] IQTSettingsNavButton hidden");
    }
}

#pragma mark - Long press on Swiftgram / Support row

static id IQSGestureGetter(id self, SEL _cmd) {
    (void)_cmd;
    return objc_getAssociatedObject(self, &IQSGestureKey);
}

static void IQSGestureSetter(id self, SEL _cmd, UILongPressGestureRecognizer *gesture) {
    (void)_cmd;
    objc_setAssociatedObject(self, &IQSGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void IQSHandleNodeLongPress(id self, SEL _cmd, UILongPressGestureRecognizer *gesture) {
    (void)self;
    (void)_cmd;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        IQSPresentSettings();
    }
}

static UILongPressGestureRecognizer *IQSGetGesture(id node) {
    SEL getter = NSSelectorFromString(@"iqsLongPressGesture");
    if ([node respondsToSelector:getter]) {
        id (*send)(id, SEL) = (void *)objc_msgSend;
        id result = send(node, getter);
        if ([result isKindOfClass:UILongPressGestureRecognizer.class]) {
            return result;
        }
    }
    return nil;
}

static void IQSSetGesture(id node, UILongPressGestureRecognizer *gesture) {
    SEL setter = NSSelectorFromString(@"setIqsLongPressGesture:");
    if ([node respondsToSelector:setter]) {
        void (*send)(id, SEL, id) = (void *)objc_msgSend;
        send(node, setter, gesture);
    }
}

static void IQSPreferOurLongPress(UIView *view, UILongPressGestureRecognizer *ours) {
    UIView *current = view;
    for (NSInteger level = 0; level < 5 && current != nil; level++, current = current.superview) {
        for (UIGestureRecognizer *recognizer in current.gestureRecognizers.copy) {
            if (recognizer == ours) continue;
            if ([recognizer isKindOfClass:UILongPressGestureRecognizer.class]) {
                [(UILongPressGestureRecognizer *)recognizer requireGestureRecognizerToFail:ours];
            }
        }
    }
}

static void IQSAttachNodeGesture(id accessibilityNode, NSString *label) {
    if (accessibilityNode == nil || label.length == 0) return;

    NSString *nodeClass = NSStringFromClass([accessibilityNode class]) ?: @"";
    if (![nodeClass containsString:@"AccessibilityAreaNode"]) return;
    if (!IQSLabelIsActivationRow(label)) return;

    id supernode = IQSObjectBySelector(accessibilityNode, @"supernode");
    if (supernode == nil) return;

    NSString *superClass = NSStringFromClass([supernode class]) ?: @"";
    if ([superClass containsString:@"ChatMessage"]) return;

    UILongPressGestureRecognizer *gesture = IQSGetGesture(supernode);
    if (gesture == nil) {
        gesture = [[UILongPressGestureRecognizer alloc]
            initWithTarget:supernode
                    action:NSSelectorFromString(@"__handleIQSwiftLongPress:")];
        gesture.cancelsTouchesInView = NO;
        gesture.delaysTouchesBegan = NO;
        gesture.delaysTouchesEnded = NO;
        IQSSetGesture(supernode, gesture);
    }

    UIView *view = IQSViewForNode(supernode);
    if (view == nil) return;
    if ([view.gestureRecognizers containsObject:gesture]) return;

    IQSPreferOurLongPress(view, gesture);
    [view addGestureRecognizer:gesture];
    NSLog(@"[iQSwiftEnhancer] long press attached to '%@'", label);
}

@interface IQSwiftGestureTarget : NSObject
+ (instancetype)shared;
- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture;
@end

@implementation IQSwiftGestureTarget
+ (instancetype)shared {
    static IQSwiftGestureTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [IQSwiftGestureTarget new];
    });
    return target;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        IQSPresentSettings();
    }
}
@end

static void IQSTryAttachGestureInView(UIView *view) {
    if (view == nil || IQSLateAttachDone) return;

    NSString *className = NSStringFromClass(view.class) ?: @"";
    if ([className containsString:@"AccessibilityAreaNode"]) {
        NSString *label = view.accessibilityLabel;
        if (IQSLabelIsActivationRow(label)) {
            UIView *container = view.superview;
            if (container != nil) {
                BOOL alreadyAttached = NO;
                for (UIGestureRecognizer *recognizer in container.gestureRecognizers.copy) {
                    if (recognizer.view == container &&
                        recognizer.name != nil &&
                        [recognizer.name isEqualToString:@"iQSwiftEnhancerActivation"]) {
                        alreadyAttached = YES;
                        break;
                    }
                }

                if (!alreadyAttached) {
                    UILongPressGestureRecognizer *gesture =
                        [[UILongPressGestureRecognizer alloc]
                            initWithTarget:IQSwiftGestureTarget.shared
                                    action:@selector(handleLongPress:)];
                    if (@available(iOS 11.0, *)) {
                        gesture.name = @"iQSwiftEnhancerActivation";
                    }
                    gesture.cancelsTouchesInView = NO;
                    gesture.delaysTouchesBegan = NO;
                    gesture.delaysTouchesEnded = NO;
                    IQSPreferOurLongPress(container, gesture);
                    [container addGestureRecognizer:gesture];
                    NSLog(@"[iQSwiftEnhancer] fallback long press attached to '%@'", label);
                }

                IQSLateAttachDone = YES;
                return;
            }
        }
    }

    for (UIView *subview in view.subviews.copy) {
        IQSTryAttachGestureInView(subview);
        if (IQSLateAttachDone) return;
    }
}

static void IQSTryAttachGesture(void) {
    if (IQSLateAttachDone) return;
    UIWindow *window = IQSBestWindow();
    if (window != nil) {
        IQSTryAttachGestureInView(window);
    }
}

#pragma mark - Hooks

static void (*IQSOriginalASSetAccessibilityLabel)(id, SEL, NSString *) = NULL;
static void IQSASSetAccessibilityLabel(id self, SEL _cmd, NSString *label) {
    IQSOriginalASSetAccessibilityLabel(self, _cmd, label);
    IQSAttachNodeGesture(self, label);
    IQSTryAttachGesture();
}

static void (*IQSOriginalASLayout)(id, SEL) = NULL;
static void IQSASLayout(id self, SEL _cmd) {
    IQSOriginalASLayout(self, _cmd);

    NSString *nodeClass = NSStringFromClass([self class]) ?: @"";
    if ([nodeClass containsString:@"AccessibilityAreaNode"]) {
        id label = IQSObjectBySelector(self, @"accessibilityLabel");
        if ([label isKindOfClass:NSString.class]) {
            IQSAttachNodeGesture(self, label);
        }
    }

    IQSTryAttachGesture();
}

static void (*IQSOriginalNavLayout)(id, SEL) = NULL;
static void IQSNavLayout(id self, SEL _cmd) {
    if (IQSOriginalNavLayout != NULL) IQSOriginalNavLayout(self, _cmd);
    IQSHideSettingsNavButton(self);
}

static void (*IQSOriginalNavSetHidden)(id, SEL, BOOL) = NULL;
static void IQSNavSetHidden(id self, SEL _cmd, BOOL hidden) {
    (void)hidden;
    if (IQSOriginalNavSetHidden != NULL) IQSOriginalNavSetHidden(self, _cmd, YES);
}

static void (*IQSOriginalNavSetAlpha)(id, SEL, CGFloat) = NULL;
static void IQSNavSetAlpha(id self, SEL _cmd, CGFloat alpha) {
    (void)alpha;
    if (IQSOriginalNavSetAlpha != NULL) IQSOriginalNavSetAlpha(self, _cmd, 0.0);
}

static void (*IQSOriginalNavSetInteraction)(id, SEL, BOOL) = NULL;
static void IQSNavSetInteraction(id self, SEL _cmd, BOOL enabled) {
    (void)enabled;
    if (IQSOriginalNavSetInteraction != NULL) IQSOriginalNavSetInteraction(self, _cmd, NO);
}

static BOOL IQSHookMethod(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
    if (cls == Nil) return NO;

    Method inherited = class_getInstanceMethod(cls, selector);
    if (inherited == NULL) return NO;

    const char *types = method_getTypeEncoding(inherited);
    IMP original = method_getImplementation(inherited);

    BOOL ownsMethod = NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            ownsMethod = YES;
            break;
        }
    }
    free(methods);

    if (ownsMethod) {
        Method own = class_getInstanceMethod(cls, selector);
        original = method_setImplementation(own, replacement);
    } else {
        class_addMethod(cls, selector, replacement, types);
    }

    if (originalOut != NULL) *originalOut = original;
    return YES;
}

static void IQSInstallHooksIfReady(void) {
    if (!IQSASNodeHooksInstalled) {
        Class asNode = NSClassFromString(@"ASDisplayNode");
        if (asNode != Nil) {
            SEL getter = NSSelectorFromString(@"iqsLongPressGesture");
            if (![asNode instancesRespondToSelector:getter]) {
                class_addMethod(asNode, getter, (IMP)&IQSGestureGetter, "@@:");
            }

            SEL setter = NSSelectorFromString(@"setIqsLongPressGesture:");
            if (![asNode instancesRespondToSelector:setter]) {
                class_addMethod(asNode, setter, (IMP)&IQSGestureSetter, "v@:@");
            }

            SEL handler = NSSelectorFromString(@"__handleIQSwiftLongPress:");
            if (![asNode instancesRespondToSelector:handler]) {
                class_addMethod(asNode, handler, (IMP)&IQSHandleNodeLongPress, "v@:@");
            }

            BOOL labelHook = IQSHookMethod(asNode,
                                           @selector(setAccessibilityLabel:),
                                           (IMP)&IQSASSetAccessibilityLabel,
                                           (IMP *)&IQSOriginalASSetAccessibilityLabel);
            BOOL layoutHook = IQSHookMethod(asNode,
                                            @selector(layout),
                                            (IMP)&IQSASLayout,
                                            (IMP *)&IQSOriginalASLayout);
            IQSASNodeHooksInstalled = labelHook || layoutHook;
        }
    }

    if (!IQSNavHooksInstalled) {
        Class nav = NSClassFromString(@"IQTSettingsNavButton");
        if (nav != Nil) {
            BOOL hookedAny = NO;

            hookedAny |= IQSHookMethod(nav,
                                       @selector(layout),
                                       (IMP)&IQSNavLayout,
                                       (IMP *)&IQSOriginalNavLayout);

            if (IQSOriginalNavLayout == NULL) {
                hookedAny |= IQSHookMethod(nav,
                                           @selector(layoutSubviews),
                                           (IMP)&IQSNavLayout,
                                           (IMP *)&IQSOriginalNavLayout);
            }

            hookedAny |= IQSHookMethod(nav,
                                       @selector(setHidden:),
                                       (IMP)&IQSNavSetHidden,
                                       (IMP *)&IQSOriginalNavSetHidden);

            hookedAny |= IQSHookMethod(nav,
                                       @selector(setAlpha:),
                                       (IMP)&IQSNavSetAlpha,
                                       (IMP *)&IQSOriginalNavSetAlpha);

            hookedAny |= IQSHookMethod(nav,
                                       @selector(setUserInteractionEnabled:),
                                       (IMP)&IQSNavSetInteraction,
                                       (IMP *)&IQSOriginalNavSetInteraction);

            IQSNavHooksInstalled = hookedAny;
        }
    }
}

#pragma mark - Scan / driver

static void IQSScanViewTree(UIView *view) {
    if (view == nil) return;

    if (IQSIsSettingsNavButton(view)) {
        IQSHideSettingsNavButton(view);
    }

    for (UIView *child in view.subviews.copy) {
        IQSScanViewTree(child);
    }
}

static void IQSScan(void) {
    UIApplication *app = UIApplication.sharedApplication;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                IQSScanViewTree(window);
            }
        }
    } else {
        for (UIWindow *window in app.windows) {
            IQSScanViewTree(window);
        }
    }

    IQSTryAttachGesture();
}

__attribute__((constructor)) static void IQSwiftEnhancerInit(void) {
    @autoreleasepool {
        if (!IQSIsSwiftgramProcess()) return;

        NSLog(@"[iQSwiftEnhancer] 1.0 loaded");

        dispatch_async(dispatch_get_main_queue(), ^{
            IQSInstallHooksIfReady();
            IQSScan();

            NSTimer *timer = [NSTimer timerWithTimeInterval:0.35
                                                   repeats:YES
                                                     block:^(__unused NSTimer *t) {
                IQSInstallHooksIfReady();
                IQSScan();
            }];
            [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        });
    }
}
