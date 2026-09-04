#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSTimer *IQTPolishTimer = nil;

static BOOL IQTPolishShouldRun(void) {
    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"";
    return [language hasPrefix:@"pt"];
}

static UIViewController *IQTPolishFindSettingsController(UIViewController *controller) {
    if (controller == nil) return nil;

    if ([NSStringFromClass(controller.class) isEqualToString:@"IQTSettingsViewController"]) {
        return controller;
    }

    if (controller.presentedViewController != nil) {
        UIViewController *found = IQTPolishFindSettingsController(controller.presentedViewController);
        if (found != nil) return found;
    }

    if ([controller isKindOfClass:UINavigationController.class]) {
        UINavigationController *navigation = (UINavigationController *)controller;
        UIViewController *found = IQTPolishFindSettingsController(navigation.visibleViewController);
        if (found != nil) return found;
        for (UIViewController *child in navigation.viewControllers) {
            found = IQTPolishFindSettingsController(child);
            if (found != nil) return found;
        }
    }

    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *found = IQTPolishFindSettingsController(child);
        if (found != nil) return found;
    }

    return nil;
}

static void IQTPolishReplaceLabelText(UILabel *label, NSString *replacement) {
    if (label == nil || replacement.length == 0) return;

    NSAttributedString *attributed = label.attributedText;
    NSString *source = label.text ?: @"";
    if (attributed.length == source.length && attributed.length > 0) {
        NSDictionary<NSAttributedStringKey, id> *attributes =
            [attributed attributesAtIndex:0 effectiveRange:NULL];
        label.attributedText = [[NSAttributedString alloc] initWithString:replacement
                                                               attributes:attributes];
    } else {
        label.text = replacement;
    }
}

static void IQTPolishLabel(UILabel *label) {
    if (label == nil || label.hidden || label.alpha < 0.05) return;

    NSString *text = label.text ?: @"";

    if ([text isEqualToString:@"Gravar chamadas automaticamente"]) {
        IQTPolishReplaceLabelText(label, @"Gravar automaticamente");
        text = label.text ?: @"";
    }

    if ([text isEqualToString:@"Watching a story greys its ring for you. The owner is never told either way — turn this off and the ring stays as if you had not watched it."]) {
        IQTPolishReplaceLabelText(
            label,
            @"Ao ver um story, o anel fica cinza só para você. O autor não é avisado. Desative para manter o anel como se não tivesse visto."
        );
        text = label.text ?: @"";
    }

    if ([text isEqualToString:@"Recursos"] || [text isEqualToString:@"Outros"]) {
        label.numberOfLines = 1;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.82;
        label.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
        label.lineBreakMode = NSLineBreakByClipping;
    }
}

static void IQTPolishViewTree(UIView *view) {
    if (view == nil || view.hidden || view.alpha < 0.05) return;

    if ([view isKindOfClass:UILabel.class]) {
        IQTPolishLabel((UILabel *)view);
    }

    for (UIView *subview in view.subviews.copy) {
        IQTPolishViewTree(subview);
    }
}

static void IQTPolishApply(void) {
    if (!IQTPolishShouldRun() ||
        UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) {
        return;
    }

    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        UIViewController *settings = IQTPolishFindSettingsController(window.rootViewController);
        if (settings == nil || !settings.isViewLoaded || settings.view.window == nil) {
            continue;
        }

        UIView *rootView = settings.navigationController != nil
            ? settings.navigationController.view
            : settings.view;
        IQTPolishViewTree(rootView);
    }
}

static void IQTPolishStart(void) {
    if (IQTPolishTimer != nil || !IQTPolishShouldRun()) return;

    IQTPolishApply();
    IQTPolishTimer = [NSTimer timerWithTimeInterval:0.25
                                            repeats:YES
                                              block:^(__unused NSTimer *timer) {
        IQTPolishApply();
    }];
    [NSRunLoop.mainRunLoop addTimer:IQTPolishTimer forMode:NSRunLoopCommonModes];
}

__attribute__((constructor)) static void IQTPolishInit(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *executable = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
        if (![bundleIdentifier isEqualToString:@"ph.telegra.Telegraph"] &&
            ![executable isEqualToString:@"Telegram"]) {
            return;
        }

        if (!IQTPolishShouldRun()) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            IQTPolishStart();
        });
    }
}
