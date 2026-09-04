#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static id IQTStoredSettingsTarget = nil;
static id IQTActiveLocalization = nil;

static char IQTLongPressKey;
static BOOL IQTFallbackAttached = NO;

static BOOL IQTASNodeHooked = NO;
static BOOL IQTLocalizationHooked = NO;
static BOOL IQTSettingsTargetHooked = NO;
static BOOL IQTSettingsNavHooked = NO;
static BOOL IQTUIViewHooked = NO;

static BOOL IQTIsTelegramProcess(void) {
    NSString *exe = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
    NSString *proc = NSProcessInfo.processInfo.processName ?: @"";
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [exe isEqualToString:@"Telegram"] ||
           [proc isEqualToString:@"Telegram"] ||
           [bid isEqualToString:@"ph.telegra.Telegraph"];
}

static UIWindow *IQTKeyWindow(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow) return window;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static BOOL IQTClassLooksLikeSettingsNavButton(id object) {
    if (object == nil) return NO;
    Class cls = NSClassFromString(@"IQTSettingsNavButton");
    if (cls != Nil && [object isKindOfClass:cls]) return YES;
    return [NSStringFromClass([object class]) containsString:@"IQTSettingsNavButton"];
}

static UIView *IQTViewForNode(id node) {
    if (node == nil) return nil;
    if ([node isKindOfClass:UIView.class]) return (UIView *)node;

    SEL viewSel = NSSelectorFromString(@"view");
    if ([node respondsToSelector:viewSel]) {
        id (*send)(id, SEL) = (void *)objc_msgSend;
        id value = send(node, viewSel);
        if ([value isKindOfClass:UIView.class]) return value;
    }
    return nil;
}

static void IQTHideSettingsNavObject(id object) {
    if (!IQTClassLooksLikeSettingsNavButton(object)) return;

    SEL setHiddenSel = NSSelectorFromString(@"setHidden:");
    if ([object respondsToSelector:setHiddenSel]) {
        void (*sendBool)(id, SEL, BOOL) = (void *)objc_msgSend;
        sendBool(object, setHiddenSel, YES);
    }

    SEL setAlphaSel = NSSelectorFromString(@"setAlpha:");
    if ([object respondsToSelector:setAlphaSel]) {
        void (*sendFloat)(id, SEL, CGFloat) = (void *)objc_msgSend;
        sendFloat(object, setAlphaSel, 0.0);
    }

    SEL setInteractionSel = NSSelectorFromString(@"setUserInteractionEnabled:");
    if ([object respondsToSelector:setInteractionSel]) {
        void (*sendBool)(id, SEL, BOOL) = (void *)objc_msgSend;
        sendBool(object, setInteractionSel, NO);
    }

    UIView *view = IQTViewForNode(object);
    if (view != nil) {
        view.hidden = YES;
        view.alpha = 0.0;
        view.userInteractionEnabled = NO;
    }
}

static BOOL IQTInvokeSettingsTarget(id target) {
    if (target == nil) return NO;

    SEL tapped = NSSelectorFromString(@"iqtTapped");
    if ([target respondsToSelector:tapped]) {
        [UIApplication.sharedApplication sendAction:tapped to:target from:nil forEvent:nil];
        return YES;
    }

    SEL show = NSSelectorFromString(@"showSettingsVC:");
    if ([target respondsToSelector:show]) {
        void (*send)(id, SEL, id) = (void *)objc_msgSend;
        send(target, show, nil);
        return YES;
    }

    return NO;
}

static void IQTOpenSettings(void) {
    if (IQTInvokeSettingsTarget(IQTStoredSettingsTarget)) return;

    Class targetClass = NSClassFromString(@"IQTSettingsButtonTarget");
    if (targetClass != Nil) {
        id candidate = [[targetClass alloc] init];
        if (candidate != nil) {
            IQTStoredSettingsTarget = candidate;
            (void)IQTInvokeSettingsTarget(candidate);
        }
    }
}

static NSString *IQTLower(NSString *value) {
    return value.length ? value.lowercaseString : @"";
}

static BOOL IQTLabelMatchesLocalizedKey(NSString *lowerLabel, NSString *key, BOOL broadMatch) {
    id localization = IQTActiveLocalization;
    if (localization == nil || lowerLabel.length == 0 || key.length == 0) return NO;

    SEL getSel = NSSelectorFromString(@"get:");
    if (![localization respondsToSelector:getSel]) return NO;

    id (*send)(id, SEL, id) = (void *)objc_msgSend;
    id value = send(localization, getSel, key);
    if (![value isKindOfClass:NSString.class]) return NO;

    NSString *localized = [(NSString *)value lowercaseString];
    if (localized.length == 0 || [localized isEqualToString:key.lowercaseString]) return NO;

    if ([lowerLabel isEqualToString:localized]) return YES;

    if (broadMatch) {
        if ([lowerLabel containsString:localized] || [localized containsString:lowerLabel]) return YES;
    } else if (localized.length >= 6 && [lowerLabel containsString:localized]) {
        return YES;
    }

    return NO;
}

static BOOL IQTLabelIsSupportRow(NSString *label) {
    if (label.length == 0) return NO;

    NSString *lower = IQTLower(label);

    if ([lower containsString:@"turrit"]) return YES;
    if ([lower containsString:@"leadgram"]) return YES;
    if ([lower containsString:@"swiftgram"]) return YES;

    if ([lower isEqualToString:@"support"]) return YES;
    if ([lower isEqualToString:@"send a gift"]) return YES;

    static NSArray<NSString *> *knownSupportLabels;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        knownSupportLabels = @[
            @"ask a question",
            @"fazer uma pergunta",
            @"faça uma pergunta",
            @"pergunte",
            @"perguntar"
        ];
    });

    for (NSString *candidate in knownSupportLabels) {
        if ([lower containsString:candidate]) return YES;
    }

    if (IQTLabelMatchesLocalizedKey(lower, @"Settings.SendGift", NO)) return YES;
    if (IQTLabelMatchesLocalizedKey(lower, @"Settings.Support", YES)) return YES;

    return NO;
}

static void IQTHandleASLongPress(id self, SEL _cmd, UILongPressGestureRecognizer *gesture) {
    (void)self;
    (void)_cmd;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        IQTOpenSettings();
    }
}

static UILongPressGestureRecognizer *IQTGestureForNode(id node) {
    return objc_getAssociatedObject(node, &IQTLongPressKey);
}

static void IQTSetGestureForNode(id node, UILongPressGestureRecognizer *gesture) {
    objc_setAssociatedObject(node, &IQTLongPressKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void IQTAttachMxStyleGestureToNode(id node) {
    if (node == nil) return;

    UILongPressGestureRecognizer *gesture = IQTGestureForNode(node);
    if (gesture == nil) {
        gesture = [[UILongPressGestureRecognizer alloc]
            initWithTarget:node
                    action:NSSelectorFromString(@"__handleIQTLongPress:")];

        gesture.cancelsTouchesInView = NO;
        gesture.delaysTouchesBegan = NO;
        gesture.delaysTouchesEnded = NO;

        IQTSetGestureForNode(node, gesture);
    }

    UIView *view = IQTViewForNode(node);
    if (view == nil) return;

    if ([view.gestureRecognizers containsObject:gesture]) return;

    UIView *cursor = view;
    for (NSInteger level = 0; cursor != nil && level < 5; level++, cursor = cursor.superview) {
        for (UIGestureRecognizer *existing in cursor.gestureRecognizers.copy) {
            if (existing == gesture) continue;
            if ([existing isKindOfClass:UILongPressGestureRecognizer.class]) {
                [existing requireGestureRecognizerToFail:gesture];
            }
        }
    }

    [view addGestureRecognizer:gesture];
}

static void (*IQTOrigASSetAccessibilityLabel)(id, SEL, NSString *) = NULL;
static void IQTASSetAccessibilityLabel(id self, SEL _cmd, NSString *label) {
    IQTOrigASSetAccessibilityLabel(self, _cmd, label);

    NSString *className = NSStringFromClass([self class]);
    if (![className containsString:@"AccessibilityAreaNode"]) return;
    if (label.length == 0) return;

    SEL supernodeSel = NSSelectorFromString(@"supernode");
    if (![self respondsToSelector:supernodeSel]) return;

    id (*send)(id, SEL) = (void *)objc_msgSend;
    id supernode = send(self, supernodeSel);
    if (supernode == nil) return;

    NSString *superClassName = NSStringFromClass([supernode class]);
    if ([superClassName containsString:@"ChatMessage"]) return;

    if (!IQTLabelIsSupportRow(label)) return;

    IQTAttachMxStyleGestureToNode(supernode);
}

@interface IQTFallbackGestureTarget : NSObject
+ (instancetype)shared;
- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture;
@end

@implementation IQTFallbackGestureTarget
+ (instancetype)shared {
    static IQTFallbackGestureTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [IQTFallbackGestureTarget new];
    });
    return target;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        IQTOpenSettings();
    }
}
@end

static void IQTTryAttachMxFallbackInView(UIView *view) {
    if (view == nil || IQTFallbackAttached) return;

    if ([NSStringFromClass(view.class) isEqualToString:@"Display.AccessibilityAreaNode"]) {
        NSString *label = view.accessibilityLabel;
        if (IQTLabelIsSupportRow(label)) {
            UIView *superview = view.superview;
            if (superview != nil) {
                for (UIGestureRecognizer *existing in superview.gestureRecognizers.copy) {
                    if ([existing isKindOfClass:UILongPressGestureRecognizer.class]) {
                        return;
                    }
                }

                UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
                    initWithTarget:IQTFallbackGestureTarget.shared
                            action:@selector(handleLongPress:)];

                [superview addGestureRecognizer:gesture];
                IQTFallbackAttached = YES;
                return;
            }
        }
    }

    for (UIView *subview in view.subviews.copy) {
        IQTTryAttachMxFallbackInView(subview);
        if (IQTFallbackAttached) return;
    }
}

static void IQTTryAttachMxFallback(void) {
    if (IQTFallbackAttached) return;
    UIWindow *window = IQTKeyWindow();
    if (window != nil) {
        IQTTryAttachMxFallbackInView(window);
    }
}

static id (*IQTOrigLocalizationGet)(id, SEL, id) = NULL;
static id IQTLocalizationGet(id self, SEL _cmd, id key) {
    IQTActiveLocalization = self;

    if (!IQTFallbackAttached) {
        dispatch_async(dispatch_get_main_queue(), ^{
            IQTTryAttachMxFallback();
        });
    }

    return IQTOrigLocalizationGet(self, _cmd, key);
}

static id (*IQTOrigLocalizationInit)(id, SEL, int, id, id, BOOL) = NULL;
static id IQTLocalizationInit(id self, SEL _cmd, int version, id code, id dict, BOOL active) {
    id result = IQTOrigLocalizationInit(self, _cmd, version, code, dict, active);
    if (result != nil) {
        IQTActiveLocalization = result;
        if (!IQTFallbackAttached) {
            dispatch_async(dispatch_get_main_queue(), ^{
                IQTTryAttachMxFallback();
            });
        }
    }
    return result;
}

static id (*IQTOrigSettingsTargetInit)(id, SEL) = NULL;
static id IQTSettingsTargetInit(id self, SEL _cmd) {
    id result = IQTOrigSettingsTargetInit(self, _cmd);
    if (result != nil) IQTStoredSettingsTarget = result;
    return result;
}

static void (*IQTOrigSettingsTargetTapped)(id, SEL) = NULL;
static void IQTSettingsTargetTapped(id self, SEL _cmd) {
    IQTStoredSettingsTarget = self;
    IQTOrigSettingsTargetTapped(self, _cmd);
}

static void (*IQTOrigSettingsNavLayout)(id, SEL) = NULL;
static void IQTSettingsNavLayout(id self, SEL _cmd) {
    if (IQTOrigSettingsNavLayout != NULL) {
        IQTOrigSettingsNavLayout(self, _cmd);
    }
    IQTHideSettingsNavObject(self);
}

static void (*IQTOrigUIViewAddSubview)(UIView *, SEL, UIView *) = NULL;
static void IQTUIViewAddSubview(UIView *self, SEL _cmd, UIView *view) {
    IQTOrigUIViewAddSubview(self, _cmd, view);
    if (IQTClassLooksLikeSettingsNavButton(view)) {
        IQTHideSettingsNavObject(view);
    }
}

static BOOL IQTHookMethod(Class cls, SEL sel, IMP replacement, IMP *originalOut) {
    if (cls == Nil) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (method == NULL) return NO;

    IMP original = method_getImplementation(method);

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL ownsMethod = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            ownsMethod = YES;
            break;
        }
    }
    free(methods);

    if (ownsMethod) {
        original = method_setImplementation(method, replacement);
    } else {
        class_addMethod(cls, sel, replacement, method_getTypeEncoding(method));
    }

    if (originalOut != NULL) *originalOut = original;
    return YES;
}

static void IQTInstallHooksIfReady(void) {
    if (!IQTUIViewHooked) {
        Method method = class_getInstanceMethod(UIView.class, @selector(addSubview:));
        if (method != NULL) {
            IQTOrigUIViewAddSubview = (void *)method_setImplementation(method, (IMP)&IQTUIViewAddSubview);
            IQTUIViewHooked = YES;
        }
    }

    if (!IQTASNodeHooked) {
        Class asNode = NSClassFromString(@"ASDisplayNode");
        if (asNode != Nil) {
            class_addMethod(asNode,
                            NSSelectorFromString(@"__handleIQTLongPress:"),
                            (IMP)&IQTHandleASLongPress,
                            "v@:@");

            if (IQTHookMethod(asNode,
                              @selector(setAccessibilityLabel:),
                              (IMP)&IQTASSetAccessibilityLabel,
                              (IMP *)&IQTOrigASSetAccessibilityLabel)) {
                IQTASNodeHooked = YES;
            }
        }
    }

    if (!IQTLocalizationHooked) {
        Class localization = NSClassFromString(@"TGLocalization");
        if (localization != Nil) {
            BOOL getHooked = IQTHookMethod(localization,
                                           NSSelectorFromString(@"get:"),
                                           (IMP)&IQTLocalizationGet,
                                           (IMP *)&IQTOrigLocalizationGet);

            BOOL initHooked = IQTHookMethod(localization,
                                            NSSelectorFromString(@"initWithVersion:code:dict:isActive:"),
                                            (IMP)&IQTLocalizationInit,
                                            (IMP *)&IQTOrigLocalizationInit);

            IQTLocalizationHooked = getHooked || initHooked;
        }
    }

    if (!IQTSettingsTargetHooked) {
        Class target = NSClassFromString(@"IQTSettingsButtonTarget");
        if (target != Nil) {
            BOOL initHooked = IQTHookMethod(target,
                                            @selector(init),
                                            (IMP)&IQTSettingsTargetInit,
                                            (IMP *)&IQTOrigSettingsTargetInit);

            BOOL tappedHooked = IQTHookMethod(target,
                                              NSSelectorFromString(@"iqtTapped"),
                                              (IMP)&IQTSettingsTargetTapped,
                                              (IMP *)&IQTOrigSettingsTargetTapped);

            IQTSettingsTargetHooked = initHooked || tappedHooked;
        }
    }

    if (!IQTSettingsNavHooked) {
        Class nav = NSClassFromString(@"IQTSettingsNavButton");
        if (nav != Nil) {
            BOOL hooked = IQTHookMethod(nav,
                                        @selector(layout),
                                        (IMP)&IQTSettingsNavLayout,
                                        (IMP *)&IQTOrigSettingsNavLayout);
            if (!hooked) {
                hooked = IQTHookMethod(nav,
                                       @selector(layoutSubviews),
                                       (IMP)&IQTSettingsNavLayout,
                                       (IMP *)&IQTOrigSettingsNavLayout);
            }
            IQTSettingsNavHooked = hooked;
        }
    }
}

__attribute__((constructor)) static void IQTEnhancerInit(void) {
    @autoreleasepool {
        if (!IQTIsTelegramProcess()) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            IQTInstallHooksIfReady();
            IQTTryAttachMxFallback();

            __block NSTimer *retryTimer = nil;
            retryTimer = [NSTimer timerWithTimeInterval:0.25
                                                repeats:YES
                                                  block:^(__unused NSTimer *timer) {
                IQTInstallHooksIfReady();

                if (!IQTFallbackAttached) {
                    IQTTryAttachMxFallback();
                }

                if (IQTASNodeHooked &&
                    IQTLocalizationHooked &&
                    IQTSettingsTargetHooked &&
                    IQTSettingsNavHooked) {
                    [retryTimer invalidate];
                    retryTimer = nil;
                }
            }];

            [NSRunLoop.mainRunLoop addTimer:retryTimer forMode:NSRunLoopCommonModes];
        });
    }
}
