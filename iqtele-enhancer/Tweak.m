#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

static __weak id IQTStoredSettingsTarget = nil;
static NSTimeInterval IQTLastOpenTime = 0;
static char IQTGestureKey;
static BOOL IQTASNodeHooksInstalled = NO;
static BOOL IQTNavHooksInstalled = NO;
static BOOL IQTTargetHooksInstalled = NO;
static BOOL IQTLoadedBannerShown = NO;

static NSString *IQTNormalized(NSString *value) {
    if (value.length == 0) return @"";
    NSString *folded = [value stringByFoldingWithOptions:(NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch)
                                                   locale:NSLocale.currentLocale];
    return folded.lowercaseString;
}

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

static void IQTShowLoadedBanner(void) {
    if (IQTLoadedBannerShown) return;
    IQTLoadedBannerShown = YES;
    UIWindow *window = IQTKeyWindow();
    if (window == nil) return;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = @"iQTele Enhancer v0.2 loaded";
    label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.labelColor;
    label.backgroundColor = UIColor.secondarySystemBackgroundColor;
    label.layer.cornerRadius = 10.0;
    label.layer.masksToBounds = YES;
    label.alpha = 0.0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [window addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
        [label.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-12.0],
        [label.heightAnchor constraintEqualToConstant:28.0],
        [label.widthAnchor constraintGreaterThanOrEqualToConstant:190.0]
    ]];
    [UIView animateWithDuration:0.2 animations:^{ label.alpha = 0.94; } completion:^(__unused BOOL finished) {
        [UIView animateWithDuration:0.25 delay:1.4 options:0 animations:^{ label.alpha = 0.0; } completion:^(__unused BOOL done) {
            [label removeFromSuperview];
        }];
    }];
}

static BOOL IQTLooksLikeSupportLabel(NSString *label) {
    NSString *text = IQTNormalized(label);
    if (text.length == 0) return NO;
    NSArray<NSString *> *known = @[
        @"settings.support",
        @"ask a question",
        @"fazer uma pergunta",
        @"faca uma pergunta",
        @"pergunte",
        @"perguntar",
        @"hacer una pregunta",
        @"poser une question",
        @"bir soru sor"
    ];
    for (NSString *needle in known) {
        if ([text containsString:needle]) return YES;
    }
    return NO;
}

static BOOL IQTClassLooksLikeSettingsNavButton(id object) {
    if (object == nil) return NO;
    Class target = NSClassFromString(@"IQTSettingsNavButton");
    if (target != Nil && [object isKindOfClass:target]) return YES;
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
    if (object == nil || !IQTClassLooksLikeSettingsNavButton(object)) return;

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
    SEL setUIESel = NSSelectorFromString(@"setUserInteractionEnabled:");
    if ([object respondsToSelector:setUIESel]) {
        void (*sendBool)(id, SEL, BOOL) = (void *)objc_msgSend;
        sendBool(object, setUIESel, NO);
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

static BOOL IQTOpenSettings(void) {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - IQTLastOpenTime < 0.9) return NO;
    IQTLastOpenTime = now;

    id target = IQTStoredSettingsTarget;
    if (IQTInvokeSettingsTarget(target)) return YES;

    Class targetClass = NSClassFromString(@"IQTSettingsButtonTarget");
    if (targetClass != Nil) {
        id candidate = [[targetClass alloc] init];
        if (candidate != nil) {
            IQTStoredSettingsTarget = candidate;
            if (IQTInvokeSettingsTarget(candidate)) return YES;
        }
    }
    return NO;
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
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    if (IQTOpenSettings()) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback prepare];
        [feedback impactOccurred];
    }
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return YES;
}
@end

static void IQTAttachLongPressToView(UIView *view) {
    if (view == nil || objc_getAssociatedObject(view, &IQTGestureKey) != nil) return;
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:IQTGestureTarget.shared action:@selector(handleLongPress:)];
    gesture.minimumPressDuration = 0.65;
    gesture.cancelsTouchesInView = NO;
    gesture.delaysTouchesBegan = NO;
    gesture.delegate = IQTGestureTarget.shared;
    view.userInteractionEnabled = YES;
    [view addGestureRecognizer:gesture];
    objc_setAssociatedObject(view, &IQTGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void IQTConsiderASNode(id node) {
    if (node == nil) return;
    if (IQTClassLooksLikeSettingsNavButton(node)) {
        IQTHideSettingsNavObject(node);
        return;
    }
    NSString *label = nil;
    SEL labelSel = NSSelectorFromString(@"accessibilityLabel");
    if ([node respondsToSelector:labelSel]) {
        id (*send)(id, SEL) = (void *)objc_msgSend;
        id value = send(node, labelSel);
        if ([value isKindOfClass:NSString.class]) label = value;
    }
    if (IQTLooksLikeSupportLabel(label)) {
        IQTAttachLongPressToView(IQTViewForNode(node));
    }
}

static void IQTScanUIView(UIView *view) {
    if (view == nil) return;
    if (IQTClassLooksLikeSettingsNavButton(view)) IQTHideSettingsNavObject(view);
    if (IQTLooksLikeSupportLabel(view.accessibilityLabel) ||
        ([view isKindOfClass:UILabel.class] && IQTLooksLikeSupportLabel(((UILabel *)view).text))) {
        UIView *anchor = view;
        for (NSInteger i = 0; i < 5 && anchor.superview != nil; i++) {
            CGFloat h = CGRectGetHeight(anchor.bounds);
            CGFloat w = CGRectGetWidth(anchor.bounds);
            if (h >= 36.0 && h <= 100.0 && w >= 180.0) break;
            anchor = anchor.superview;
        }
        IQTAttachLongPressToView(anchor);
    }
    for (UIView *subview in view.subviews.copy) IQTScanUIView(subview);
}

static void IQTScan(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) IQTScanUIView(window);
}

static void (*IQTOrigUIViewAddSubview)(UIView *, SEL, UIView *) = NULL;
static void IQTUIViewAddSubview(UIView *self, SEL _cmd, UIView *view) {
    IQTOrigUIViewAddSubview(self, _cmd, view);
    if (IQTClassLooksLikeSettingsNavButton(view)) IQTHideSettingsNavObject(view);
}

static void (*IQTOrigASSetAccessibilityLabel)(id, SEL, NSString *) = NULL;
static void IQTASSetAccessibilityLabel(id self, SEL _cmd, NSString *label) {
    IQTOrigASSetAccessibilityLabel(self, _cmd, label);
    if (IQTClassLooksLikeSettingsNavButton(self)) IQTHideSettingsNavObject(self);
    if (IQTLooksLikeSupportLabel(label)) IQTAttachLongPressToView(IQTViewForNode(self));
}

static void (*IQTOrigASLayout)(id, SEL) = NULL;
static void IQTASLayout(id self, SEL _cmd) {
    IQTOrigASLayout(self, _cmd);
    IQTConsiderASNode(self);
}

static id (*IQTOrigTargetInit)(id, SEL) = NULL;
static id IQTTargetInit(id self, SEL _cmd) {
    id obj = IQTOrigTargetInit(self, _cmd);
    if (obj != nil) IQTStoredSettingsTarget = obj;
    return obj;
}

static void (*IQTOrigTargetTapped)(id, SEL) = NULL;
static void IQTTargetTapped(id self, SEL _cmd) {
    IQTStoredSettingsTarget = self;
    IQTOrigTargetTapped(self, _cmd);
}

static void (*IQTOrigNavLayout)(id, SEL) = NULL;
static void IQTNavLayout(id self, SEL _cmd) {
    if (IQTOrigNavLayout != NULL) IQTOrigNavLayout(self, _cmd);
    IQTHideSettingsNavObject(self);
}

static BOOL IQTAddOrReplaceHook(Class cls, SEL sel, IMP replacement, IMP *originalOut) {
    if (cls == Nil) return NO;
    Method inherited = class_getInstanceMethod(cls, sel);
    if (inherited == NULL) return NO;
    const char *types = method_getTypeEncoding(inherited);
    IMP original = method_getImplementation(inherited);
    Method own = class_getInstanceMethod(cls, sel);
    BOOL owns = NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { owns = YES; break; }
    }
    free(methods);
    if (owns && own != NULL) {
        original = method_setImplementation(own, replacement);
    } else {
        class_addMethod(cls, sel, replacement, types);
    }
    if (originalOut) *originalOut = original;
    return YES;
}

static void IQTInstallRuntimeHooksIfReady(void) {
    if (!IQTASNodeHooksInstalled) {
        Class asNode = NSClassFromString(@"ASDisplayNode");
        if (asNode != Nil) {
            BOOL a = IQTAddOrReplaceHook(asNode, @selector(setAccessibilityLabel:), (IMP)&IQTASSetAccessibilityLabel, (IMP *)&IQTOrigASSetAccessibilityLabel);
            BOOL b = IQTAddOrReplaceHook(asNode, @selector(layout), (IMP)&IQTASLayout, (IMP *)&IQTOrigASLayout);
            IQTASNodeHooksInstalled = a || b;
        }
    }

    if (!IQTTargetHooksInstalled) {
        Class target = NSClassFromString(@"IQTSettingsButtonTarget");
        if (target != Nil) {
            BOOL a = IQTAddOrReplaceHook(target, @selector(init), (IMP)&IQTTargetInit, (IMP *)&IQTOrigTargetInit);
            BOOL b = IQTAddOrReplaceHook(target, NSSelectorFromString(@"iqtTapped"), (IMP)&IQTTargetTapped, (IMP *)&IQTOrigTargetTapped);
            IQTTargetHooksInstalled = a || b;
        }
    }

    if (!IQTNavHooksInstalled) {
        Class nav = NSClassFromString(@"IQTSettingsNavButton");
        if (nav != Nil) {
            BOOL hooked = IQTAddOrReplaceHook(nav, @selector(layout), (IMP)&IQTNavLayout, (IMP *)&IQTOrigNavLayout);
            if (!hooked) hooked = IQTAddOrReplaceHook(nav, @selector(layoutSubviews), (IMP)&IQTNavLayout, (IMP *)&IQTOrigNavLayout);
            IQTNavHooksInstalled = hooked;
        }
    }
}

static void IQTInstallUIViewHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method method = class_getInstanceMethod(UIView.class, @selector(addSubview:));
        if (method != NULL) IQTOrigUIViewAddSubview = (void *)method_setImplementation(method, (IMP)&IQTUIViewAddSubview);
    });
}

__attribute__((constructor)) static void IQTEnhancerInit(void) {
    @autoreleasepool {
        if (!IQTIsTelegramProcess()) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            IQTInstallUIViewHook();
            IQTInstallRuntimeHooksIfReady();
            IQTScan();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                IQTShowLoadedBanner();
            });

            NSTimer *timer = [NSTimer timerWithTimeInterval:0.35 repeats:YES block:^(__unused NSTimer *t) {
                IQTInstallRuntimeHooksIfReady();
                IQTScan();
            }];
            [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        });
    }
}
