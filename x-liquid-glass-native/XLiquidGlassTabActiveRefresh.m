#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

// XLiquidGlassNative 3.1 Beta 5
// Passive active-tab refresh for X 12.35+.
// No hooks into selection/update/layout methods.
// Selection comes only from UIAccessibilityTraitSelected, validated by probe.
// The semantic icon path remains imageView / glyphContainer only.

static NSString *const kXLG31B5TabTintModeKey = @"XLiquidGlassTabBarTintMode";
static const NSInteger kXLG31B5TintModeActive = 1;
static const NSTimeInterval kXLG31B5PollInterval = 0.12;

static NSString *gXLG31B5LastSignature = nil;
static UIColor *gXLG31B5NativeInactiveColor = nil;
static NSUInteger gXLG31B5Generation = 0;

static id XLG31B5SafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSInteger XLG31B5TintMode(void) {
    return [[NSUserDefaults standardUserDefaults]
        integerForKey:kXLG31B5TabTintModeKey];
}

static BOOL XLG31B5ItemIsProfile(UIView *item) {
    NSMutableString *identity = [NSMutableString string];
    for (NSString *part in @[
        item.accessibilityLabel ?: @"",
        item.accessibilityIdentifier ?: @"",
        item.accessibilityHint ?: @"",
        item.accessibilityValue ?: @""
    ]) {
        if (part.length) [identity appendFormat:@" %@", part.lowercaseString];
    }

    return [identity containsString:@"perfil"] ||
           [identity containsString:@"profile"] ||
           [identity containsString:@"conta"] ||
           [identity containsString:@"account"];
}

static BOOL XLG31B5ViewIsItem(UIView *view) {
    if (!view) return NO;
    NSString *name = NSStringFromClass(view.class);
    return [name isEqualToString:@"XNavigation.TabBarItemView"] ||
           [name hasSuffix:@".TabBarItemView"];
}

static UIImageView *XLG31B5FindImageViewRecursive(UIView *root, NSUInteger depth) {
    if (!root || depth > 6) return nil;
    if ([root isKindOfClass:UIImageView.class]) return (UIImageView *)root;

    for (UIView *subview in root.subviews ?: @[]) {
        UIImageView *found = XLG31B5FindImageViewRecursive(subview, depth + 1);
        if (found) return found;
    }
    return nil;
}

static UIImageView *XLG31B5ImageViewForItem(UIView *item) {
    if (!item) return nil;

    id direct = XLG31B5SafeValueForKey(item, @"imageView");
    if ([direct isKindOfClass:UIImageView.class]) {
        return (UIImageView *)direct;
    }

    id glyphContainer = XLG31B5SafeValueForKey(item, @"glyphContainer");
    if ([glyphContainer isKindOfClass:UIView.class]) {
        return XLG31B5FindImageViewRecursive((UIView *)glyphContainer, 0);
    }

    return nil;
}

static UIColor *XLG31B5ResolvedThemeColor(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger option = 0;

    id nfb = [defaults objectForKey:@"bh_color_theme_selectedColor"];
    if ([nfb respondsToSelector:@selector(integerValue)]) {
        option = [nfb integerValue];
    } else {
        id native = [defaults objectForKey:@"T1ColorSettingsPrimaryColorOptionKey"];
        if ([native respondsToSelector:@selector(integerValue)]) {
            option = [native integerValue];
        }
    }

    if (option < 1) option = 1;

    Class settingsClass = NSClassFromString(@"TAEColorSettings");
    SEL sharedSEL = NSSelectorFromString(@"sharedSettings");
    if (settingsClass && [settingsClass respondsToSelector:sharedSEL]) {
        id settings = ((id(*)(id,SEL))objc_msgSend)(settingsClass, sharedSEL);
        SEL currentSEL = NSSelectorFromString(@"currentColorPalette");
        id current = (settings && [settings respondsToSelector:currentSEL])
            ? ((id(*)(id,SEL))objc_msgSend)(settings, currentSEL)
            : nil;
        SEL paletteSEL = NSSelectorFromString(@"colorPalette");
        id palette = (current && [current respondsToSelector:paletteSEL])
            ? ((id(*)(id,SEL))objc_msgSend)(current, paletteSEL)
            : nil;
        SEL primarySEL = NSSelectorFromString(@"primaryColorForOption:");
        if (palette && [palette respondsToSelector:primarySEL]) {
            id color = ((id(*)(id,SEL,NSUInteger))objc_msgSend)(
                palette, primarySEL, (NSUInteger)option);
            if ([color isKindOfClass:UIColor.class]) return color;
        }
    }

    return UIColor.systemBlueColor;
}

static UIColor *XLG31B5FallbackNativeInactiveColor(void) {
    Class tabViewClass = NSClassFromString(@"T1TabView");
    SEL itemColorSEL = NSSelectorFromString(@"itemColor");
    if (tabViewClass && [tabViewClass respondsToSelector:itemColorSEL]) {
        id color = ((id(*)(id,SEL))objc_msgSend)(tabViewClass, itemColorSEL);
        if ([color isKindOfClass:UIColor.class]) return color;
    }
    return UIColor.secondaryLabelColor;
}

static void XLG31B5CollectItems(UIView *view, NSMutableArray<UIView *> *items) {
    if (!view) return;

    if (XLG31B5ViewIsItem(view)) {
        // The visible navigation items in X 12.35 expose accessibility labels.
        // Ignore the additional internal/carried copies with no label.
        if (view.window && !view.hidden && view.alpha > 0.01 &&
            view.accessibilityLabel.length > 0 && !XLG31B5ItemIsProfile(view)) {
            [items addObject:view];
        }
    }

    for (UIView *subview in view.subviews ?: @[]) {
        XLG31B5CollectItems(subview, items);
    }
}

static NSArray<UIView *> *XLG31B5VisibleItems(void) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window || window.hidden) continue;

            NSMutableArray<UIView *> *windowItems = [NSMutableArray array];
            XLG31B5CollectItems(window, windowItems);
            for (UIView *item in windowItems) {
                NSValue *key = [NSValue valueWithNonretainedObject:item];
                if ([seen containsObject:key]) continue;
                [seen addObject:key];
                [items addObject:item];
            }
        }
    }

    return items;
}

static BOOL XLG31B5ItemIsSelected(UIView *item) {
    return item &&
        ((item.accessibilityTraits & UIAccessibilityTraitSelected) != 0);
}

static void XLG31B5CaptureNativeInactiveColorIfNeeded(NSArray<UIView *> *items) {
    if (gXLG31B5NativeInactiveColor) return;

    for (UIView *item in items) {
        if (XLG31B5ItemIsSelected(item)) continue;
        UIImageView *imageView = XLG31B5ImageViewForItem(item);
        UIColor *color = imageView.tintColor ?: item.tintColor;
        if ([color isKindOfClass:UIColor.class]) {
            gXLG31B5NativeInactiveColor = color;
            return;
        }
    }

    gXLG31B5NativeInactiveColor = XLG31B5FallbackNativeInactiveColor();
}

static void XLG31B5ApplyColorToItem(UIView *item, UIColor *color) {
    if (!item || !color) return;

    item.tintColor = color;

    id glyphContainer = XLG31B5SafeValueForKey(item, @"glyphContainer");
    if ([glyphContainer isKindOfClass:UIView.class]) {
        ((UIView *)glyphContainer).tintColor = color;
    }

    UIImageView *imageView = XLG31B5ImageViewForItem(item);
    if (!imageView) return;

    if (imageView.image &&
        imageView.image.renderingMode != UIImageRenderingModeAlwaysTemplate) {
        imageView.image =
            [imageView.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    imageView.tintColor = color;
}

static NSString *XLG31B5SelectionSignature(NSArray<UIView *> *items) {
    NSMutableString *signature = [NSMutableString string];
    for (UIView *item in items) {
        [signature appendFormat:@"%p:%d:%@|",
            item,
            XLG31B5ItemIsSelected(item),
            item.accessibilityLabel ?: @""];
    }
    return signature;
}

static void XLG31B5RefreshIfSelectionChanged(BOOL force) {
    if (XLG31B5TintMode() != kXLG31B5TintModeActive) {
        gXLG31B5LastSignature = nil;
        return;
    }

    NSArray<UIView *> *items = XLG31B5VisibleItems();
    if (!items.count) return;

    NSString *signature = XLG31B5SelectionSignature(items);
    if (!force && [signature isEqualToString:gXLG31B5LastSignature]) return;
    gXLG31B5LastSignature = [signature copy];

    XLG31B5CaptureNativeInactiveColorIfNeeded(items);

    UIColor *themeColor = XLG31B5ResolvedThemeColor();
    UIColor *inactiveColor = gXLG31B5NativeInactiveColor ?: XLG31B5FallbackNativeInactiveColor();

    for (UIView *item in items) {
        UIColor *color = XLG31B5ItemIsSelected(item) ? themeColor : inactiveColor;
        XLG31B5ApplyColorToItem(item, color);
    }
}

static void XLG31B5ScheduleLoop(NSUInteger generation) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kXLG31B5PollInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != gXLG31B5Generation) return;
        XLG31B5RefreshIfSelectionChanged(NO);
        XLG31B5ScheduleLoop(generation);
    });
}

__attribute__((constructor))
static void XLiquidGlass31Beta5ActiveRefreshInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            gXLG31B5Generation++;
            NSUInteger generation = gXLG31B5Generation;
            XLG31B5RefreshIfSelectionChanged(YES);
            XLG31B5ScheduleLoop(generation);
            NSLog(@"[XLiquidGlassNative] 3.1 Beta 5 passive active-tab refresh installed");
        });
    }
}
