#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

// iQFace Feed Separator 0.1.0
// Hook-free add-on for iQFace + FBOLED.
// Adds a native iQFace toggle and recolors only the validated Facebook feed
// separator view (FBLineComponentInternalView) during the periodic scan.
// No swizzling, no method replacement, no image changes.

static NSString *const IQFSPreferenceKey = @"iQFaceFeedSeparatorsEnabled";
static const void *kIQFSOriginalViewColorKey = &kIQFSOriginalViewColorKey;
static const void *kIQFSOriginalLayerColorKey = &kIQFSOriginalLayerColorKey;

static NSTimer *gIQFSTimer;
static id gIQFSActiveObserver;
static BOOL gIQFSEnabled = NO;

static void IQFSRunPass(void);

#pragma mark - Preference

static BOOL IQFSLoadPreference(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:IQFSPreferenceKey] == nil) return NO;
    return [defaults boolForKey:IQFSPreferenceKey];
}

static void IQFSSavePreference(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:IQFSPreferenceKey];
}

#pragma mark - Color helpers

static uint32_t IQFSRGBA(UIColor *color, UITraitCollection *traits) {
    if (!color) return UINT32_MAX;

    UIColor *resolved = color;
    @try {
        if (traits) resolved = [color resolvedColorWithTraitCollection:traits];
    } @catch (__unused NSException *exception) {
        return UINT32_MAX;
    }

    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![resolved getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat white = 0.0;
        if (![resolved getWhite:&white alpha:&alpha]) return UINT32_MAX;
        red = green = blue = white;
    }

    uint32_t r = (uint32_t)llround(MAX(0.0, MIN(1.0, red)) * 255.0);
    uint32_t g = (uint32_t)llround(MAX(0.0, MIN(1.0, green)) * 255.0);
    uint32_t b = (uint32_t)llround(MAX(0.0, MIN(1.0, blue)) * 255.0);
    uint32_t a = (uint32_t)llround(MAX(0.0, MIN(1.0, alpha)) * 255.0);
    return (r << 24) | (g << 16) | (b << 8) | a;
}

static BOOL IQFSIsDarkSeparatorColor(uint32_t rgba) {
    // Native Facebook dark separator and the resulting FBOLED black.
    return rgba == 0x101011FF || rgba == 0x000000FF;
}

static UIColor *IQFSSeparatorColor(void) {
    // Subtle on true black: visually about #242424 while preserving OLED feel.
    return [UIColor colorWithWhite:1.0 alpha:0.14];
}

#pragma mark - Feed separator identification

static BOOL IQFSHasFeedAncestor(UIView *view) {
    UIView *ancestor = view.superview;
    NSUInteger depth = 0;

    while (ancestor && depth < 24) {
        NSString *name = NSStringFromClass(ancestor.class);
        if ([name isEqualToString:@"FBNewsFeedView"] ||
            [name isEqualToString:@"FBNewsFeedCollectionView"]) {
            return YES;
        }
        ancestor = ancestor.superview;
        depth++;
    }

    return NO;
}

static BOOL IQFSIsValidatedFeedSeparator(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.01) return NO;
    if (![NSStringFromClass(view.class) isEqualToString:@"FBLineComponentInternalView"]) return NO;

    CGRect bounds = view.bounds;
    CGFloat width = fabs(bounds.size.width);
    CGFloat height = fabs(bounds.size.height);
    if (!isfinite(width) || !isfinite(height)) return NO;

    // Diagnostic signature: full-width horizontal line, ~393 x 2 pt.
    CGFloat screenWidth = fabs(UIScreen.mainScreen.bounds.size.width);
    CGFloat minimumWidth = MAX(200.0, screenWidth * 0.70);
    if (width < minimumWidth) return NO;
    if (height <= 0.0 || height > 3.0) return NO;

    // Keep the rule inside the News Feed only so unrelated Facebook hairlines
    // and settings separators remain untouched.
    if (!IQFSHasFeedAncestor(view)) return NO;

    UIColor *viewColor = view.backgroundColor;
    if (viewColor && IQFSIsDarkSeparatorColor(IQFSRGBA(viewColor, view.traitCollection))) {
        return YES;
    }

    if (!viewColor && view.layer.backgroundColor) {
        UIColor *layerColor = [UIColor colorWithCGColor:view.layer.backgroundColor];
        if (IQFSIsDarkSeparatorColor(IQFSRGBA(layerColor, view.traitCollection))) {
            return YES;
        }
    }

    // If this exact validated separator is already ours, keep managing it.
    if (objc_getAssociatedObject(view, kIQFSOriginalViewColorKey) ||
        objc_getAssociatedObject(view.layer, kIQFSOriginalLayerColorKey)) {
        return YES;
    }

    return NO;
}

static void IQFSRestoreViewIfNeeded(UIView *view) {
    UIColor *originalView = objc_getAssociatedObject(view, kIQFSOriginalViewColorKey);
    if (originalView) {
        view.backgroundColor = originalView;
        objc_setAssociatedObject(view,
                                 kIQFSOriginalViewColorKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIColor *originalLayer = objc_getAssociatedObject(view.layer, kIQFSOriginalLayerColorKey);
    if (originalLayer) {
        view.layer.backgroundColor = originalLayer.CGColor;
        objc_setAssociatedObject(view.layer,
                                 kIQFSOriginalLayerColorKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void IQFSApplySeparatorStyle(UIView *view) {
    BOOL target = IQFSIsValidatedFeedSeparator(view);

    if (!gIQFSEnabled || !target) {
        IQFSRestoreViewIfNeeded(view);
        return;
    }

    UIColor *separator = IQFSSeparatorColor();

    if (view.backgroundColor) {
        if (!objc_getAssociatedObject(view, kIQFSOriginalViewColorKey)) {
            objc_setAssociatedObject(view,
                                     kIQFSOriginalViewColorKey,
                                     view.backgroundColor,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.backgroundColor = separator;
        return;
    }

    if (view.layer.backgroundColor) {
        if (!objc_getAssociatedObject(view.layer, kIQFSOriginalLayerColorKey)) {
            UIColor *original = [UIColor colorWithCGColor:view.layer.backgroundColor];
            objc_setAssociatedObject(view.layer,
                                     kIQFSOriginalLayerColorKey,
                                     original,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.layer.backgroundColor = separator.CGColor;
    }
}

static void IQFSWalkViews(UIView *view) {
    if (!view) return;

    IQFSApplySeparatorStyle(view);

    for (UIView *child in [view.subviews copy]) {
        IQFSWalkViews(child);
    }
}

#pragma mark - Native iQFace settings row, discovered without hooks

static NSString *IQFSRowTitle(id row) {
    NSString *title = nil;
    @try {
        title = [row valueForKey:@"title"];
    } @catch (__unused NSException *exception) {
        title = nil;
    }
    return [title isKindOfClass:NSString.class] ? title : nil;
}

static BOOL IQFSIsOwnRow(id row) {
    NSString *title = IQFSRowTitle(row);
    return [title isEqualToString:@"Mostrar separadores no feed"] ||
           [title isEqualToString:@"Show feed separators"];
}

static NSArray *IQFSSections(UIViewController *controller) {
    NSArray *sections = nil;
    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        sections = nil;
    }
    return [sections isKindOfClass:NSArray.class] ? sections : nil;
}

static id IQFSFindToolsSection(NSArray *sections) {
    for (id section in sections) {
        NSString *header = nil;
        @try {
            header = [section valueForKey:@"header"];
        } @catch (__unused NSException *exception) {
            header = nil;
        }

        if (![header isKindOfClass:NSString.class]) continue;
        NSString *normalized = header.lowercaseString;
        if ([normalized isEqualToString:@"ferramentas"] ||
            [normalized isEqualToString:@"tools"] ||
            [normalized isEqualToString:@"herramientas"]) {
            return section;
        }
    }
    return nil;
}

static BOOL IQFSRowAlreadyExists(NSArray *sections) {
    for (id section in sections) {
        NSArray *rows = nil;
        @try {
            rows = [section valueForKey:@"rows"];
        } @catch (__unused NSException *exception) {
            rows = nil;
        }
        if (![rows isKindOfClass:NSArray.class]) continue;

        for (id row in rows) {
            if (IQFSIsOwnRow(row)) return YES;
        }
    }
    return NO;
}

static id IQFSCreateNativeToggleRow(UIViewController *controller) {
    SEL selector = NSSelectorFromString(@"rowWithTitle:icon:key:def:onChange:");
    if (!controller || ![controller respondsToSelector:selector]) return nil;

    void (^onChange)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            gIQFSEnabled = !gIQFSEnabled;
            IQFSSavePreference(gIQFSEnabled);

            UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
            [feedback selectionChanged];

            IQFSRunPass();
        });
    };

    typedef id (*IQFSNativeToggleBuilder)(id, SEL, id, id, id, BOOL, id);
    IQFSNativeToggleBuilder builder = (IQFSNativeToggleBuilder)(void *)objc_msgSend;

    return builder(controller,
                   selector,
                   @"Mostrar separadores no feed",
                   @"line.3.horizontal",
                   IQFSPreferenceKey,
                   gIQFSEnabled,
                   [onChange copy]);
}

static void IQFSInstallSettingsRow(UIViewController *controller) {
    if (!controller || ![NSStringFromClass(controller.class) isEqualToString:@"IQFSettingsViewController"]) {
        return;
    }

    NSArray *sections = IQFSSections(controller);
    if (sections.count == 0 || IQFSRowAlreadyExists(sections)) return;

    id toolsSection = IQFSFindToolsSection(sections);
    if (!toolsSection) return;

    NSArray *rows = nil;
    @try {
        rows = [toolsSection valueForKey:@"rows"];
    } @catch (__unused NSException *exception) {
        rows = nil;
    }
    if (![rows isKindOfClass:NSArray.class]) return;

    id nativeRow = IQFSCreateNativeToggleRow(controller);
    Class rowClass = NSClassFromString(@"IQFRow");
    if (!nativeRow || rowClass == Nil || ![nativeRow isKindOfClass:rowClass]) return;

    NSMutableArray *updatedRows = [rows mutableCopy];
    NSUInteger insertionIndex = updatedRows.count;

    // Prefer placing it immediately after the OLED control when present.
    for (NSUInteger i = 0; i < updatedRows.count; i++) {
        NSString *title = IQFSRowTitle(updatedRows[i]);
        if ([title isEqualToString:@"Modo OLED"] || [title isEqualToString:@"OLED Mode"]) {
            insertionIndex = i + 1;
            break;
        }
    }

    if (insertionIndex == updatedRows.count) {
        for (NSUInteger i = 0; i < updatedRows.count; i++) {
            NSString *title = IQFSRowTitle(updatedRows[i]);
            if ([title isEqualToString:@"Limpar cache"] || [title isEqualToString:@"Clear cache"] ||
                [title isEqualToString:@"Alterar ícone"] || [title isEqualToString:@"Change Icon"]) {
                insertionIndex = i + 1;
            }
        }
    }

    [updatedRows insertObject:nativeRow atIndex:MIN(insertionIndex, updatedRows.count)];

    @try {
        [toolsSection setValue:[updatedRows copy] forKey:@"rows"];
        if ([controller isKindOfClass:UITableViewController.class]) {
            [((UITableViewController *)controller).tableView reloadData];
        }
    } @catch (__unused NSException *exception) {
        // Leave iQFace settings untouched if its internal model changes.
    }
}

static UIViewController *IQFSFindSettingsController(UIViewController *controller, NSUInteger depth) {
    if (!controller || depth > 20) return nil;

    if ([NSStringFromClass(controller.class) isEqualToString:@"IQFSettingsViewController"]) {
        return controller;
    }

    UIViewController *presented = controller.presentedViewController;
    if (presented) {
        UIViewController *found = IQFSFindSettingsController(presented, depth + 1);
        if (found) return found;
    }

    if ([controller isKindOfClass:UINavigationController.class]) {
        UIViewController *top = ((UINavigationController *)controller).topViewController;
        UIViewController *found = IQFSFindSettingsController(top, depth + 1);
        if (found) return found;
    }

    if ([controller isKindOfClass:UITabBarController.class]) {
        UIViewController *selected = ((UITabBarController *)controller).selectedViewController;
        UIViewController *found = IQFSFindSettingsController(selected, depth + 1);
        if (found) return found;
    }

    for (UIViewController *child in controller.children) {
        UIViewController *found = IQFSFindSettingsController(child, depth + 1);
        if (found) return found;
    }

    return nil;
}

#pragma mark - Periodic pass

static NSArray<UIWindow *> *IQFSWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateUnattached) continue;
        [windows addObjectsFromArray:windowScene.windows];
    }

    return windows;
}

static void IQFSRunPass(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ IQFSRunPass(); });
        return;
    }

    @autoreleasepool {
        @try {
            NSArray<UIWindow *> *windows = IQFSWindows();

            for (UIWindow *window in windows) {
                IQFSWalkViews(window);

                UIViewController *settings = IQFSFindSettingsController(window.rootViewController, 0);
                if (settings) IQFSInstallSettingsRow(settings);
            }
        } @catch (__unused NSException *exception) {
            // A transient Facebook/iQFace tree mutation must never terminate the app.
        }
    }
}

static void IQFSStart(void) {
    IQFSRunPass();

    if (!gIQFSTimer) {
        gIQFSTimer = [NSTimer timerWithTimeInterval:0.75
                                            repeats:YES
                                              block:^(__unused NSTimer *timer) {
            IQFSRunPass();
        }];
        gIQFSTimer.tolerance = 0.15;
        [NSRunLoop.mainRunLoop addTimer:gIQFSTimer forMode:NSRunLoopCommonModes];
    }

    if (!gIQFSActiveObserver) {
        gIQFSActiveObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
            IQFSRunPass();
        }];
    }
}

__attribute__((constructor))
static void IQFSInitialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        gIQFSEnabled = IQFSLoadPreference();

        dispatch_async(dispatch_get_main_queue(), ^{
            IQFSStart();
        });
    }
}
