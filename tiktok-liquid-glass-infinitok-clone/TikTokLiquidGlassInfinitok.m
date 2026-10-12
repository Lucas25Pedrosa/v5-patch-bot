#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>

static NSString *const kMasterKey   = @"liquid_glass_enabled";
static NSString *const kControlsKey = @"liquid_glass_controls";
static NSString *const kNoticesKey  = @"liquid_glass_notices";
static NSString *const kOverlaysKey = @"liquid_glass_overlays";
static NSString *const kBarKey      = @"liquid_glass_bar";
static NSString *const kBarLargeKey = @"liquid_glass_bar_large";
static NSString *const kSettingsIdentifier = @"tiktok_liquid_glass_settings";

static NSMutableDictionary<NSString *, NSValue *> *gOriginals;
static NSMutableSet<NSString *> *gInstalled;

static BOOL Pref(NSString *key) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}

static void SetPref(NSString *key, BOOL value) {
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static NSString *MethodKey(Class methodOwner, SEL sel) {
    return [NSString stringWithFormat:@"%p|%@", methodOwner, NSStringFromSelector(sel)];
}

static IMP FindOriginal(id self, SEL sel) {
    Class c = object_getClass(self);
    while (c) {
        NSValue *v = nil;
        @synchronized(gOriginals) { v = gOriginals[MethodKey(c, sel)]; }
        if (v) return [v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

static BOOL InstallHook(Class owner, BOOL classMethod, SEL sel, IMP replacement) {
    if (!owner || !sel || !replacement) return NO;
    Class methodOwner = classMethod ? object_getClass(owner) : owner;
    if (!methodOwner) return NO;
    Method m = class_getInstanceMethod(methodOwner, sel);
    if (!m) return NO;

    NSString *key = MethodKey(methodOwner, sel);
    @synchronized(gInstalled) {
        if ([gInstalled containsObject:key]) return YES;

        IMP original = method_getImplementation(m);
        if (!original || original == replacement) {
            [gInstalled addObject:key];
            return YES;
        }
        const char *types = method_getTypeEncoding(m);
        gOriginals[key] = [NSValue valueWithPointer:original];

        if (!class_addMethod(methodOwner, sel, replacement, types)) {
            method_setImplementation(m, replacement);
        }
        [gInstalled addObject:key];
    }
    return YES;
}

#pragma mark - Exact Infinitok-style Liquid Glass experiment groups

static NSInteger CategoryForSelector(SEL sel) {
    NSString *s = NSStringFromSelector(sel);
    static NSSet *controls, *notices, *overlays;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        controls = [NSSet setWithArray:@[
            @"isLiquidGlassButtonEnabled", @"isLiquidGlassMenuEnabled",
            @"isLiquidGlassIntroPanelEnabled", @"isLiquidGlassPopoverEnabled"
        ]];
        notices = [NSSet setWithArray:@[
            @"isLiquidGlassToastEnabled", @"isLiquidGlassCenterToastEnabled",
            @"isLiquidGlassBottomToastEnabled", @"isLiquidGlassFloatingNoticeEnabled",
            @"isLiquidGlassInAppPushEnabled"
        ]];
        overlays = [NSSet setWithArray:@[
            @"isLiquidGlassModalEnabled", @"isLiquidGlassSheetEnabled",
            @"isLiquidGlassDialogEnabled"
        ]];
    });
    if ([controls containsObject:s]) return 0;
    if ([notices containsObject:s]) return 1;
    if ([overlays containsObject:s]) return 2;
    return -1;
}

static BOOL TUXExperimentReplacement(id self, SEL sel) {
    IMP imp = FindOriginal(self, sel);
    BOOL original = imp ? ((BOOL(*)(id,SEL))imp)(self, sel) : NO;
    if (!Pref(kMasterKey)) return original;
    switch (CategoryForSelector(sel)) {
        case 0: return original || Pref(kControlsKey);
        case 1: return original || Pref(kNoticesKey);
        case 2: return original || Pref(kOverlaysKey);
        default: return original;
    }
}

static BOOL TUXButtonReplacement(id self, SEL sel) {
    IMP imp = FindOriginal(self, sel);
    BOOL original = imp ? ((BOOL(*)(id,SEL))imp)(self, sel) : NO;
    return original || (Pref(kMasterKey) && Pref(kControlsKey));
}

static void InstallLiquidGlassExperimentHooks(void) {
    Class exp = NSClassFromString(@"TUXSwiftBase.TUXExperiments");
    if (!exp) exp = NSClassFromString(@"_TtC12TUXSwiftBase14TUXExperiments");
    NSArray *sels = @[
        @"isLiquidGlassButtonEnabled", @"isLiquidGlassMenuEnabled",
        @"isLiquidGlassIntroPanelEnabled", @"isLiquidGlassPopoverEnabled",
        @"isLiquidGlassToastEnabled", @"isLiquidGlassCenterToastEnabled",
        @"isLiquidGlassBottomToastEnabled", @"isLiquidGlassFloatingNoticeEnabled",
        @"isLiquidGlassInAppPushEnabled", @"isLiquidGlassModalEnabled",
        @"isLiquidGlassSheetEnabled", @"isLiquidGlassDialogEnabled"
    ];
    for (NSString *name in sels) {
        SEL s = NSSelectorFromString(name);
        InstallHook(exp, NO, s, (IMP)TUXExperimentReplacement);
        InstallHook(exp, YES, s, (IMP)TUXExperimentReplacement);
    }

    Class button = NSClassFromString(@"TUXButton");
    InstallHook(button, NO, NSSelectorFromString(@"isLiquidGlassEnabled"), (IMP)TUXButtonReplacement);
}

#pragma mark - Infinitok glass tab bar path

static BOOL PadBarBoolReplacement(id self, SEL sel) {
    IMP imp = FindOriginal(self, sel);
    BOOL original = imp ? ((BOOL(*)(id,SEL))imp)(self, sel) : NO;
    return original || Pref(kBarKey);
}

static double PadBarDoubleReplacement(id self, SEL sel) {
    IMP imp = FindOriginal(self, sel);
    double original = imp ? ((double(*)(id,SEL))imp)(self, sel) : 0.0;
    if (!(Pref(kBarKey) && Pref(kBarLargeKey))) return original;

    NSString *name = NSStringFromSelector(sel);
    if ([name isEqualToString:@"padPaddingForTab"]) {
        CGFloat target = CGRectGetWidth(UIScreen.mainScreen.bounds) / 5.0 * 0.45;
        return MAX(original, target);
    }
    if ([name isEqualToString:@"padTabBarImageSize"]) {
        return original * 1.25;
    }
    return original;
}

static void HideLegacyBarDecor(UIView *root) {
    if (!root) return;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger i = 0; i < queue.count && i < 600; i++) {
        UIView *v = queue[i];
        NSString *name = NSStringFromClass(v.class);
        if ([name containsString:@"TabBarBackgroundView"] ||
            [name containsString:@"TabBarGradientView"] ||
            [name containsString:@"TTKTabBarBlurView"]) {
            v.alpha = 0.0;
        }
        [queue addObjectsFromArray:v.subviews];
    }
    for (NSString *key in @[@"backgroundView", @"bgView", @"gradientView", @"blurView"]) {
        @try {
            id obj = [root valueForKey:key];
            if ([obj isKindOfClass:UIView.class]) [(UIView *)obj setAlpha:0.0];
        } @catch (__unused NSException *e) {}
    }
}

static UIView *FindRoundedCapsule(UIView *bar) {
    if (!bar) return nil;
    CGFloat barWidth = CGRectGetWidth(bar.bounds);
    UIView *best = nil;
    CGFloat bestWidth = 0.0;
    NSMutableArray<UIView *> *level = [NSMutableArray arrayWithObject:bar];

    // Infinitok scans three descendant levels and chooses a large, rounded pill.
    for (NSUInteger depth = 0; depth < 3 && level.count; depth++) {
        NSMutableArray<UIView *> *next = [NSMutableArray array];
        for (UIView *parent in level) {
            for (UIView *v in parent.subviews) {
                [next addObject:v];
                CGRect b = v.bounds;
                CGFloat w = CGRectGetWidth(b), h = CGRectGetHeight(b);
                CGFloat r = v.layer.cornerRadius;
                if (h >= 30.0 && w >= 120.0 && w < barWidth - 24.0 &&
                    r >= (h / 3.0 - 1.0) && w > bestWidth) {
                    best = v;
                    bestWidth = w;
                }
            }
        }
        level = next;
    }
    return best;
}

static void ApplyBarLayout(UIView *bar) {
    if (!Pref(kBarKey) || !bar) return;
    bar.opaque = NO;
    bar.backgroundColor = UIColor.clearColor;
    HideLegacyBarDecor(bar);

    if (Pref(kBarLargeKey)) {
        UIView *pill = FindRoundedCapsule(bar);
        UIView *parent = pill.superview;
        if (pill && parent) {
            CGFloat targetWidth = MAX(0.0, CGRectGetWidth(parent.bounds) - 32.0);
            CGRect f = pill.frame;
            if (targetWidth > CGRectGetWidth(f) + 1.0) {
                f.origin.x = 16.0;
                f.size.width = targetWidth;
                pill.frame = f;
            }
        }
    }
}

static void TTKTabBarLayoutReplacement(id self, SEL sel) {
    IMP imp = FindOriginal(self, sel);
    if (imp) ((void(*)(id,SEL))imp)(self, sel);
    if ([self isKindOfClass:UIView.class]) ApplyBarLayout((UIView *)self);
}

static void InstallGlassBarHooks(void) {
    Class pad = NSClassFromString(@"TTKPadTabBar");
    for (NSString *name in @[
        @"isPadCompactTabBarEnabled",
        @"isPadCompactTabBarCapsuleBackgroundEnabled",
        @"isPadCompactTabBarActionsEnabled",
        @"isTabBarLayoutEnabled"
    ]) {
        InstallHook(pad, NO, NSSelectorFromString(name), (IMP)PadBarBoolReplacement);
        InstallHook(pad, YES, NSSelectorFromString(name), (IMP)PadBarBoolReplacement);
    }
    for (NSString *name in @[@"padPaddingForTab", @"padTabBarImageSize"]) {
        InstallHook(pad, NO, NSSelectorFromString(name), (IMP)PadBarDoubleReplacement);
    }

    Class ab = NSClassFromString(@"TTKABTest");
    SEL capsule = NSSelectorFromString(@"padCompactTabBarCapsuleBackground");
    InstallHook(ab, YES, capsule, (IMP)PadBarBoolReplacement);
    InstallHook(ab, NO, capsule, (IMP)PadBarBoolReplacement);

    Class tab = NSClassFromString(@"TTKTabBar");
    InstallHook(tab, NO, @selector(layoutSubviews), (IMP)TTKTabBarLayoutReplacement);
}

#pragma mark - Settings UI

@interface TLGSettingsController : UITableViewController
@end

@implementation TLGSettingsController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Liquid Glass";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeSettings)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72.0;
}

- (void)closeSettings {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 4 : 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Appearance" : @"Feed Content";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) return @"Restart TikTok after changing the Liquid Glass tab bar options.";
    return nil;
}

- (NSArray<NSDictionary *> *)rowsForSection:(NSInteger)section {
    if (section == 0) {
        return @[
            @{@"title":@"Enable Liquid Glass UI", @"detail":@"Force-enable TikTok's in-development Liquid Glass visual redesign, if present in this app build", @"key":kMasterKey},
            @{@"title":@"Liquid Glass: Buttons/Menus/Panels", @"detail":@"Applies to buttons, menus, and intro panels — needs Enable Liquid Glass UI on", @"key":kControlsKey},
            @{@"title":@"Liquid Glass: Toasts/Notices", @"detail":@"Applies to toasts, banners, and in-app push notices — needs Enable Liquid Glass UI on", @"key":kNoticesKey},
            @{@"title":@"Liquid Glass: Modals/Sheets", @"detail":@"Applies to modals, sheets, and dialogs — needs Enable Liquid Glass UI on", @"key":kOverlaysKey}
        ];
    }
    return @[
        @{@"title":@"Liquid glass tab bar", @"detail":@"Uses the rounded iPad-style compact tab bar. Restart TikTok after changing.", @"key":kBarKey},
        @{@"title":@"Liquid glass bar: full size", @"detail":@"Stretches the Liquid Glass tab bar and enlarges its icons. Needs Liquid glass tab bar on.", @"key":kBarLargeKey}
    ];
}

- (BOOL)rowEnabledAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0 && ip.row > 0) return Pref(kMasterKey);
    if (ip.section == 1 && ip.row == 1) return Pref(kBarKey);
    return YES;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *reuse = @"TLGSwitchCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];

    NSDictionary *row = [self rowsForSection:ip.section][ip.row];
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = row[@"detail"];
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UISwitch *sw = [UISwitch new];
    sw.on = Pref(row[@"key"]);
    sw.enabled = [self rowEnabledAtIndexPath:ip];
    sw.tag = ip.section * 100 + ip.row;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;

    CGFloat alpha = sw.enabled ? 1.0 : 0.45;
    cell.textLabel.alpha = alpha;
    cell.detailTextLabel.alpha = alpha;
    return cell;
}

- (void)switchChanged:(UISwitch *)sender {
    NSInteger section = sender.tag / 100, rowIndex = sender.tag % 100;
    NSArray *rows = [self rowsForSection:section];
    if (rowIndex < 0 || rowIndex >= (NSInteger)rows.count) return;
    NSString *key = rows[rowIndex][@"key"];
    SetPref(key, sender.isOn);

    if ([key isEqualToString:kMasterKey] || [key isEqualToString:kBarKey]) {
        [self.tableView reloadData];
    }
    InstallLiquidGlassExperimentHooks();
    InstallGlassBarHooks();
}
@end

#pragma mark - RXMenuFix-style TikTok settings insertion

static id MsgId0(id obj, SEL sel) {
    return obj && [obj respondsToSelector:sel] ? ((id(*)(id,SEL))objc_msgSend)(obj, sel) : nil;
}
static id MsgId1(id obj, SEL sel, id arg) {
    return obj && [obj respondsToSelector:sel] ? ((id(*)(id,SEL,id))objc_msgSend)(obj, sel, arg) : nil;
}
static void MsgVoid1(id obj, SEL sel, id arg) {
    if (obj && [obj respondsToSelector:sel]) ((void(*)(id,SEL,id))objc_msgSend)(obj, sel, arg);
}
static void MsgVoidInt(id obj, SEL sel, NSInteger value) {
    if (obj && [obj respondsToSelector:sel]) ((void(*)(id,SEL,NSInteger))objc_msgSend)(obj, sel, value);
}

static BOOL IsAccountSection(id section) {
    id ident = MsgId0(section, NSSelectorFromString(@"sectionIdentifier"));
    return [ident isKindOfClass:NSString.class] && [(NSString *)ident isEqualToString:@"account"];
}

static NSArray *SectionModels(id section) {
    @try {
        id v = [section valueForKey:@"modelsArray"];
        if ([v isKindOfClass:NSArray.class]) return v;
    } @catch (__unused NSException *e) {}
    @try {
        id v = [section valueForKey:@"models"];
        if ([v isKindOfClass:NSArray.class]) return v;
    } @catch (__unused NSException *e) {}
    return @[];
}

static void AddLiquidGlassSettingsRowIfNeeded(id section) {
    if (!section || !IsAccountSection(section)) return;

    for (id plugin in SectionModels(section)) {
        id item = MsgId0(plugin, NSSelectorFromString(@"itemModel"));
        id ident = MsgId0(item, NSSelectorFromString(@"identifier"));
        if ([ident isKindOfClass:NSString.class] && [(NSString *)ident isEqualToString:kSettingsIdentifier]) return;
    }

    Class pluginClass = NSClassFromString(@"TTKSettingsBaseCellPlugin");
    Class modelClass = NSClassFromString(@"AWESettingItemModel");
    if (!pluginClass || !modelClass) return;

    id context = MsgId0(section, NSSelectorFromString(@"context"));
    id plugin = MsgId1([pluginClass alloc], NSSelectorFromString(@"initWithPluginContext:"), context);
    id model = MsgId1([modelClass alloc], NSSelectorFromString(@"initWithIdentifier:"), kSettingsIdentifier);
    if (!plugin || !model) return;

    MsgVoid1(model, NSSelectorFromString(@"setTitle:"), @"Liquid Glass");
    MsgVoid1(model, NSSelectorFromString(@"setDetail:"), @"Liquid Glass settings");
    UIImage *icon = [UIImage systemImageNamed:@"circle.hexagongrid.fill"] ?: [UIImage systemImageNamed:@"sparkles"];
    if (icon) {
        icon = [[icon imageWithTintColor:UIColor.systemGrayColor] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        MsgVoid1(model, NSSelectorFromString(@"setIconImage:"), icon);
    }
    MsgVoidInt(model, NSSelectorFromString(@"setType:"), 99);
    MsgVoid1(plugin, NSSelectorFromString(@"setItemModel:"), model);

    SEL insert = NSSelectorFromString(@"insertModel:atIndex:animated:");
    if ([section respondsToSelector:insert]) {
        ((void(*)(id,SEL,id,NSInteger,BOOL))objc_msgSend)(section, insert, plugin, 0, NO);
    }
}

static void SettingsSectionViewDidLoad(id self, SEL sel) {
    IMP imp = FindOriginal(self, sel);
    if (imp) ((void(*)(id,SEL))imp)(self, sel);
    AddLiquidGlassSettingsRowIfNeeded(self);
}

static void SettingsSectionSetModels(id self, SEL sel, id models) {
    IMP imp = FindOriginal(self, sel);
    if (imp) ((void(*)(id,SEL,id))imp)(self, sel, models);
    AddLiquidGlassSettingsRowIfNeeded(self);
}

static UIViewController *TopViewController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { window = w; break; }
        }
        if (window) break;
    }
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:UINavigationController.class]) vc = ((UINavigationController *)vc).topViewController;
    if ([vc isKindOfClass:UITabBarController.class]) vc = ((UITabBarController *)vc).selectedViewController;
    return vc ?: window.rootViewController;
}

static void SettingsPluginDidSelect(id self, SEL sel, NSInteger index) {
    id item = MsgId0(self, NSSelectorFromString(@"itemModel"));
    id ident = MsgId0(item, NSSelectorFromString(@"identifier"));
    if ([ident isKindOfClass:NSString.class] && [(NSString *)ident isEqualToString:kSettingsIdentifier]) {
        TLGSettingsController *settings = [TLGSettingsController new];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [TopViewController() presentViewController:nav animated:YES completion:nil];
        return;
    }
    IMP imp = FindOriginal(self, sel);
    if (imp) ((void(*)(id,SEL,NSInteger))imp)(self, sel, index);
}

static void InstallSettingsHooks(void) {
    Class section = NSClassFromString(@"AWESettingsNormalSectionViewModel");
    InstallHook(section, NO, @selector(viewDidLoad), (IMP)SettingsSectionViewDidLoad);
    InstallHook(section, NO, NSSelectorFromString(@"setModelsArray:"), (IMP)SettingsSectionSetModels);

    Class plugin = NSClassFromString(@"TTKSettingsBaseCellPlugin");
    InstallHook(plugin, NO, NSSelectorFromString(@"didSelectItemAtIndex:"), (IMP)SettingsPluginDidSelect);
}

#pragma mark - Installer

static void InstallAll(void) {
    InstallLiquidGlassExperimentHooks();
    InstallGlassBarHooks();
    InstallSettingsHooks();
}

static void ImageAdded(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    dispatch_async(dispatch_get_main_queue(), ^{ InstallAll(); });
}

__attribute__((constructor))
static void TLGInit(void) {
    @autoreleasepool {
        gOriginals = [NSMutableDictionary dictionary];
        gInstalled = [NSMutableSet set];
        InstallAll();
        _dyld_register_func_for_add_image(ImageAdded);
        for (NSNumber *delay in @[@0.10, @0.35, @0.75, @1.5, @3.0, @6.0, @10.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ InstallAll(); });
        }
        NSLog(@"[TikTokLiquidGlass] 0.2 menu replica loaded");
    }
}
