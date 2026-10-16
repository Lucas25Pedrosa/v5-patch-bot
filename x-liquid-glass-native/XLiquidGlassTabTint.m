#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

// XLiquidGlassNative 3.1 Beta 1
// Isolated Tab Bar icon tint module for X 12.35+.
// Intentionally does NOT implement badges, sidebar, tab labels, pill/platter
// tinting, navigation fixes, blur fixes, legacy hosts or any other visual fix.

static NSString *const kXLG31TabTintModeKey = @"XLiquidGlassTabBarTintMode";

typedef NS_ENUM(NSInteger, XLG31TabTintMode) {
    XLG31TabTintModeNative = 0,
    XLG31TabTintModeActive = 1,
    XLG31TabTintModeAll = 2,
};

static IMP gXLG31OrigTabBarLayout = NULL;
static BOOL gXLG31TabBarHooked = NO;

static IMP gXLG31OrigSettingsSections = NULL;
static IMP gXLG31OrigSettingsRows = NULL;
static IMP gXLG31OrigSettingsCell = NULL;
static IMP gXLG31OrigSettingsFooter = NULL;
static IMP gXLG31OrigSettingsDidSelect = NULL;
static BOOL gXLG31SettingsHooked = NO;

#pragma mark - Small helpers

static id XLG31SafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL XLG31HookMethod(Class cls,
                            SEL sel,
                            IMP replacement,
                            IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP current = class_getMethodImplementation(cls, sel);
    if (current == replacement) return YES;

    if (originalOut && !*originalOut) *originalOut = current;
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    return class_getMethodImplementation(cls, sel) == replacement;
}

static XLG31TabTintMode XLG31TintMode(void) {
    NSInteger mode = [[NSUserDefaults standardUserDefaults]
        integerForKey:kXLG31TabTintModeKey];
    if (mode < XLG31TabTintModeNative || mode > XLG31TabTintModeAll) {
        mode = XLG31TabTintModeNative;
    }
    return (XLG31TabTintMode)mode;
}

static void XLG31SetTintMode(XLG31TabTintMode mode) {
    if (mode < XLG31TabTintModeNative || mode > XLG31TabTintModeAll) {
        mode = XLG31TabTintModeNative;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:mode
                                               forKey:kXLG31TabTintModeKey];
}

static BOOL XLG31IsPortuguese(void) {
    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"";
    return [language hasPrefix:@"pt"];
}

static NSString *XLG31TintTitle(void) {
    return XLG31IsPortuguese() ? @"Coloração da Tab Bar" : @"Tab Bar Tint";
}

static NSString *XLG31TintDetail(void) {
    return XLG31IsPortuguese()
        ? @"Escolha quais ícones usam a cor do tema."
        : @"Choose which icons use the theme color.";
}

static NSString *XLG31ModeTitle(XLG31TabTintMode mode) {
    if (XLG31IsPortuguese()) {
        switch (mode) {
            case XLG31TabTintModeActive: return @"Aba ativa";
            case XLG31TabTintModeAll: return @"Todas as abas";
            default: return @"Nativa";
        }
    }

    switch (mode) {
        case XLG31TabTintModeActive: return @"Active tab";
        case XLG31TabTintModeAll: return @"All tabs";
        default: return @"Native";
    }
}

#pragma mark - NFB theme color

static UIColor *XLG31ResolvedThemeColor(void) {
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

#pragma mark - X 12.35 Tab Bar icon path

static BOOL XLG31ItemIsProfile(UIView *item) {
    NSMutableString *identity = [NSMutableString string];
    for (NSString *part in @[
        item.accessibilityLabel ?: @"",
        item.accessibilityIdentifier ?: @"",
        item.accessibilityHint ?: @""
    ]) {
        if (part.length) [identity appendFormat:@" %@", part.lowercaseString];
    }

    return [identity containsString:@"perfil"] ||
           [identity containsString:@"profile"] ||
           [identity containsString:@"conta"] ||
           [identity containsString:@"account"];
}

static UIImageView *XLG31FindImageViewRecursive(UIView *root, NSUInteger depth) {
    if (!root || depth > 5) return nil;

    if ([root isKindOfClass:UIImageView.class]) {
        return (UIImageView *)root;
    }

    for (UIView *subview in root.subviews ?: @[]) {
        UIImageView *found = XLG31FindImageViewRecursive(subview, depth + 1);
        if (found) return found;
    }
    return nil;
}

static UIImageView *XLG31ImageViewForItem(UIView *item) {
    if (!item) return nil;

    // X 12.35 exposes an imageView field but may place it under glyphContainer.
    // Prefer the semantic field; fall back to a recursive view walk so the tint
    // survives small internal hierarchy changes without touching other UI.
    id direct = XLG31SafeValueForKey(item, @"imageView");
    if ([direct isKindOfClass:UIImageView.class]) {
        return (UIImageView *)direct;
    }

    id glyphContainer = XLG31SafeValueForKey(item, @"glyphContainer");
    if ([glyphContainer isKindOfClass:UIView.class]) {
        UIImageView *insideGlyph = XLG31FindImageViewRecursive(
            (UIView *)glyphContainer, 0);
        if (insideGlyph) return insideGlyph;
    }

    return XLG31FindImageViewRecursive(item, 0);
}

static void XLG31ApplyTintToTabBar(UIView *tabBar) {
    XLG31TabTintMode mode = XLG31TintMode();
    if (mode == XLG31TabTintModeNative || !tabBar) return;

    id itemViewsValue = XLG31SafeValueForKey(tabBar, @"itemViews");
    id selectedValue = XLG31SafeValueForKey(tabBar, @"selectedIndex");
    if (![itemViewsValue isKindOfClass:NSArray.class]) return;

    NSArray *itemViews = (NSArray *)itemViewsValue;
    NSInteger selectedIndex = [selectedValue respondsToSelector:@selector(integerValue)]
        ? [selectedValue integerValue]
        : NSNotFound;

    UIColor *themeColor = XLG31ResolvedThemeColor();

    [itemViews enumerateObjectsUsingBlock:^(id object, NSUInteger index, BOOL *stop) {
        (void)stop;
        if (![object isKindOfClass:UIView.class]) return;

        UIView *item = (UIView *)object;
        if (XLG31ItemIsProfile(item)) return;

        BOOL selected = ((item.accessibilityTraits & UIAccessibilityTraitSelected) != 0) ||
                        ((NSInteger)index == selectedIndex);
        BOOL shouldTint = (mode == XLG31TabTintModeAll) ||
                          (mode == XLG31TabTintModeActive && selected);
        if (!shouldTint) return;

        UIImageView *imageView = XLG31ImageViewForItem(item);
        if (!imageView || !imageView.image) return;

        if (imageView.image.renderingMode != UIImageRenderingModeAlwaysTemplate) {
            imageView.image = [imageView.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        imageView.tintColor = themeColor;
    }];
}

static void XLG31TabBarLayout(id self, SEL _cmd) {
    if (gXLG31OrigTabBarLayout) {
        ((void(*)(id,SEL))gXLG31OrigTabBarLayout)(self, _cmd);
    }
    if ([self isKindOfClass:UIView.class]) {
        XLG31ApplyTintToTabBar((UIView *)self);
    }
}

static void XLG31InstallTabBarHook(void) {
    if (gXLG31TabBarHooked) return;

    Class cls = NSClassFromString(@"_TtC11XNavigation10TabBarView");
    if (!cls) cls = NSClassFromString(@"XNavigation.TabBarView");
    if (!cls) return;

    gXLG31TabBarHooked = XLG31HookMethod(
        cls,
        @selector(layoutSubviews),
        (IMP)XLG31TabBarLayout,
        &gXLG31OrigTabBarLayout
    );
}

static void XLG31RefreshViewTree(UIView *view, Class tabBarClass) {
    if (!view) return;
    if ((tabBarClass && [view isKindOfClass:tabBarClass]) ||
        [NSStringFromClass(view.class) isEqualToString:@"XNavigation.TabBarView"]) {
        [view setNeedsLayout];
        [view layoutIfNeeded];
    }
    for (UIView *subview in view.subviews ?: @[]) {
        XLG31RefreshViewTree(subview, tabBarClass);
    }
}

static void XLG31RefreshTabBars(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class tabBarClass = NSClassFromString(@"_TtC11XNavigation10TabBarView");
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window.hidden) XLG31RefreshViewTree(window, tabBarClass);
            }
        }
    });
}

#pragma mark - Three-choice tint menu

@interface XLiquidGlassTabTintSettingsViewController : UITableViewController
@end

@implementation XLiquidGlassTabTintSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = XLG31TintTitle();
    self.tableView.backgroundColor = UIColor.systemBackgroundColor;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 3;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"XLiquidGlass31TintModeCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];
    }

    XLG31TabTintMode rowMode = (XLG31TabTintMode)indexPath.row;
    cell.textLabel.text = XLG31ModeTitle(rowMode);
    cell.accessoryType = (XLG31TintMode() == rowMode)
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    XLG31SetTintMode((XLG31TabTintMode)indexPath.row);
    [tableView reloadData];
    XLG31RefreshTabBars();
}

@end

static NSInteger XLG31SettingsNumberOfSections(id self, SEL _cmd, UITableView *tableView) {
    NSInteger original = gXLG31OrigSettingsSections
        ? ((NSInteger(*)(id,SEL,UITableView *))gXLG31OrigSettingsSections)(self, _cmd, tableView)
        : 1;
    return original + 1;
}

static NSInteger XLG31SettingsRows(id self,
                                   SEL _cmd,
                                   UITableView *tableView,
                                   NSInteger section) {
    NSInteger originalSections = gXLG31OrigSettingsSections
        ? ((NSInteger(*)(id,SEL,UITableView *))gXLG31OrigSettingsSections)(
            self, @selector(numberOfSectionsInTableView:), tableView)
        : 1;

    if (section == originalSections) return 1;
    return gXLG31OrigSettingsRows
        ? ((NSInteger(*)(id,SEL,UITableView *,NSInteger))gXLG31OrigSettingsRows)(
            self, _cmd, tableView, section)
        : 0;
}

static UITableViewCell *XLG31SettingsCell(id self,
                                          SEL _cmd,
                                          UITableView *tableView,
                                          NSIndexPath *indexPath) {
    NSInteger originalSections = gXLG31OrigSettingsSections
        ? ((NSInteger(*)(id,SEL,UITableView *))gXLG31OrigSettingsSections)(
            self, @selector(numberOfSectionsInTableView:), tableView)
        : 1;

    if (indexPath.section == originalSections) {
        static NSString *identifier = @"XLiquidGlass31TintEntryCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                          reuseIdentifier:identifier];
        }
        cell.textLabel.text = XLG31TintTitle();
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@",
                                     XLG31TintDetail(),
                                     XLG31ModeTitle(XLG31TintMode())];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.numberOfLines = 2;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    return gXLG31OrigSettingsCell
        ? ((UITableViewCell *(*)(id,SEL,UITableView *,NSIndexPath *))gXLG31OrigSettingsCell)(
            self, _cmd, tableView, indexPath)
        : [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                 reuseIdentifier:nil];
}

static NSString *XLG31SettingsFooter(id self,
                                     SEL _cmd,
                                     UITableView *tableView,
                                     NSInteger section) {
    NSInteger originalSections = gXLG31OrigSettingsSections
        ? ((NSInteger(*)(id,SEL,UITableView *))gXLG31OrigSettingsSections)(
            self, @selector(numberOfSectionsInTableView:), tableView)
        : 1;

    if (section == originalSections) return nil;
    return gXLG31OrigSettingsFooter
        ? ((NSString *(*)(id,SEL,UITableView *,NSInteger))gXLG31OrigSettingsFooter)(
            self, _cmd, tableView, section)
        : nil;
}

static void XLG31SettingsDidSelect(id self,
                                   SEL _cmd,
                                   UITableView *tableView,
                                   NSIndexPath *indexPath) {
    NSInteger originalSections = gXLG31OrigSettingsSections
        ? ((NSInteger(*)(id,SEL,UITableView *))gXLG31OrigSettingsSections)(
            self, @selector(numberOfSectionsInTableView:), tableView)
        : 1;

    if (indexPath.section == originalSections) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        if ([self isKindOfClass:UIViewController.class]) {
            XLiquidGlassTabTintSettingsViewController *controller =
                [[XLiquidGlassTabTintSettingsViewController alloc] init];
            UINavigationController *nav = ((UIViewController *)self).navigationController;
            if (nav) {
                [nav pushViewController:controller animated:YES];
            } else {
                UINavigationController *wrapper =
                    [[UINavigationController alloc] initWithRootViewController:controller];
                [(UIViewController *)self presentViewController:wrapper
                                                      animated:YES
                                                    completion:nil];
            }
        }
        return;
    }

    if (gXLG31OrigSettingsDidSelect) {
        ((void(*)(id,SEL,UITableView *,NSIndexPath *))gXLG31OrigSettingsDidSelect)(
            self, _cmd, tableView, indexPath);
    }
}

static void XLG31InstallSettingsIntegration(void) {
    if (gXLG31SettingsHooked) return;

    Class cls = NSClassFromString(@"XLiquidGlassNativeSettingsViewController");
    if (!cls) return;

    BOOL sections = XLG31HookMethod(
        cls,
        @selector(numberOfSectionsInTableView:),
        (IMP)XLG31SettingsNumberOfSections,
        &gXLG31OrigSettingsSections);

    BOOL rows = XLG31HookMethod(
        cls,
        @selector(tableView:numberOfRowsInSection:),
        (IMP)XLG31SettingsRows,
        &gXLG31OrigSettingsRows);

    BOOL cell = XLG31HookMethod(
        cls,
        @selector(tableView:cellForRowAtIndexPath:),
        (IMP)XLG31SettingsCell,
        &gXLG31OrigSettingsCell);

    XLG31HookMethod(
        cls,
        @selector(tableView:titleForFooterInSection:),
        (IMP)XLG31SettingsFooter,
        &gXLG31OrigSettingsFooter);

    SEL didSelectSEL = @selector(tableView:didSelectRowAtIndexPath:);
    Method didSelectMethod = class_getInstanceMethod(cls, didSelectSEL);
    if (didSelectMethod) {
        XLG31HookMethod(cls,
                        didSelectSEL,
                        (IMP)XLG31SettingsDidSelect,
                        &gXLG31OrigSettingsDidSelect);
    } else {
        class_addMethod(cls, didSelectSEL, (IMP)XLG31SettingsDidSelect, "v@:@@");
    }

    gXLG31SettingsHooked = sections && rows && cell;
}

static void XLG31Install(void) {
    XLG31InstallTabBarHook();
    XLG31InstallSettingsIntegration();
}

static void XLG31ScheduleRetry(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        XLG31Install();
    });
}

__attribute__((constructor))
static void XLiquidGlass31TabTintInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlassNative] 3.1 Beta 1 tab icon tint module loaded");
        XLG31Install();
        XLG31ScheduleRetry(0.00);
        XLG31ScheduleRetry(0.05);
        XLG31ScheduleRetry(0.20);
        XLG31ScheduleRetry(0.50);
        XLG31ScheduleRetry(1.00);
        XLG31ScheduleRetry(2.00);
        XLG31ScheduleRetry(4.00);
    }
}
