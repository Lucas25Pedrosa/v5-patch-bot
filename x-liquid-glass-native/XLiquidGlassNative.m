#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

// XLiquidGlassNative
// Native activation path only. No navigation, badge, sidebar, blur,
// tab-label, legacy-host or visual/runtime fixes.
// The only extra UI is the NeoFreeBird on/off toggle requested by the user.

static NSString *const kXLGNativeEnabledKey = @"XLiquidGlassEnabled";
static NSString *const kXLGNativePersistedGateKey = @"T1LiquidGlassRedesignPersistedGate";

static IMP gOrigInstallGate = NULL;
static IMP gOrigInstallGateForAccount = NULL;
static IMP gOrigAccountGate = NULL;
static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;

static BOOL gDebugSettingsHooked = NO;
static BOOL gSwiftLiquidGlassHooked = NO;
static BOOL gRedesignFeaturesHooked = NO;
static BOOL gInstallGateHooked = NO;
static BOOL gInstallGateForAccountHooked = NO;
static BOOL gAccountGateHooked = NO;
static BOOL gNFBSettingsHooked = NO;

static BOOL XLGNativeEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:kXLGNativeEnabledKey];
    return stored ? [stored boolValue] : YES;
}

static BOOL XLGNativeHookMethod(Class cls,
                                SEL sel,
                                BOOL classMethod,
                                IMP replacement,
                                IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;

    Method method = classMethod ? class_getClassMethod(cls, sel)
                                : class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    Class target = classMethod ? object_getClass(cls) : cls;
    if (!target) return NO;

    IMP current = class_getMethodImplementation(target, sel);
    if (current == replacement) return YES;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    if (originalOut && !*originalOut) {
        *originalOut = current;
    }

    class_replaceMethod(target, sel, replacement, types);
    return class_getMethodImplementation(target, sel) == replacement;
}

#pragma mark - Native Liquid Glass activation gates

static BOOL XLGNativeReturnState(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return XLGNativeEnabled();
}

static BOOL XLGNativeAccountGate(id self, SEL _cmd) {
    if (XLGNativeEnabled()) return YES;
    if (gOrigAccountGate) {
        return ((BOOL (*)(id, SEL))gOrigAccountGate)(self, _cmd);
    }
    return NO;
}

static void XLGNativeInstallGateWithRedesignEnabled(id self,
                                                     SEL _cmd,
                                                     BOOL requestedState) {
    if (!gOrigInstallGate) return;

    BOOL forwarded = XLGNativeEnabled() ? YES : requestedState;
    ((void (*)(id, SEL, BOOL))gOrigInstallGate)(self, _cmd, forwarded);
}

static void XLGNativeInstallGateForAccount(id self, SEL _cmd, id account) {
    if (gOrigInstallGateForAccount) {
        ((void (*)(id, SEL, id))gOrigInstallGateForAccount)(self, _cmd, account);
    }

    if (!XLGNativeEnabled()) return;

    SEL gateSEL = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    if ([self respondsToSelector:gateSEL]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, gateSEL, YES);
    }
}

static void XLGNativeSyncPersistedGate(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if (XLGNativeEnabled()) {
        [defaults setBool:YES forKey:kXLGNativePersistedGateKey];

        Class compatibility =
            NSClassFromString(@"_TtC17TFSUtilitiesSwift32LiquidGlassCompatibilityOverride");
        SEL applySEL = NSSelectorFromString(@"applyOverrideIfNeeded");

        if (compatibility && [compatibility respondsToSelector:applySEL]) {
            ((void (*)(id, SEL))objc_msgSend)(compatibility, applySEL);
        }
    } else {
        [defaults removeObjectForKey:kXLGNativePersistedGateKey];
    }

    Class installer = NSClassFromString(@"T1LiquidGlassGateInstaller");
    SEL gateSEL = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    if (installer && [installer respondsToSelector:gateSEL] && XLGNativeEnabled()) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(installer, gateSEL, YES);
    }
}

static void XLGNativeInstallActivationHooks(void) {
    Class cls = Nil;

    if (!gDebugSettingsHooked) {
        cls = NSClassFromString(@"T1LiquidGlassDebugSettings");
        if (cls) {
            gDebugSettingsHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"useTabBarControllerEnabled"),
                YES,
                (IMP)XLGNativeReturnState,
                NULL
            );
        }
    }

    if (!gSwiftLiquidGlassHooked) {
        cls = NSClassFromString(@"_TtC17TFSUtilitiesSwift11LiquidGlass");
        if (cls) {
            gSwiftLiquidGlassHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"isEnabled"),
                YES,
                (IMP)XLGNativeReturnState,
                NULL
            );
        }
    }

    if (!gRedesignFeaturesHooked) {
        cls = NSClassFromString(@"_TtC14T1TwitterSwift27LiquidGlassRedesignFeatures");
        if (cls) {
            gRedesignFeaturesHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"isRedesignEnabled"),
                NO,
                (IMP)XLGNativeReturnState,
                NULL
            );
        }
    }

    cls = NSClassFromString(@"T1LiquidGlassGateInstaller");
    if (cls) {
        if (!gInstallGateHooked) {
            gInstallGateHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"installGateWithRedesignEnabled:"),
                YES,
                (IMP)XLGNativeInstallGateWithRedesignEnabled,
                &gOrigInstallGate
            );
        }

        if (!gInstallGateForAccountHooked) {
            gInstallGateForAccountHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"installGateForAccount:"),
                YES,
                (IMP)XLGNativeInstallGateForAccount,
                &gOrigInstallGateForAccount
            );
        }
    }

    if (!gAccountGateHooked) {
        cls = NSClassFromString(@"TFNTwitterAccount");
        if (cls) {
            gAccountGateHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"isDummyTest1FeatureEnabled"),
                NO,
                (IMP)XLGNativeAccountGate,
                &gOrigAccountGate
            );
        }
    }

    XLGNativeSyncPersistedGate();
}

#pragma mark - NeoFreeBird settings toggle

@interface XLiquidGlassNativeSettingsViewController : UITableViewController
@end

@implementation XLiquidGlassNativeSettingsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Liquid Glass";
    self.tableView.backgroundColor = UIColor.systemBackgroundColor;
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
    return @"Reinicie o X após alterar esta opção para aplicar completamente a interface.";
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

    cell.textLabel.text = @"Ativar Liquid Glass";
    cell.detailTextLabel.text = @"Ativa o redesign nativo presente no X.";
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    toggle.on = XLGNativeEnabled();
    [toggle addTarget:self
               action:@selector(xlgNativeToggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;

    return cell;
}

- (void)xlgNativeToggleChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn
                                            forKey:kXLGNativeEnabledKey];
    XLGNativeSyncPersistedGate();

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Liquid Glass"
                                            message:@"Reinicie o X para aplicar completamente a alteração."
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

static BOOL XLGNativeSectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"action"] isEqualToString:@"showXLiquidGlassNativeSettings"]) {
            return YES;
        }
    }
    return NO;
}

static void XLGNativeInjectNFBSection(id controller) {
    NSArray *sections = nil;

    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        return;
    }

    if (![sections isKindOfClass:NSArray.class] ||
        XLGNativeSectionsContainEntry(sections)) {
        return;
    }

    NSMutableArray *updated = [sections mutableCopy];
    NSDictionary *entry = @{
        @"title": @"Liquid Glass",
        @"subtitle": @"Ativar ou desativar o redesign nativo do X.",
        @"icon": @"paintbrush_stroke",
        @"action": @"showXLiquidGlassNativeSettings"
    };

    NSUInteger insertIndex = MIN((NSUInteger)2, updated.count);
    [updated insertObject:entry atIndex:insertIndex];

    @try {
        [controller setValue:[updated copy] forKey:@"sections"];
    } @catch (__unused NSException *exception) {
    }
}

static void XLGNativeNFBSetupSections(id self, SEL _cmd) {
    if (gOrigNFBSetupSections) {
        ((void (*)(id, SEL))gOrigNFBSetupSections)(self, _cmd);
    }
    XLGNativeInjectNFBSection(self);
}

static void XLGNativeNFBViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigNFBViewWillAppear) {
        ((void (*)(id, SEL, BOOL))gOrigNFBViewWillAppear)(self, _cmd, animated);
    }

    XLGNativeInjectNFBSection(self);

    UITableView *tableView = nil;
    @try {
        tableView = [self valueForKey:@"tableView"];
    } @catch (__unused NSException *exception) {
    }
    [tableView reloadData];
}

static void XLGNativeShowSettings(id self, SEL _cmd) {
    (void)_cmd;

    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassNativeSettingsViewController *settings =
        [[XLiquidGlassNativeSettingsViewController alloc] init];

    UINavigationController *navigation =
        ((UIViewController *)self).navigationController;

    if (navigation) {
        [navigation pushViewController:settings animated:YES];
    } else {
        UINavigationController *wrapper =
            [[UINavigationController alloc] initWithRootViewController:settings];
        [(UIViewController *)self presentViewController:wrapper
                                              animated:YES
                                            completion:nil];
    }
}

static void XLGNativeInstallNFBSettingsIntegration(void) {
    if (gNFBSettingsHooked) return;

    Class cls = NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;

    SEL showSEL = NSSelectorFromString(@"showXLiquidGlassNativeSettings");
    class_addMethod(cls, showSEL, (IMP)XLGNativeShowSettings, "v@:");

    BOOL setupHooked = XLGNativeHookMethod(
        cls,
        NSSelectorFromString(@"setupSections"),
        NO,
        (IMP)XLGNativeNFBSetupSections,
        &gOrigNFBSetupSections
    );

    BOOL appearHooked = XLGNativeHookMethod(
        cls,
        @selector(viewWillAppear:),
        NO,
        (IMP)XLGNativeNFBViewWillAppear,
        &gOrigNFBViewWillAppear
    );

    gNFBSettingsHooked = setupHooked || appearHooked;
}

static void XLGNativeInstall(void) {
    XLGNativeInstallActivationHooks();
    XLGNativeInstallNFBSettingsIntegration();
}

static void XLGNativeScheduleRetry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            XLGNativeInstall();
        }
    );
}

__attribute__((constructor))
static void XLiquidGlassNativeInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlassNative] 1.1.0 loaded - native activation + NeoFreeBird toggle");

        XLGNativeInstall();
        XLGNativeScheduleRetry(0.00);
        XLGNativeScheduleRetry(0.05);
        XLGNativeScheduleRetry(0.20);
        XLGNativeScheduleRetry(0.50);
        XLGNativeScheduleRetry(1.00);
        XLGNativeScheduleRetry(2.00);
        XLGNativeScheduleRetry(4.00);
    }
}
