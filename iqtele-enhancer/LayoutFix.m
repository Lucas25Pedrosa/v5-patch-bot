#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSTimer *IQTLayoutTimer = nil;

static BOOL IQTLayoutShouldRun(void) {
    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"";
    return [language hasPrefix:@"pt"];
}

static BOOL IQTViewHasAncestorOfClass(UIView *view, Class cls) {
    UIView *current = view.superview;
    while (current != nil) {
        if ([current isKindOfClass:cls]) {
            return YES;
        }
        current = current.superview;
    }
    return NO;
}

static BOOL IQTVerticalRectsOverlap(CGRect first, CGRect second) {
    CGFloat top = MAX(CGRectGetMinY(first), CGRectGetMinY(second));
    CGFloat bottom = MIN(CGRectGetMaxY(first), CGRectGetMaxY(second));
    return bottom - top >= 4.0;
}

static BOOL IQTIsRightSideBlocker(UIView *view) {
    if (view.hidden || view.alpha < 0.05 || view.bounds.size.width <= 0.0 || view.bounds.size.height <= 0.0) {
        return NO;
    }

    if ([view isKindOfClass:UISwitch.class] ||
        [view isKindOfClass:UIStepper.class] ||
        [view isKindOfClass:UISlider.class]) {
        return YES;
    }

    if ([view isKindOfClass:UIButton.class]) {
        return view.bounds.size.width <= 120.0 && view.bounds.size.height <= 80.0;
    }

    if ([view isKindOfClass:UIImageView.class]) {
        return view.bounds.size.width <= 56.0 && view.bounds.size.height <= 56.0;
    }

    return NO;
}

static void IQTFindNearestBlockerInTree(UIView *view,
                                        UIView *excluded,
                                        UIView *container,
                                        CGRect labelRect,
                                        CGFloat *nearestX) {
    if (view == nil || view == excluded || view.hidden || view.alpha < 0.05) {
        return;
    }

    if (IQTIsRightSideBlocker(view)) {
        CGRect blockerRect = [view convertRect:view.bounds toView:container];
        if (IQTVerticalRectsOverlap(labelRect, blockerRect) &&
            CGRectGetMinX(blockerRect) > CGRectGetMinX(labelRect) + 24.0 &&
            CGRectGetMinX(blockerRect) < *nearestX) {
            *nearestX = CGRectGetMinX(blockerRect);
        }
    }

    for (UIView *subview in view.subviews) {
        IQTFindNearestBlockerInTree(subview, excluded, container, labelRect, nearestX);
    }
}

static CGFloat IQTAvailableWidthForLabelInContainer(UILabel *label, UIView *container) {
    if (label == nil || container == nil || label.superview == nil) {
        return 0.0;
    }

    CGRect labelRect = [label convertRect:label.bounds toView:container];
    CGFloat rightEdge = CGRectGetWidth(container.bounds) - 16.0;

    CGFloat nearestBlockerX = CGFLOAT_MAX;
    for (UIView *subview in container.subviews) {
        IQTFindNearestBlockerInTree(subview, label, container, labelRect, &nearestBlockerX);
    }

    if (nearestBlockerX < CGFLOAT_MAX) {
        rightEdge = MIN(rightEdge, nearestBlockerX - 12.0);
    }

    return MAX(0.0, rightEdge - CGRectGetMinX(labelRect));
}

static CGFloat IQTRequiredLabelWidth(UILabel *label) {
    if (label.text.length == 0) {
        return 0.0;
    }

    CGSize intrinsic = label.intrinsicContentSize;
    CGFloat width = intrinsic.width;

    if (!isfinite(width) || width <= 0.0) {
        NSDictionary *attributes = label.font != nil ? @{NSFontAttributeName: label.font} : @{};
        width = [label.text sizeWithAttributes:attributes].width;
    }

    return ceil(width) + 6.0;
}

static UIView *IQTBestContainerForLabel(UILabel *label, CGFloat requiredWidth, CGFloat *availableWidthOut) {
    UIView *current = label.superview;
    UIView *best = nil;
    CGFloat bestAvailable = CGRectGetWidth(label.bounds);
    NSUInteger depth = 0;

    while (current != nil && depth < 7) {
        CGFloat containerWidth = CGRectGetWidth(current.bounds);
        CGFloat containerHeight = CGRectGetHeight(current.bounds);
        if (containerWidth > 80.0 && containerHeight > 12.0) {
            CGFloat available = IQTAvailableWidthForLabelInContainer(label, current);
            if (available > bestAvailable + 2.0) {
                best = current;
                bestAvailable = available;
            }

            if (available >= requiredWidth &&
                (containerHeight <= 320.0 || depth <= 2)) {
                best = current;
                bestAvailable = available;
                break;
            }
        }

        if ([current isKindOfClass:UIWindow.class]) {
            break;
        }

        current = current.superview;
        depth += 1;
    }

    if (availableWidthOut != NULL) {
        *availableWidthOut = bestAvailable;
    }
    return best;
}

static void IQTUpdateWidthConstraintIfPresent(UILabel *label, UIView *stopView, CGFloat desiredWidth) {
    UIView *current = label;
    NSUInteger depth = 0;

    while (current != nil && depth < 7) {
        for (NSLayoutConstraint *constraint in current.constraints) {
            if (!constraint.active) continue;

            BOOL isDirectWidth =
                constraint.firstItem == label &&
                constraint.firstAttribute == NSLayoutAttributeWidth &&
                constraint.secondItem == nil;

            if (isDirectWidth && fabs(constraint.constant - desiredWidth) > 0.5) {
                constraint.constant = desiredWidth;
            }
        }

        if (current == stopView) {
            break;
        }
        current = current.superview;
        depth += 1;
    }
}

static void IQTExpandLabelIfNeeded(UILabel *label) {
    if (label == nil || label.superview == nil || label.text.length < 3 || label.hidden || label.alpha < 0.05) {
        return;
    }

    if (IQTViewHasAncestorOfClass(label, UINavigationBar.class) ||
        IQTViewHasAncestorOfClass(label, UISearchBar.class) ||
        IQTViewHasAncestorOfClass(label, UITextField.class)) {
        return;
    }

    CGFloat currentWidth = CGRectGetWidth(label.bounds);
    CGFloat requiredWidth = IQTRequiredLabelWidth(label);
    if (requiredWidth <= currentWidth + 1.0) {
        return;
    }

    CGFloat availableWidth = currentWidth;
    UIView *container = IQTBestContainerForLabel(label, requiredWidth, &availableWidth);
    if (container == nil || availableWidth <= currentWidth + 1.0) {
        return;
    }

    CGFloat desiredWidth = MIN(requiredWidth, availableWidth);
    if (desiredWidth <= currentWidth + 1.0) {
        return;
    }

    [label setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentHuggingPriority:UILayoutPriorityDefaultLow
                              forAxis:UILayoutConstraintAxisHorizontal];

    IQTUpdateWidthConstraintIfPresent(label, container, desiredWidth);

    CGRect frame = label.frame;
    frame.size.width = desiredWidth;
    label.frame = frame;
    label.preferredMaxLayoutWidth = desiredWidth;
}

static void IQTFixViewTree(UIView *view) {
    if (view == nil || view.hidden || view.alpha < 0.05) {
        return;
    }

    if ([view isKindOfClass:UILabel.class]) {
        IQTExpandLabelIfNeeded((UILabel *)view);
    }

    for (UIView *subview in view.subviews.copy) {
        IQTFixViewTree(subview);
    }
}

static UIViewController *IQTFindSettingsController(UIViewController *controller) {
    if (controller == nil) {
        return nil;
    }

    if ([NSStringFromClass(controller.class) isEqualToString:@"IQTSettingsViewController"]) {
        return controller;
    }

    if (controller.presentedViewController != nil) {
        UIViewController *found = IQTFindSettingsController(controller.presentedViewController);
        if (found != nil) return found;
    }

    if ([controller isKindOfClass:UINavigationController.class]) {
        UINavigationController *navigation = (UINavigationController *)controller;
        UIViewController *found = IQTFindSettingsController(navigation.visibleViewController);
        if (found != nil) return found;
    }

    if ([controller isKindOfClass:UITabBarController.class]) {
        UITabBarController *tabs = (UITabBarController *)controller;
        UIViewController *found = IQTFindSettingsController(tabs.selectedViewController);
        if (found != nil) return found;
    }

    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *found = IQTFindSettingsController(child);
        if (found != nil) return found;
    }

    return nil;
}

static void IQTApplyDynamicSettingsLayout(void) {
    if (!IQTLayoutShouldRun() || UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) {
        return;
    }

    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        UIViewController *settings = IQTFindSettingsController(window.rootViewController);
        if (settings == nil || !settings.isViewLoaded || settings.view.window == nil) {
            continue;
        }

        IQTFixViewTree(settings.view);

        UINavigationController *navigation = settings.navigationController;
        if (navigation != nil && navigation.navigationBar != nil) {
            [navigation.view setNeedsLayout];
        }
    }
}

static void IQTStartLayoutTimer(void) {
    if (IQTLayoutTimer != nil || !IQTLayoutShouldRun()) {
        return;
    }

    IQTApplyDynamicSettingsLayout();
    IQTLayoutTimer = [NSTimer timerWithTimeInterval:0.25
                                            repeats:YES
                                              block:^(__unused NSTimer *timer) {
        IQTApplyDynamicSettingsLayout();
    }];
    [NSRunLoop.mainRunLoop addTimer:IQTLayoutTimer forMode:NSRunLoopCommonModes];
}

__attribute__((constructor)) static void IQTLayoutFixInit(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *executable = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
        if (![bundleIdentifier isEqualToString:@"ph.telegra.Telegraph"] &&
            ![executable isEqualToString:@"Telegram"]) {
            return;
        }

        if (!IQTLayoutShouldRun()) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            IQTStartLayoutTimer();
        });
    }
}
