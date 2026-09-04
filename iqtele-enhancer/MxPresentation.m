#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL IQTMxASHandlerHooked = NO;
static BOOL IQTMxFallbackHandlerHooked = NO;

static BOOL IQTIsTelegramProcessForMxPresentation(void) {
    NSString *exe = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
    NSString *proc = NSProcessInfo.processInfo.processName ?: @"";
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [exe isEqualToString:@"Telegram"] ||
           [proc isEqualToString:@"Telegram"] ||
           [bid isEqualToString:@"ph.telegra.Telegraph"];
}

// Adapt only MxGram's showUI(): use iQTele's own root settings controller,
// but present it exactly the same way MxGram presents its settings UI.
static BOOL IQTPresentSettingsMxStyle(void) {
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

static void IQTMxASHandleLongPressReplacement(id self,
                                               SEL _cmd,
                                               UILongPressGestureRecognizer *gesture) {
    (void)self;
    (void)_cmd;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        IQTPresentSettingsMxStyle();
    }
}

static void IQTMxFallbackHandleLongPressReplacement(id self,
                                                     SEL _cmd,
                                                     UILongPressGestureRecognizer *gesture) {
    (void)self;
    (void)_cmd;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        IQTPresentSettingsMxStyle();
    }
}

static void IQTInstallMxPresentationOverridesIfReady(void) {
    if (!IQTMxASHandlerHooked) {
        Class asNode = NSClassFromString(@"ASDisplayNode");
        SEL selector = NSSelectorFromString(@"__handleMxLongPress:");
        Method method = asNode != Nil ? class_getInstanceMethod(asNode, selector) : NULL;
        if (method != NULL) {
            method_setImplementation(method, (IMP)&IQTMxASHandleLongPressReplacement);
            IQTMxASHandlerHooked = YES;
        }
    }

    if (!IQTMxFallbackHandlerHooked) {
        Class target = NSClassFromString(@"IQTMxGestureTarget");
        SEL selector = NSSelectorFromString(@"handleLongPress:");
        Method method = target != Nil ? class_getInstanceMethod(target, selector) : NULL;
        if (method != NULL) {
            method_setImplementation(method, (IMP)&IQTMxFallbackHandleLongPressReplacement);
            IQTMxFallbackHandlerHooked = YES;
        }
    }
}

__attribute__((constructor)) static void IQTMxPresentationInit(void) {
    @autoreleasepool {
        if (!IQTIsTelegramProcessForMxPresentation()) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            IQTInstallMxPresentationOverridesIfReady();

            __block NSTimer *timer = nil;
            timer = [NSTimer timerWithTimeInterval:0.10
                                           repeats:YES
                                             block:^(__unused NSTimer *t) {
                IQTInstallMxPresentationOverridesIfReady();
                if (IQTMxASHandlerHooked && IQTMxFallbackHandlerHooked) {
                    [timer invalidate];
                    timer = nil;
                }
            }];
            [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        });
    }
}
