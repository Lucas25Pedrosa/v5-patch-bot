#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

// XLiquidGlassNative 3.1 Beta 8
// Built directly from the proven Beta 7 / Beta 2 icon resolver.
// Active-tab tint keeps the validated XLiquidGlass 2.0.2 Portal/Carried model:
// labeled primary items keep X's native inactive tint, while unlabeled
// Portal/Carried copies keep the NFB accent and X reveals the active copy.
// Beta 8 only adds a restart notice when switching back to Native mode.
// No polling, selection hooks, badge/sidebar/blur/label/navigation fixes.

static NSString *const kXLG31TabTintModeKey = @"XLiquidGlassTabBarTintMode";

typedef NS_ENUM(NSInteger, XLG31TabTintMode) {
    XLG31TabTintModeNative = 0,
    XLG31TabTintModeActive = 1,
    XLG31TabTintModeAll = 2,
};

static IMP gXLG31OrigItemLayout = NULL;
static BOOL gXLG31ItemHooked = NO;

static IMP gXLG31OrigSettingsSections = NULL;
static IMP gXLG31OrigSettingsRows = NULL;
static IMP gXLG31OrigSettingsCell = NULL;
static IMP gXLG31OrigSettingsFooter = NULL;
static IMP gXLG31OrigSettingsDidSelect = NULL;
static BOOL gXLG31SettingsHooked = NO;

#pragma mark - Helpers

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

#pragma mark - Colors

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

// Exact 2.0.2 inactive-color path.
static UIColor *XLG31NativeInactiveTabColor(void) {
    Class tabViewClass = NSClassFromString(@"T1TabView");
    SEL itemColorSEL = NSSelectorFromString(@"itemColor");
    if (tabViewClass && [tabViewClass respondsToSelector:itemColorSEL]) {
        id color = ((id(*)(id,SEL))objc_msgSend)(tabViewClass, itemColorSEL);
        if ([color isKindOfClass:UIColor.class]) return color;
    }
    return UIColor.secondaryLabelColor;
}

#pragma mark - XNavigation.TabBarItemView

static UIView *XLG31AncestorNamed(UIView *view, NSString *name) {
    UIView *cursor = view.superview;
    while (cursor) {
        NSString *className = NSStringFromClass(cursor.class);
        if ([className isEqualToString:name] ||
            [className hasSuffix:[@"." stringByAppendingString:name.lastPathComponent]]) {
            return cursor;
        }
        if ([className isEqualToString:@"XNavigation.TabBarView"]) return cursor;
        cursor = cursor.superview;
    }
    return nil;
}

static BOOL XLG31ItemIsProfile(UIView *item) {
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

static UIImageView *XLG31FindImageViewRecursive(UIView *root, NSUInteger depth) {
    if (!root || depth > 6) return nil;
    if ([root isKindOfClass:UIImageView.class]) return (UIImageView *)root;

    for (UIView *subview in root.subviews ?: @[]) {
        UIImageView *found = XLG31FindImageViewRecursive(subview, depth + 1);
        if (found) return found;
    }
    return nil;
}

// Keep the Beta 2 resolver intact: this is the resolver that actually painted
// all tabs on X 12.35 in device testing.
static UIImageView *XLG31ImageViewForItem(UIView *item) {
    if (!item) return nil;

    for (UIView *subview in item.subviews ?: @[]) {
        if ([subview isKindOfClass:UIImageView.class]) {
            return (UIImageView *)subview;
        }
    }

    id direct = XLG31SafeValueForKey(item, @"imageView");
    if ([direct isKindOfClass:UIImageView.class]) {
        return (UIImageView *)direct;
    }

    id glyphContainer = XLG31SafeValueForKey(item, @"glyphContainer");
    if ([glyphContainer isKindOfClass:UIView.class]) {
        UIImageView *inside = XLG31FindImageViewRecursive((UIView *)glyphContainer, 0);
        if (inside) return inside;
    }

    return XLG31FindImageViewRecursive(item, 0);
}

static void XLG31ApplyTintToItem(UIView *item) {
    if (!item || XLG31ItemIsProfile(item)) return;

    XLG31TabTintMode mode = XLG31TintMode();
    if (mode == XLG31TabTintModeNative) return;

    UIImageView *imageView = XLG31ImageViewForItem(item);
    if (!imageView || !imageView.image) return;

    UIColor *accent = XLG31ResolvedThemeColor();
    UIColor *inactive = XLG31NativeInactiveTabColor();
    UIView *bar = XLG31AncestorNamed(item, @"XNavigation.TabBarView");

    UIColor *color = nil;
    if (mode == XLG31TabTintModeAll) {
        color = accent;
    } else {
        // Ported literally from the validated 2.0.2 Test7/Test8 model.
        // Primary visible row items carry accessibility labels and stay native.
        // Unlabeled Portal/Carried copies carry the accent. X's Liquid Glass
        // portal reveals the accented copy only for the currently active tab.
        color = item.accessibilityLabel.length ? inactive : accent;
    }

    if (imageView.image.renderingMode != UIImageRenderingModeAlwaysTemplate) {
        imageView.image =
            [imageView.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    imageView.tintColor = color;

    if (mode == XLG31TabTintModeAll) {
        item.tintColor = accent;
    } else {
        // Also mirrors 2.0.2: the item itself remains on the bar/native tint;
        // only the Portal/Carried UIImageView copies hold the accent.
        item.tintColor = bar.tintColor ?: inactive;
    }
}

static void XLG31ItemLayout(id self, SEL _cmd) {
    if (gXLG31OrigItemLayout) {
        ((void(*)(id,SEL))gXLG31OrigItemLayout)(self, _cmd);
    }

    if ([self isKindOfClass:UIView.class]) {
        XLG31ApplyTintToItem((UIView *)self);
    }
}

static Class XLG31ItemClass(void) {
    Class cls = NSClassFromString(@"XNavigation.TabBarItemView");
    if (!cls) cls = NSClassFromString(@"_TtC11XNavigation14TabBarItemView");
    return cls;
}

static void XLG31InstallItemHook(void) {
    if (gXLG31ItemHooked) return;

    Class cls = XLG31ItemClass();
    if (!cls) return;

    gXLG31ItemHooked = XLG31HookMethod(
        cls,
        @selector(layoutSubviews),
        (IMP)XLG31ItemLayout,
        &gXLG31OrigItemLayout
    );
}

static BOOL XLG31ViewIsItem(UIView *view, Class itemClass) {
    if (!view) return NO;
    if (itemClass && [view isKindOfClass:itemClass]) return YES;
    NSString *name = NSStringFromClass(view.class);
    return [name isEqualToString:@"XNavigation.TabBarItemView"] ||
           [name hasSuffix:@".TabBarItemView"];
}

static void XLG31RefreshViewTree(UIView *view, Class itemClass) {
    if (!view) return;

    if (XLG31ViewIsItem(view, itemClass)) {
        [view setNeedsLayout];
        [view layoutIfNeeded];
    }

    for (UIView *subview in view.subviews ?: @[]) {
        XLG31RefreshViewTree(subview, itemClass);
    }
}

static void XLG31RefreshTabItems(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class itemClass = XLG31ItemClass();
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window.hidden) XLG31RefreshViewTree(window, itemClass);
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

    XLG31TabTintMode selectedMode = (XLG31TabTintMode)indexPath.row;
    XLG31SetTintMode(selectedMode);
    [tableView reloadData];
    XLG31RefreshTabItems();

    if (selectedMode == XLG31TabTintModeNative) {
        NSString *title = XLG31IsPortuguese() ? @"Reiniciar o X" : @"Restart X";
        NSString *message = XLG31IsPortuguese()
            ? @"Reinicie o X para restaurar completamente a coloração nativa da Tab Bar."
            : @"Restart X to fully restore the native Tab Bar coloring.";

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:title
                                                message:message
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                 style:UIAlertActionStyleDefault
                                               handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
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
    XLG31InstallItemHook();
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
        NSLog(@"[XLiquidGlassNative] 3.1 Beta 8 tab tint - 2.0.2 Portal/Carried model loaded");
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
