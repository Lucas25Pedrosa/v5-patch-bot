#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static char IQTMxLongPressKey;
static BOOL IQTMxLateAttachDone = NO;
static BOOL IQTASNodeHooksInstalled = NO;
static BOOL IQTGlassButtonHookInstalled = NO;

#pragma mark - Common helpers

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

static id IQTObjectBySelector(id object, NSString *selectorName) {
    if (object == nil) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    id (*send)(id, SEL) = (void *)objc_msgSend;
    return send(object, selector);
}

static UIView *IQTViewForNode(id node) {
    if ([node isKindOfClass:UIView.class]) return (UIView *)node;
    id view = IQTObjectBySelector(node, @"view");
    return [view isKindOfClass:UIView.class] ? view : nil;
}

static BOOL IQTMxLabelIsSupportRow(NSString *label) {
    NSString *text = IQTNormalize(label);
    if (text.length == 0) return NO;

    NSArray<NSString *> *matches = @[
        @"settings.support",
        @"ask a question",
        @"pergunte",
        @"fazer uma pergunta",
        @"faca uma pergunta",
        @"hacer una pregunta",
        @"poser une question",
        @"stellen sie eine frage",
        @"fai una domanda",
        @"bir soru sor"
    ];

    for (NSString *candidate in matches) {
        if ([text containsString:candidate]) return YES;
    }
    return NO;
}

#pragma mark - iQTele 1.5 settings presentation

static BOOL IQTPresentSettings(void) {
    Class settingsClass = NSClassFromString(@"IQTSettingsViewController");
    if (settingsClass == Nil) return NO;

    id settingsObject = [[settingsClass alloc] init];
    if (![settingsObject isKindOfClass:UIViewController.class]) return NO;

    UIViewController *settingsVC = (UIViewController *)settingsObject;
    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:settingsVC];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIWindow *keyWindow = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop

    UIViewController *rootViewController = keyWindow.rootViewController;
    if (rootViewController == nil) return NO;

    [rootViewController presentViewController:navigationController
                                     animated:YES
                                   completion:nil];
    return YES;
}

#pragma mark - iQTele 1.5 glass settings button

static BOOL IQTIsSettingsGlassButton(id object) {
    if (object == nil) return NO;

    Class cls = NSClassFromString(@"IQTSettingsGlassButton");
    if (cls != Nil && [object isKindOfClass:cls]) return YES;

    return [NSStringFromClass([object class]) containsString:@"IQTSettingsGlassButton"];
}

static void IQTHideSettingsGlassButton(id object) {
    if (!IQTIsSettingsGlassButton(object)) return;

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

#pragma mark - MxGram ASDisplayNode path

static id IQTASMxGestureGetter(id self, SEL _cmd) {
    (void)_cmd;
    return objc_getAssociatedObject(self, &IQTMxLongPressKey);
}

static void IQTASMxGestureSetter(id self, SEL _cmd, UILongPressGestureRecognizer *gesture) {
    (void)_cmd;
    objc_setAssociatedObject(self,
                             &IQTMxLongPressKey,
                             gesture,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void IQTASHandleMxLongPress(id self, SEL _cmd, UILongPressGestureRecognizer *gesture) {
    (void)self;
    (void)_cmd;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        IQTPresentSettings();
    }
}

static UILongPressGestureRecognizer *IQTASGetMxGesture(id node) {
    SEL getter = NSSelectorFromString(@"mxLongPressGesture");
    if ([node respondsToSelector:getter]) {
        id (*send)(id, SEL) = (void *)objc_msgSend;
        id result = send(node, getter);
        if ([result isKindOfClass:UILongPressGestureRecognizer.class]) {
            return result;
        }
    }
    return nil;
}

static void IQTASSetMxGesture(id node, UILongPressGestureRecognizer *gesture) {
    SEL setter = NSSelectorFromString(@"setMxLongPressGesture:");
    if ([node respondsToSelector:setter]) {
        void (*send)(id, SEL, id) = (void *)objc_msgSend;
        send(node, setter, gesture);
    }
}

static void IQTMxRequireOtherLongPressesToFail(UIView *view,
                                                UILongPressGestureRecognizer *ours) {
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

static void IQTMxAttachASDisplayNodeGesture(id accessibilityNode, NSString *label) {
    if (accessibilityNode == nil || label.length == 0) return;

    NSString *nodeClass = NSStringFromClass([accessibilityNode class]);
    if (![nodeClass containsString:@"AccessibilityAreaNode"]) return;

    id supernode = IQTObjectBySelector(accessibilityNode, @"supernode");
    if (supernode == nil) return;

    NSString *superClass = NSStringFromClass([supernode class]);
    if ([superClass containsString:@"ChatMessage"]) return;

    if (!IQTMxLabelIsSupportRow(label)) return;

    UILongPressGestureRecognizer *gesture = IQTASGetMxGesture(supernode);
    if (gesture == nil) {
        gesture = [[UILongPressGestureRecognizer alloc]
            initWithTarget:supernode
                    action:NSSelectorFromString(@"__handleMxLongPress:")];

        gesture.cancelsTouchesInView = NO;
        gesture.delaysTouchesBegan = NO;
        gesture.delaysTouchesEnded = NO;
        IQTASSetMxGesture(supernode, gesture);
    }

    UIView *view = IQTViewForNode(supernode);
    if (view == nil) return;
    if ([view.gestureRecognizers containsObject:gesture]) return;

    IQTMxRequireOtherLongPressesToFail(view, gesture);
    [view addGestureRecognizer:gesture];
}

#pragma mark - MxGram UIKit late-attach path

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
        IQTPresentSettings();
    }
}
@end

static void IQTMxTryAttachGestureInView(UIView *view) {
    if (view == nil || IQTMxLateAttachDone) return;

    NSString *className = NSStringFromClass(view.class);
    if ([className isEqualToString:@"Display.AccessibilityAreaNode"]) {
        NSString *label = view.accessibilityLabel;
        if (IQTMxLabelIsSupportRow(label)) {
            UIView *superview = view.superview;
            if (superview != nil) {
                BOOL hasLongPress = NO;
                for (UIGestureRecognizer *recognizer in superview.gestureRecognizers.copy) {
                    if ([recognizer isKindOfClass:UILongPressGestureRecognizer.class]) {
                        hasLongPress = YES;
                        break;
                    }
                }

                if (!hasLongPress) {
                    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
                        initWithTarget:IQTMxGestureTarget.shared
                                action:@selector(handleLongPress:)];
                    [superview addGestureRecognizer:gesture];
                    IQTMxLateAttachDone = YES;
                    return;
                }
            }
        }
    }

    for (UIView *subview in view.subviews.copy) {
        IQTMxTryAttachGestureInView(subview);
        if (IQTMxLateAttachDone) return;
    }
}

static void IQTMxTryAttachGesture(void) {
    if (IQTMxLateAttachDone) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIWindow *keyWindow = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
    if (keyWindow != nil) {
        IQTMxTryAttachGestureInView(keyWindow);
    }
}

#pragma mark - Hooks

static void (*IQTOriginalASSetAccessibilityLabel)(id, SEL, NSString *) = NULL;
static void IQTASSetAccessibilityLabel(id self, SEL _cmd, NSString *label) {
    if (IQTOriginalASSetAccessibilityLabel != NULL) {
        IQTOriginalASSetAccessibilityLabel(self, _cmd, label);
    }
    IQTMxAttachASDisplayNodeGesture(self, label);
    IQTMxTryAttachGesture();
}

static void (*IQTOriginalASLayout)(id, SEL) = NULL;
static void IQTASLayout(id self, SEL _cmd) {
    if (IQTOriginalASLayout != NULL) {
        IQTOriginalASLayout(self, _cmd);
    }

    NSString *nodeClass = NSStringFromClass([self class]);
    if ([nodeClass containsString:@"AccessibilityAreaNode"]) {
        id label = IQTObjectBySelector(self, @"accessibilityLabel");
        if ([label isKindOfClass:NSString.class]) {
            IQTMxAttachASDisplayNodeGesture(self, label);
        }
    }

    IQTMxTryAttachGesture();
}

static void (*IQTOriginalGlassLayoutSubviews)(id, SEL) = NULL;
static void IQTGlassLayoutSubviews(id self, SEL _cmd) {
    if (IQTOriginalGlassLayoutSubviews != NULL) {
        IQTOriginalGlassLayoutSubviews(self, _cmd);
    }
    IQTHideSettingsGlassButton(self);
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
            SEL getter = NSSelectorFromString(@"mxLongPressGesture");
            if (![asNode instancesRespondToSelector:getter]) {
                class_addMethod(asNode, getter, (IMP)&IQTASMxGestureGetter, "@@:");
            }

            SEL setter = NSSelectorFromString(@"setMxLongPressGesture:");
            if (![asNode instancesRespondToSelector:setter]) {
                class_addMethod(asNode, setter, (IMP)&IQTASMxGestureSetter, "v@:@");
            }

            SEL handler = NSSelectorFromString(@"__handleMxLongPress:");
            if (![asNode instancesRespondToSelector:handler]) {
                class_addMethod(asNode, handler, (IMP)&IQTASHandleMxLongPress, "v@:@");
            }

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

    if (!IQTGlassButtonHookInstalled) {
        Class glassButton = NSClassFromString(@"IQTSettingsGlassButton");
        if (glassButton != Nil) {
            IQTGlassButtonHookInstalled = IQTHookMethod(glassButton,
                                                        @selector(layoutSubviews),
                                                        (IMP)&IQTGlassLayoutSubviews,
                                                        (IMP *)&IQTOriginalGlassLayoutSubviews);
        }
    }
}

#pragma mark - iQTele 1.5 icon scan + Mx late attach driver

static void IQTScanViewTree(UIView *view) {
    if (view == nil) return;

    if (IQTIsSettingsGlassButton(view)) {
        IQTHideSettingsGlassButton(view);
    }

    for (UIView *child in view.subviews.copy) {
        IQTScanViewTree(child);
    }
}

static void IQTScan(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        IQTScanViewTree(window);
    }
    IQTMxTryAttachGesture();
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
