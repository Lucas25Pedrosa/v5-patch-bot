#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

// XLiquidGlass 3.0 Beta 1
// UI/preferences only. Liquid Glass activation lives exclusively in
// XLiquidGlass1238Engine.m.

static NSString *const kXLGEnabledKey = @"XLiquidGlassEnabled";
static NSString *const kXLGLegacyPersistedGateKey = @"T1LiquidGlassRedesignPersistedGate";

static IMP gXLGOrigAppearanceUpdateVisibleToggles = NULL;
static IMP gXLGOrigAppearanceViewWillAppear = NULL;
static BOOL gXLGAppearanceSettingsHooked = NO;

static BOOL XLGEnabled(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kXLGEnabledKey];
    return stored ? [stored boolValue] : YES;
}

static BOOL XLGHookMethod(Class cls,
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

static BOOL XLGIsPortuguese(void) {
    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"";
    return [language hasPrefix:@"pt"];
}

static NSString *XLGEnableTitle(void) {
    return XLGIsPortuguese() ? @"Ativar Liquid Glass" : @"Enable Liquid Glass";
}

static NSString *XLGEnableDetail(void) {
    return XLGIsPortuguese()
        ? @"Usa o redesign nativo presente no X."
        : @"Uses the native redesign built into X.";
}

static NSString *XLGRestartFooter(void) {
    return XLGIsPortuguese()
        ? @"Reinicie o X após alterar esta opção para aplicar completamente a interface."
        : @"Restart X after changing this option to fully apply the interface.";
}

static NSString *XLGRestartMessage(void) {
    return XLGIsPortuguese()
        ? @"Reinicie o X para aplicar completamente a alteração."
        : @"Restart X to fully apply the change.";
}

@interface XLiquidGlassSettingsViewController : UITableViewController
@end

@implementation XLiquidGlassSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Liquid Glass";
    self.tableView.backgroundColor = UIColor.systemBackgroundColor;
    self.tableView.estimatedRowHeight = 60.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return XLGRestartFooter();
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)indexPath;

    static NSString *identifier = @"XLiquidGlassNativeToggleCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }

    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = XLGEnableTitle();
    cell.detailTextLabel.text = XLGEnableDetail();
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 2;

    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    toggle.on = XLGEnabled();
    [toggle addTarget:self
               action:@selector(xlgToggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;

    return cell;
}

- (void)xlgToggleChanged:(UISwitch *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:sender.isOn forKey:kXLGEnabledKey];

    // Cleanup only: this key belonged to the retired pre-12.38 engine.
    // The new engine does not use it.
    if (!sender.isOn) {
        [defaults removeObjectForKey:kXLGLegacyPersistedGateKey];
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Liquid Glass"
                                            message:XLGRestartMessage()
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

static BOOL XLGArrayContainsAction(NSArray *entries, NSString *action) {
    for (id entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"action"] isEqualToString:action]) return YES;
    }
    return NO;
}

static NSArray *XLGArrayForKey(id controller, NSString *key) {
    @try {
        id value = [controller valueForKey:key];
        return [value isKindOfClass:NSArray.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void XLGSetArrayForKey(id controller, NSString *key, NSArray *value) {
    @try {
        [controller setValue:value forKey:key];
    } @catch (__unused NSException *exception) {
    }
}

static void XLGReloadControllerTable(id controller) {
    @try {
        id value = [controller valueForKey:@"tableView"];
        if ([value isKindOfClass:UITableView.class]) [(UITableView *)value reloadData];
    } @catch (__unused NSException *exception) {
    }
}

static void XLGShowSettings(id self) {
    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassSettingsViewController *settings =
        [[XLiquidGlassSettingsViewController alloc] init];
    UINavigationController *navigation = ((UIViewController *)self).navigationController;

    if (navigation) {
        [navigation pushViewController:settings animated:YES];
    } else {
        UINavigationController *wrapper =
            [[UINavigationController alloc] initWithRootViewController:settings];
        [(UIViewController *)self presentViewController:wrapper animated:YES completion:nil];
    }
}

static void XLGShowSettingsFromAppearance(id self, SEL _cmd, id sender) {
    (void)_cmd;
    (void)sender;
    XLGShowSettings(self);
}

static void XLGInjectAppearanceButton(id controller) {
    NSArray *visible = XLGArrayForKey(controller, @"visibleToggles");
    if (!visible) return;

    NSString *action = @"showXLiquidGlassNativeSettings:";
    if (XLGArrayContainsAction(visible, action)) return;

    NSDictionary *entry = @{
        @"type": @"button",
        @"key": @"xlg_native_liquid_glass_button",
        @"titleKey": @"Liquid Glass",
        @"action": action
    };

    NSMutableArray *updated = [visible mutableCopy];
    NSUInteger insertIndex = MIN((NSUInteger)3, updated.count);
    [updated insertObject:entry atIndex:insertIndex];
    XLGSetArrayForKey(controller, @"visibleToggles", [updated copy]);
}

static void XLGAppearanceUpdateVisibleToggles(id self, SEL _cmd) {
    if (gXLGOrigAppearanceUpdateVisibleToggles) {
        ((void (*)(id, SEL))gXLGOrigAppearanceUpdateVisibleToggles)(self, _cmd);
    }
    XLGInjectAppearanceButton(self);
}

static void XLGAppearanceViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gXLGOrigAppearanceViewWillAppear) {
        ((void (*)(id, SEL, BOOL))gXLGOrigAppearanceViewWillAppear)(self, _cmd, animated);
    }
    XLGInjectAppearanceButton(self);
    XLGReloadControllerTable(self);
}

static void XLGInstallNFBSettingsIntegration(void) {
    if (gXLGAppearanceSettingsHooked) return;

    Class cls = NSClassFromString(@"AppearanceSettingsViewController");
    if (!cls) return;

    SEL showSEL = NSSelectorFromString(@"showXLiquidGlassNativeSettings:");
    if (![cls instancesRespondToSelector:showSEL]) {
        class_addMethod(cls, showSEL, (IMP)XLGShowSettingsFromAppearance, "v@:@");
    }

    BOOL updateHooked = XLGHookMethod(
        cls,
        NSSelectorFromString(@"updateVisibleToggles"),
        (IMP)XLGAppearanceUpdateVisibleToggles,
        &gXLGOrigAppearanceUpdateVisibleToggles
    );

    BOOL appearHooked = XLGHookMethod(
        cls,
        @selector(viewWillAppear:),
        (IMP)XLGAppearanceViewWillAppear,
        &gXLGOrigAppearanceViewWillAppear
    );

    gXLGAppearanceSettingsHooked = updateHooked || appearHooked;
}

static void XLGScheduleUIRetry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            XLGInstallNFBSettingsIntegration();
        }
    );
}

__attribute__((constructor))
static void XLiquidGlassUIInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlass] 3.0 Beta 1 UI loaded; activation handled by X12.38 engine");
        XLGInstallNFBSettingsIntegration();
        for (NSNumber *delay in @[@0.0, @0.05, @0.20, @0.50, @1.0, @2.0, @4.0]) {
            XLGScheduleUIRetry(delay.doubleValue);
        }
    }
}
