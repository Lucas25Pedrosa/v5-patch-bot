#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static id IQTStoredNavButton = nil;
static char IQTLongPressKey;
static BOOL IQTASNodeHooksInstalled = NO;
static BOOL IQTNavHooksInstalled = NO;

static NSString *IQTNormalize(NSString *value) {
    if (value.length == 0) return @"";
    return [[value stringByFoldingWithOptions:(NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch)
                                       locale:NSLocale.currentLocale] lowercaseString];
}

static BOOL IQTIsTelegramProcess(void) {
    NSString *exe = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
    NSString *proc = NSProcessInfo.processInfo.processName ?: @"";
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [exe isEqualToString:@"Telegram"] ||
           [proc isEqualToString:@"Telegram"] ||
           [bid isEqualToString:@"ph.telegra.Telegraph"];
}

static BOOL IQTIsSettingsNavButton(id object) {
    if (object == nil) return NO;
    Class cls = NSClassFromString(@"IQTSettingsNavButton");
    if (cls != Nil && [object isKindOfClass:cls]) return YES;
    return [NSStringFromClass([object class]) containsString:@"IQTSettingsNavButton"];
}

static id IQTObjectBySelector(id object, NSString *selectorName) {
    if (object == nil) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    id (*send)(id, SEL) = (void *)objc_msgSend;
    return send(object, selector);
}

static UIView *IQTViewForNode(id node) {
    id view = IQTObjectBySelector(node, @"view");
    return [view isKindOfClass:UIView.class] ? view : nil;
}

static void IQTRememberAndHideNavButton(id object) {
    if (!IQTIsSettingsNavButton(object)) return;

    // Preserve the exact original iQTele button instance. In iQTele 1.2 the
    // button registers itself as target for @selector(iqtTapped).
    IQTStoredNavButton = object;

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

    UIView *view = IQTViewForNode(object);
    if (view != nil) {
        view.hidden = YES;
        view.alpha = 0.0;
        view.userInteractionEnabled = NO;
    }
}

static BOOL IQTOpenSettingsThroughOriginalButton(void) {
    id button = IQTStoredNavButton;
    if (button == nil) return NO;

    // This is the original action registered by IQTSettingsNavButton itself.
    SEL tapped = NSSelectorFromString(@"iqtTapped");
    if (![button respondsToSelector:tapped]) return NO;

    void (*send)(id, SEL) = (void *)objc_msgSend;
    send(button, tapped);
    return YES;
}

@interface IQTMxGestureTarget : NSObject
+ (instancetype)shared;
- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture;
@end

@implementation IQTMxGestureTarget
+ (instancetype)shared {
    static IQTMxGestureTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [IQTMxGestureTarget new];
    });
    return target;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        IQTOpenSettingsThroughOriginalButton();
    }
}
@end

static BOOL IQTIsSupportLabel(NSString *label) {
    NSString *text = IQTNormalize(label);
    if (text.length == 0) return NO;

    NSArray<NSString *> *matches = @[
        @"settings.support",
        @"ask a question",
        @"pergunte",
        @"fazer uma pergunta",
        @"faca uma pergunta"
    ];
    for (NSString *candidate in matches) {
        if ([text containsString:candidate]) return YES;
    }
    return NO;
}

static void IQTPrioritizeMxStyleLongPress(UIView *view, UILongPressGestureRecognizer *ours) {
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

static void IQTAttachMxStyleLongPressToAccessibilityNode(id accessibilityNode) {
    if (accessibilityNode == nil) return;

    // MxGram attaches to the AccessibilityAreaNode's supernode, not to the
    // AccessibilityAreaNode itself.
    id supernode = IQTObjectBySelector(accessibilityNode, @"supernode");
    if (supernode == nil) return;

    if (objc_getAssociatedObject(supernode, &IQTLongPressKey) != nil) return;

    UIView *view = IQTViewForNode(supernode);
    if (view == nil) return;

    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:IQTMxGestureTarget.shared
                action:@selector(handleLongPress:)];

    // Keep UIKit defaults, as MxGram does. Only preserve normal tap handling.
    gesture.cancelsTouchesInView = NO;
    gesture.delaysTouchesBegan = NO;
    gesture.delaysTouchesEnded = NO;

    [view addGestureRecognizer:gesture];
    objc_setAssociatedObject(supernode,
                             &IQTLongPressKey,
                             gesture,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    IQTPrioritizeMxStyleLongPress(view, gesture);
}

static void IQTConsiderASNode(id node) {
    if (node == nil) return;

    if (IQTIsSettingsNavButton(node)) {
        IQTRememberAndHideNavButton(node);
        return;
    }

    id label = IQTObjectBySelector(node, @"accessibilityLabel");
    if ([label isKindOfClass:NSString.class] && IQTIsSupportLabel(label)) {
        IQTAttachMxStyleLongPressToAccessibilityNode(node);
    }
}

static void (*IQTOriginalASSetAccessibilityLabel)(id, SEL, NSString *) = NULL;
static void IQTASSetAccessibilityLabel(id self, SEL _cmd, NSString *label) {
    IQTOriginalASSetAccessibilityLabel(self, _cmd, label);

    if (IQTIsSettingsNavButton(self)) {
        IQTRememberAndHideNavButton(self);
        return;
    }

    if (IQTIsSupportLabel(label)) {
        IQTAttachMxStyleLongPressToAccessibilityNode(self);
    }
}

static void (*IQTOriginalASLayout)(id, SEL) = NULL;
static void IQTASLayout(id self, SEL _cmd) {
    IQTOriginalASLayout(self, _cmd);
    IQTConsiderASNode(self);
}

static void (*IQTOriginalNavLayout)(id, SEL) = NULL;
static void IQTNavLayout(id self, SEL _cmd) {
    if (IQTOriginalNavLayout != NULL) IQTOriginalNavLayout(self, _cmd);
    IQTRememberAndHideNavButton(self);
}

static BOOL IQTHookMethod(Class cls, SEL selector, IMP replacement, IMP *originalOut) {
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

static void IQTInstallHooksIfReady(void) {
    if (!IQTASNodeHooksInstalled) {
        Class asNode = NSClassFromString(@"ASDisplayNode");
        if (asNode != Nil) {
            BOOL labelHook = IQTHookMethod(asNode,
                                           @selector(setAccessibilityLabel:),
                                           (IMP)&IQTASSetAccessibilityLabel,
                                           (IMP *)&IQTOriginalASSetAccessibilityLabel);
            BOOL layoutHook = IQTHookMethod(asNode,
                                            @selector(layout),
                                            (IMP)&IQTASLayout,
                                            (IMP *)&IQTOriginalASLayout);
            IQTASNodeHooksInstalled = labelHook || layoutHook;
        }
    }

    if (!IQTNavHooksInstalled) {
        Class nav = NSClassFromString(@"IQTSettingsNavButton");
        if (nav != Nil) {
            BOOL hooked = IQTHookMethod(nav,
                                        @selector(layout),
                                        (IMP)&IQTNavLayout,
                                        (IMP *)&IQTOriginalNavLayout);
            if (!hooked) {
                hooked = IQTHookMethod(nav,
                                       @selector(layoutSubviews),
                                       (IMP)&IQTNavLayout,
                                       (IMP *)&IQTOriginalNavLayout);
            }
            IQTNavHooksInstalled = hooked;
        }
    }
}

static void IQTScanViewTree(UIView *view) {
    if (view == nil) return;

    if (IQTIsSettingsNavButton(view)) {
        IQTRememberAndHideNavButton(view);
    }

    for (UIView *child in view.subviews.copy) {
        IQTScanViewTree(child);
    }
}

static void IQTScan(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        IQTScanViewTree(window);
    }
}

__attribute__((constructor)) static void IQTEnhancerInit(void) {
    @autoreleasepool {
        if (!IQTIsTelegramProcess()) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            IQTInstallHooksIfReady();
            IQTScan();

            NSTimer *timer = [NSTimer timerWithTimeInterval:0.35
                                                   repeats:YES
                                                     block:^(__unused NSTimer *t) {
                IQTInstallHooksIfReady();
                IQTScan();
            }];
            [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        });
    }
}
