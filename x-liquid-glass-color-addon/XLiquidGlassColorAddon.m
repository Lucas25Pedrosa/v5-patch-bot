#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

#pragma mark - XLiquidGlass 2.0 Color Add-on

// Standalone companion for XLiquidGlass 1.9.3.
// Scope is intentionally limited to Tab Bar theme coloring only.

static NSString *const kXCATabBarColorModeKey = @"XLiquidGlassTabBarColorMode";

typedef NS_ENUM(NSInteger, XCATabBarColorMode) {
    XCATabBarColorModeNative = 0,
    XCATabBarColorModeActiveOnly = 1,
    XCATabBarColorModeAllTabs = 2,
};

static BOOL gXCAThemeAccentEnabled = NO;
static BOOL gXCAActiveOnlyNeedsPrime = NO;
static BOOL gXCAAllowNavigationHook = NO;

static BOOL gXCANavigationHookInstalled = NO;
static BOOL gXCAThemeDefaultsHooksInstalled = NO;
static BOOL gXCASettingsHooksInstalled = NO;

static IMP gOrigXCANavigationLayoutSubviews = NULL;
static IMP gOrigXCADefaultsSetInteger = NULL;
static IMP gOrigXCADefaultsSetObject = NULL;

static IMP gOrigXCASettingsRows = NULL;
static IMP gOrigXCASettingsCell = NULL;
static IMP gOrigXCASettingsDidSelect = NULL;

#pragma mark - Hook helper

static BOOL XCAHookMethod(Class cls,
                          SEL sel,
                          IMP replacement,
                          IMP *original) {
    if (!cls || !sel || !replacement) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP current = class_getMethodImplementation(cls, sel);
    if (current == replacement) return YES;

    if (original && !*original) {
        *original = current;
    }

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    class_replaceMethod(cls, sel, replacement, types);
    return class_getMethodImplementation(cls, sel) == replacement;
}

#pragma mark - Preference

static XCATabBarColorMode XCATabBarColorModeValue(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults objectForKey:kXCATabBarColorModeKey]) {
        return XCATabBarColorModeNative;
    }

    NSInteger raw = [defaults integerForKey:kXCATabBarColorModeKey];
    if (raw < XCATabBarColorModeNative ||
        raw > XCATabBarColorModeAllTabs) {
        return XCATabBarColorModeNative;
    }

    return (XCATabBarColorMode)raw;
}

static NSString *XCATabBarColorModeTitle(XCATabBarColorMode mode) {
    switch (mode) {
        case XCATabBarColorModeActiveOnly:
            return @"Aba ativa";
        case XCATabBarColorModeAllTabs:
            return @"Todas as abas";
        case XCATabBarColorModeNative:
        default:
            return @"Nativa";
    }
}

#pragma mark - View helpers

static NSArray<UIView *> *XCACollectViewsMatching(
    UIView *root,
    BOOL (^predicate)(UIView *view)
) {
    if (!root || !predicate) return @[];

    NSMutableArray<UIView *> *result = [NSMutableArray array];
    NSMutableArray<UIView *> *queue =
        [NSMutableArray arrayWithObject:root];

    for (NSUInteger i = 0; i < queue.count && i < 512; i++) {
        UIView *view = queue[i];

        if (predicate(view)) {
            [result addObject:view];
        }

        for (UIView *subview in view.subviews ?: @[]) {
            [queue addObject:subview];
        }
    }

    return result;
}

static NSArray<UIView *> *XCAVisibleNavigationBars(void) {
    NSMutableArray<UIView *> *bars = [NSMutableArray array];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;

        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window || window.hidden) continue;

            NSArray<UIView *> *matches =
                XCACollectViewsMatching(window, ^BOOL(UIView *view) {
                    NSString *name = NSStringFromClass(view.class);
                    return [name isEqualToString:@"XNavigation.TabBarView"] ||
                           [name isEqualToString:@"_TtC11XNavigation10TabBarView"];
                });

            [bars addObjectsFromArray:matches];
        }
    }

    return bars;
}

#pragma mark - Theme color resolver

static UIColor *XCAResolvedThemeAccentColor(UIView *navigationBar) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger option = 0;

    id nfb = [defaults objectForKey:@"bh_color_theme_selectedColor"];
    if ([nfb respondsToSelector:@selector(integerValue)]) {
        option = [nfb integerValue];
    } else {
        id native =
            [defaults objectForKey:@"T1ColorSettingsPrimaryColorOptionKey"];
        if ([native respondsToSelector:@selector(integerValue)]) {
            option = [native integerValue];
        }
    }

    if (option < 1) option = 1;

    Class settingsClass = NSClassFromString(@"TAEColorSettings");
    SEL sharedSEL = NSSelectorFromString(@"sharedSettings");

    if (settingsClass && [settingsClass respondsToSelector:sharedSEL]) {
        id settings =
            ((id(*)(id,SEL))objc_msgSend)(settingsClass, sharedSEL);

        SEL infoSEL = NSSelectorFromString(@"currentColorPalette");
        id info =
            (settings && [settings respondsToSelector:infoSEL])
                ? ((id(*)(id,SEL))objc_msgSend)(settings, infoSEL)
                : nil;

        SEL paletteSEL = NSSelectorFromString(@"colorPalette");
        id palette =
            (info && [info respondsToSelector:paletteSEL])
                ? ((id(*)(id,SEL))objc_msgSend)(info, paletteSEL)
                : nil;

        SEL primarySEL = NSSelectorFromString(@"primaryColorForOption:");
        if (palette && [palette respondsToSelector:primarySEL]) {
            id themeColor =
                ((id(*)(id,SEL,NSUInteger))objc_msgSend)(
                    palette,
                    primarySEL,
                    (NSUInteger)option
                );

            if ([themeColor isKindOfClass:UIColor.class]) {
                return themeColor;
            }
        }
    }

    UIColor *fallback = navigationBar.tintColor;
    if (!fallback && navigationBar.window) {
        fallback = navigationBar.window.tintColor;
    }

    return fallback ?: UIColor.systemBlueColor;
}

#pragma mark - Validated Test8 visual path

static void XCATintImageViews(UIView *root, UIColor *color) {
    if (!root || !color) return;

    if ([root isKindOfClass:UIImageView.class]) {
        UIImageView *imageView = (UIImageView *)root;
        UIImage *image = imageView.image;

        if (image &&
            image.renderingMode != UIImageRenderingModeAlwaysTemplate) {
            imageView.image =
                [image imageWithRenderingMode:
                    UIImageRenderingModeAlwaysTemplate];
        }

        imageView.tintColor = color;
    }

    for (UIView *subview in root.subviews ?: @[]) {
        XCATintImageViews(subview, color);
    }
}

static UIView *XCAFindSelectionChrome(UIView *root) {
    if (!root) return nil;

    NSArray<UIView *> *matches =
        XCACollectViewsMatching(root, ^BOOL(UIView *view) {
            NSString *name = NSStringFromClass(view.class);

            return [name containsString:@"_UITabSelectionView"] ||
                   [name containsString:@"TabSelectionView"] ||
                   [name containsString:@"TabSelection"] ||
                   [name containsString:@"_UITabBarPlatterView"];
        });

    return matches.firstObject;
}

static void XCAApplySelectionChrome(UIView *chrome, UIColor *accent) {
    if (!chrome || !accent) return;

    chrome.tintColor = accent;

    UIColor *background = chrome.backgroundColor;
    CGFloat r = 0, g = 0, b = 0, a = 0;

    BOOL resolved =
        [background getRed:&r green:&g blue:&b alpha:&a];

    if (!resolved) {
        CGFloat white = 0;
        resolved = [background getWhite:&white alpha:&a];
    }

    if (resolved && a > 0.01) {
        chrome.backgroundColor =
            [accent colorWithAlphaComponent:a];
    }

    for (UIView *subview in chrome.subviews ?: @[]) {
        subview.tintColor = accent;
    }
}

static UIColor *XCANativeInactiveTabColor(void) {
    Class tabViewClass = NSClassFromString(@"T1TabView");
    SEL itemColorSEL = NSSelectorFromString(@"itemColor");

    if (tabViewClass &&
        [tabViewClass respondsToSelector:itemColorSEL]) {
        id color =
            ((id(*)(id,SEL))objc_msgSend)(
                tabViewClass,
                itemColorSEL
            );

        if ([color isKindOfClass:UIColor.class]) {
            return color;
        }
    }

    return UIColor.secondaryLabelColor;
}

static void XCARestorePrimaryNavigationRow(void) {
    if (XCATabBarColorModeValue() != XCATabBarColorModeActiveOnly ||
        gXCAThemeAccentEnabled) {
        return;
    }

    UIColor *inactive = XCANativeInactiveTabColor();

    for (UIView *bar in XCAVisibleNavigationBars()) {
        NSArray<UIView *> *primaryItems =
            XCACollectViewsMatching(bar, ^BOOL(UIView *view) {
                NSString *name = NSStringFromClass(view.class);

                BOOL item =
                    [name isEqualToString:@"XNavigation.TabBarItemView"] ||
                    [name containsString:@"TabBarItemView"];

                // Test7 probe proved that the primary visible row is the
                // TabBarItemView copy carrying accessibility labels.
                // Portal/Carried copies have no label and must remain accented.
                return item && view.accessibilityLabel.length > 0;
            });

        for (UIView *item in primaryItems) {
            NSArray<UIView *> *images =
                XCACollectViewsMatching(item, ^BOOL(UIView *view) {
                    return [view isKindOfClass:UIImageView.class];
                });

            for (UIImageView *imageView
                 in (NSArray<UIImageView *> *)images) {
                UIImage *image = imageView.image;

                if (image &&
                    image.renderingMode !=
                        UIImageRenderingModeAlwaysTemplate) {
                    imageView.image =
                        [image imageWithRenderingMode:
                            UIImageRenderingModeAlwaysTemplate];
                }

                imageView.tintColor = inactive;
            }
        }
    }
}

#pragma mark - Refresh

static void XCARefreshPass(void) {
    for (UIView *bar in XCAVisibleNavigationBars()) {
        [bar setNeedsLayout];
        [bar layoutIfNeeded];
    }
}

static void XCARefreshNow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        XCARefreshPass();

        for (NSNumber *delayValue in @[@0.04, @0.12]) {
            NSTimeInterval delay = delayValue.doubleValue;

            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    (int64_t)(delay * NSEC_PER_SEC)
                ),
                dispatch_get_main_queue(),
                ^{
                    XCARefreshPass();
                }
            );
        }
    });
}

static void XCASchedulePrimaryRowRestore(void) {
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(0.20 * NSEC_PER_SEC)
        ),
        dispatch_get_main_queue(),
        ^{
            XCARestorePrimaryNavigationRow();
        }
    );
}

#pragma mark - XNavigation hook

static void XCANavigationLayoutSubviews(id self, SEL cmd) {
    if (gOrigXCANavigationLayoutSubviews) {
        ((void(*)(id,SEL))gOrigXCANavigationLayoutSubviews)(
            self,
            cmd
        );
    }

    if (![self isKindOfClass:UIView.class]) return;
    if (!gXCAThemeAccentEnabled) return;

    UIView *bar = (UIView *)self;
    UIColor *accent = XCAResolvedThemeAccentColor(bar);

    XCATintImageViews(bar, accent);

    UIView *chrome = XCAFindSelectionChrome(bar);
    XCAApplySelectionChrome(chrome, accent);

    if (gXCAActiveOnlyNeedsPrime &&
        XCATabBarColorModeValue() ==
            XCATabBarColorModeActiveOnly) {
        gXCAActiveOnlyNeedsPrime = NO;

        // Exact Test8 sequence:
        // allow the fully accented layout to settle, then turn the
        // accent pass off and restore only the labeled primary row.
        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(0.75 * NSEC_PER_SEC)
            ),
            dispatch_get_main_queue(),
            ^{
                if (XCATabBarColorModeValue() !=
                    XCATabBarColorModeActiveOnly) {
                    return;
                }

                gXCAThemeAccentEnabled = NO;
                XCARefreshNow();
                XCASchedulePrimaryRowRestore();
            }
        );
    }
}

static void XCAInstallNavigationHook(void) {
    if (gXCANavigationHookInstalled) return;
    if (!gXCAAllowNavigationHook) return;

    Class cls =
        NSClassFromString(@"_TtC11XNavigation10TabBarView");

    if (!cls) {
        cls = NSClassFromString(@"XNavigation.TabBarView");
    }

    if (!cls) return;

    gXCANavigationHookInstalled =
        XCAHookMethod(
            cls,
            @selector(layoutSubviews),
            (IMP)XCANavigationLayoutSubviews,
            &gOrigXCANavigationLayoutSubviews
        );
}

#pragma mark - Theme preference refresh

static BOOL XCAIsThemeColorPreferenceKey(NSString *key) {
    if (![key isKindOfClass:NSString.class]) return NO;

    return [key isEqualToString:
                @"bh_color_theme_selectedColor"] ||
           [key isEqualToString:
                @"T1ColorSettingsPrimaryColorOptionKey"];
}

static void XCAThemePreferenceChanged(void) {
    XCATabBarColorMode mode = XCATabBarColorModeValue();

    if (mode == XCATabBarColorModeNative) return;

    if (mode == XCATabBarColorModeAllTabs) {
        gXCAThemeAccentEnabled = YES;
        gXCAActiveOnlyNeedsPrime = NO;
        XCARefreshNow();
        return;
    }

    // Active Only needs the same validated ON -> OFF transition so the
    // Portal copy receives the new accent before the primary row resets.
    gXCAThemeAccentEnabled = YES;
    gXCAActiveOnlyNeedsPrime = YES;
    XCARefreshNow();
}

static void XCADefaultsSetInteger(id self,
                                  SEL cmd,
                                  NSInteger value,
                                  NSString *key) {
    if (gOrigXCADefaultsSetInteger) {
        ((void(*)(id,SEL,NSInteger,NSString *))
            gOrigXCADefaultsSetInteger)(
                self,
                cmd,
                value,
                key
            );
    }

    if (XCAIsThemeColorPreferenceKey(key)) {
        XCAThemePreferenceChanged();
    }
}

static void XCADefaultsSetObject(id self,
                                 SEL cmd,
                                 id value,
                                 NSString *key) {
    if (gOrigXCADefaultsSetObject) {
        ((void(*)(id,SEL,id,NSString *))
            gOrigXCADefaultsSetObject)(
                self,
                cmd,
                value,
                key
            );
    }

    if (XCAIsThemeColorPreferenceKey(key)) {
        XCAThemePreferenceChanged();
    }
}

static void XCAInstallThemePreferenceHooks(void) {
    if (gXCAThemeDefaultsHooksInstalled) return;

    Class cls = NSUserDefaults.class;

    BOOL integerHooked =
        XCAHookMethod(
            cls,
            @selector(setInteger:forKey:),
            (IMP)XCADefaultsSetInteger,
            &gOrigXCADefaultsSetInteger
        );

    BOOL objectHooked =
        XCAHookMethod(
            cls,
            @selector(setObject:forKey:),
            (IMP)XCADefaultsSetObject,
            &gOrigXCADefaultsSetObject
        );

    gXCAThemeDefaultsHooksInstalled =
        integerHooked || objectHooked;
}

#pragma mark - Liquid Glass settings extension

static NSInteger XCAOriginalSettingsRowCount(
    id controller,
    UITableView *tableView,
    NSInteger section
) {
    if (!gOrigXCASettingsRows) return 0;

    return ((NSInteger(*)(id,SEL,UITableView *,NSInteger))
        gOrigXCASettingsRows)(
            controller,
            @selector(tableView:numberOfRowsInSection:),
            tableView,
            section
        );
}

static BOOL XCAIsAddonIndexPath(id controller,
                                UITableView *tableView,
                                NSIndexPath *indexPath) {
    if (!indexPath || indexPath.section != 0) return NO;

    NSInteger base =
        XCAOriginalSettingsRowCount(
            controller,
            tableView,
            indexPath.section
        );

    return indexPath.row == base;
}

static NSInteger XCASettingsRows(id self,
                                 SEL cmd,
                                 UITableView *tableView,
                                 NSInteger section) {
    NSInteger base = 0;

    if (gOrigXCASettingsRows) {
        base =
            ((NSInteger(*)(id,SEL,UITableView *,NSInteger))
                gOrigXCASettingsRows)(
                    self,
                    cmd,
                    tableView,
                    section
                );
    }

    return section == 0 ? base + 1 : base;
}

static UITableViewCell *XCASettingsCell(
    id self,
    SEL cmd,
    UITableView *tableView,
    NSIndexPath *indexPath
) {
    if (!XCAIsAddonIndexPath(self, tableView, indexPath)) {
        if (gOrigXCASettingsCell) {
            return
                ((UITableViewCell *(*)(id,SEL,UITableView *,NSIndexPath *))
                    gOrigXCASettingsCell)(
                        self,
                        cmd,
                        tableView,
                        indexPath
                    );
        }

        return [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault
          reuseIdentifier:nil];
    }

    static NSString *const identifier =
        @"XLiquidGlassColorAddonCell";

    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {
        cell =
            [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleSubtitle
              reuseIdentifier:identifier];
    }

    cell.textLabel.text = @"Cor do tema na Tab Bar";
    cell.detailTextLabel.text =
        XCATabBarColorModeTitle(XCATabBarColorModeValue());
    cell.accessoryView = nil;
    cell.accessoryType =
        UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle =
        UITableViewCellSelectionStyleDefault;

    return cell;
}

static void XCAApplySelectedMode(id controller,
                                 UITableView *tableView,
                                 XCATabBarColorMode newMode) {
    XCATabBarColorMode oldMode = XCATabBarColorModeValue();

    if (newMode == oldMode) {
        [tableView reloadData];
        return;
    }

    [NSUserDefaults.standardUserDefaults
        setInteger:newMode
            forKey:kXCATabBarColorModeKey];

    BOOL oldNeedsHook =
        oldMode != XCATabBarColorModeNative;
    BOOL newNeedsHook =
        newMode != XCATabBarColorModeNative;

    BOOL requiresRestart =
        oldNeedsHook != newNeedsHook;

    if (newMode == XCATabBarColorModeAllTabs) {
        gXCAThemeAccentEnabled = YES;
        gXCAActiveOnlyNeedsPrime = NO;

        if (!requiresRestart) {
            XCARefreshNow();
        }
    } else if (newMode == XCATabBarColorModeActiveOnly) {
        if (requiresRestart) {
            // The hook is intentionally absent on a Native startup.
            // Constructor will execute the validated prime after restart.
            gXCAThemeAccentEnabled = YES;
            gXCAActiveOnlyNeedsPrime = YES;
        } else {
            // Live All Tabs -> Active Only reproduces Test8's OFF phase.
            gXCAThemeAccentEnabled = NO;
            gXCAActiveOnlyNeedsPrime = NO;
            XCARefreshNow();
            XCASchedulePrimaryRowRestore();
        }
    } else {
        gXCAThemeAccentEnabled = NO;
        gXCAActiveOnlyNeedsPrime = NO;
    }

    [tableView reloadData];

    if (requiresRestart &&
        [controller isKindOfClass:UIViewController.class]) {
        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"Liquid Glass"
                                 message:
                    @"Reinicie o X para aplicar completamente esta alteração."
                          preferredStyle:
                    UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction
                actionWithTitle:@"OK"
                          style:UIAlertActionStyleDefault
                        handler:nil]];

        [(UIViewController *)controller
            presentViewController:alert
                         animated:YES
                       completion:nil];
    }
}

static void XCAShowColorModeSelector(id controller,
                                     UITableView *tableView,
                                     NSIndexPath *indexPath) {
    if (![controller isKindOfClass:UIViewController.class]) return;

    UIAlertController *sheet =
        [UIAlertController
            alertControllerWithTitle:@"Cor do tema na Tab Bar"
                             message:nil
                      preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSNumber *> *modes = @[
        @(XCATabBarColorModeNative),
        @(XCATabBarColorModeActiveOnly),
        @(XCATabBarColorModeAllTabs)
    ];

    for (NSNumber *number in modes) {
        XCATabBarColorMode mode =
            (XCATabBarColorMode)number.integerValue;

        UIAlertAction *action =
            [UIAlertAction
                actionWithTitle:XCATabBarColorModeTitle(mode)
                          style:UIAlertActionStyleDefault
                        handler:^(__unused UIAlertAction *selected) {
                            XCAApplySelectedMode(
                                controller,
                                tableView,
                                mode
                            );
                        }];

        if (mode == XCATabBarColorModeValue()) {
            [action setValue:@YES forKey:@"checked"];
        }

        [sheet addAction:action];
    }

    [sheet addAction:
        [UIAlertAction
            actionWithTitle:@"Cancelar"
                      style:UIAlertActionStyleCancel
                    handler:nil]];

    UIPopoverPresentationController *popover =
        sheet.popoverPresentationController;

    if (popover) {
        popover.sourceView = tableView;
        popover.sourceRect =
            [tableView rectForRowAtIndexPath:indexPath];
    }

    [(UIViewController *)controller
        presentViewController:sheet
                     animated:YES
                   completion:nil];
}

static void XCASettingsDidSelect(id self,
                                 SEL cmd,
                                 UITableView *tableView,
                                 NSIndexPath *indexPath) {
    if (XCAIsAddonIndexPath(self, tableView, indexPath)) {
        [tableView
            deselectRowAtIndexPath:indexPath
                         animated:YES];

        XCAShowColorModeSelector(
            self,
            tableView,
            indexPath
        );
        return;
    }

    if (gOrigXCASettingsDidSelect) {
        ((void(*)(id,SEL,UITableView *,NSIndexPath *))
            gOrigXCASettingsDidSelect)(
                self,
                cmd,
                tableView,
                indexPath
            );
    }
}

static void XCAInstallSettingsExtension(void) {
    if (gXCASettingsHooksInstalled) return;

    Class cls =
        NSClassFromString(
            @"XLiquidGlassSettingsViewController"
        );

    if (!cls) return;

    BOOL rows =
        XCAHookMethod(
            cls,
            @selector(tableView:numberOfRowsInSection:),
            (IMP)XCASettingsRows,
            &gOrigXCASettingsRows
        );

    BOOL cell =
        XCAHookMethod(
            cls,
            @selector(tableView:cellForRowAtIndexPath:),
            (IMP)XCASettingsCell,
            &gOrigXCASettingsCell
        );

    BOOL selection =
        XCAHookMethod(
            cls,
            @selector(tableView:didSelectRowAtIndexPath:),
            (IMP)XCASettingsDidSelect,
            &gOrigXCASettingsDidSelect
        );

    gXCASettingsHooksInstalled =
        rows && cell && selection;
}

#pragma mark - Install

static void XCAInstall(void) {
    XCAInstallNavigationHook();
    XCAInstallThemePreferenceHooks();
    XCAInstallSettingsExtension();
}

static void XCAScheduleInstallRetry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(delay * NSEC_PER_SEC)
        ),
        dispatch_get_main_queue(),
        ^{
            XCAInstall();
        }
    );
}

__attribute__((constructor))
static void XLiquidGlassColorAddonInit(void) {
    @autoreleasepool {
        XCATabBarColorMode startupMode =
            XCATabBarColorModeValue();

        gXCAAllowNavigationHook =
            startupMode != XCATabBarColorModeNative;

        if (startupMode == XCATabBarColorModeAllTabs) {
            gXCAThemeAccentEnabled = YES;
            gXCAActiveOnlyNeedsPrime = NO;
        } else if (startupMode ==
                   XCATabBarColorModeActiveOnly) {
            gXCAThemeAccentEnabled = YES;
            gXCAActiveOnlyNeedsPrime = YES;
        } else {
            gXCAThemeAccentEnabled = NO;
            gXCAActiveOnlyNeedsPrime = NO;
        }

        NSLog(@"[XLiquidGlassColorAddon] 2.0 Color Add-on loaded");

        XCAInstall();

        for (NSNumber *delayValue
             in @[@0.05, @0.20, @0.50, @1.00, @2.00, @4.00]) {
            XCAScheduleInstallRetry(
                delayValue.doubleValue
            );
        }
    }
}
