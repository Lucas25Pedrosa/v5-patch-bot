#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>

#pragma mark - XLiquidGlass 1.9.3 Beta 6

#define XLGDiagLog(...) do { if (0) NSLog(__VA_ARGS__); } while (0)

static BOOL XLGApplyStartupHoldIfNeeded(
    NSString *userID,
    BOOL hasNtab, NSInteger *ntab,
    BOOL hasDM, NSInteger *dm,
    BOOL hasXChat, NSInteger *xchat,
    BOOL hasTotal, NSInteger *total);
static void XLGResolveStartupHoldWithRemote(
    NSString *userID,
    NSInteger remoteNtab,
    NSInteger remoteDM,
    NSInteger remoteXChat,
    NSInteger remoteTotal);
static NSString *XLGCurrentActiveUserID(void);
static NSMutableDictionary *XLGMutableBadgeStateForUserID(
    NSString *userID, BOOL create);
static NSMutableDictionary *XLGSourceStateForUserID(
    NSString *userID, BOOL create);
static NSInteger XLGStateInteger(NSDictionary *state,
                                 NSString *key,
                                 NSInteger fallback);
static NSInteger XLGChatDisplayCountForState(NSDictionary *state);
static NSInteger XLGNotificationDisplayCountForState(NSDictionary *state);
static void XLGPersistBadgeStates(void);
static void XLGRefreshGlobalTabBar(void);
static NSString *XLGTryResolveUserID(id object, NSUInteger depth);
static NSString *XLGB6LogPath(void);
static void XLGB6ProbeSnapshot(NSString *reason);
static void XLGB68DumpConstructorProbe(NSString *reason);
static void XLGB69DumpSwiftSymbolSources(NSString *reason);
static void XLGB6InjectNFBProbeEntry(id controller);
static void XLGB6ShowProbeSettings(id self, SEL cmd);

static NSString *const kXLGEnabledKey = @"XLiquidGlassEnabled";
static NSString *const kXLGPersistedGateKey = @"T1LiquidGlassRedesignPersistedGate";
static NSString *const kXLGTabLabelsKey = @"XLiquidGlassTabLabelsEnabled";

static IMP gOrigInstallGate = NULL;
static IMP gOrigInstallGateForAccount = NULL;
static IMP gOrigDummyFeature = NULL;
static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;
static IMP gOrigAppearanceUpdateVisibleToggles = NULL;
static IMP gOrigAppearanceViewWillAppear = NULL;
static IMP gOrigNotificationsViewDidAppear = NULL;
static IMP gOrigNavProbePushViewController = NULL;
static IMP gOrigNavProbePresentViewController = NULL;
static IMP gOrigNavProbeOpenURL = NULL;
static IMP gOrigNavProbeSendAction = NULL;
static IMP gOrigNavProbeT1OpenURL = NULL;
static IMP gOrigNavProbeTrendingFactoryCreate = NULL;
static NSMutableDictionary<NSString *, NSValue *> *gXLGNavProbeViewAppearOriginals = nil;
static BOOL gXLGNavigationProbeActive = NO;
static BOOL gXLGNavigationProbeHooksInstalled = NO;
static NSMutableDictionary<NSString *, NSValue *> *gXLGContainerProbeOriginals = nil;
static BOOL gXLGContainerProbeHooksInstalled = NO;
static char kXLGGuideBridgeNavigationKey;
static char kXLGGuideBridgeMarkerKey;
static IMP gOrigXAppShowSearchResultsSource = NULL;
static IMP gOrigXAppShowSearchResultsFromPanel = NULL;
static BOOL gXLGXAppSearchRouterInstalled = NO;
static IMP gOrigXAppPremiumProfileCustomization = NULL;
static IMP gOrigXAppPremiumCustomizeNavigation = NULL;
static IMP gOrigXAppPremiumAppIcon = NULL;
static IMP gOrigXAppPremiumSettings = NULL;
static IMP gOrigXAppShowDisplaySettings = NULL;
static BOOL gXLGXAppPremiumRouterInstalled = NO;
static IMP gOrigSearchContainerViewDidLayoutSubviews = NULL;
static BOOL gXLGSearchBlurFixInstalled = NO;
static char kXLGSearchBlurLoggedKey;

static BOOL gDebugSettingsHooked = NO;
static BOOL gSwiftLiquidGlassHooked = NO;
static BOOL gRedesignFeaturesHooked = NO;
static BOOL gInstallGateHooked = NO;
static BOOL gInstallGateForAccountHooked = NO;
static BOOL gDummyFeatureHooked = NO;
static BOOL gNFBSettingsHooked = NO;
static BOOL gAppearanceSettingsHooked = NO;

// Beta 6.5: bridge NFB custom-tab source into the native Liquid Glass
// configuration pipeline before XNavigation creates its descriptors.
static NSMutableDictionary<NSString *, NSValue *> *gXLGB65ArrayGetterOriginals = nil;
static NSMutableDictionary<NSString *, NSValue *> *gXLGB65BoolGetterOriginals = nil;
static BOOL gXLGB65RebuildScheduled = NO;
static id gXLGB65DefaultsObserver = nil;
static char kXLGB65RebuildAttemptKey;

static IMP gOrigToastBridgeToasterInit = NULL;
static IMP gOrigToastBridgeRegisterVC = NULL;
static IMP gOrigToastBridgePushToast = NULL;
static IMP gOrigToastBridgePushToastPriority = NULL;
static IMP gOrigToastBridgeTweetSentInit = NULL;
static BOOL gXLGToastBridgeInstalled = NO;
static id gXLGToastBridgeToaster = nil;
static UIWindow *gXLGToastBridgeWindow = nil;
static id gXLGToastBridgeCompositionObserver = nil;
static char kXLGToastBridgePushedKey;
static char kXLGToastBridgeScheduledKey;
static char kXLGToastBridgeStatusHasToastKey;
static char kXLGToastBridgeCompositionHandledKey;

static BOOL XLGEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:kXLGEnabledKey];
    return stored ? [stored boolValue] : YES;
}

static BOOL XLGTabLabelsEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:kXLGTabLabelsKey];
    return stored ? [stored boolValue] : NO;
}

static BOOL XLGHookMethod(Class cls,
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

static BOOL XLGReturnState(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return XLGEnabled();
}

static BOOL XLGDummyTest1Feature(id self, SEL _cmd) {
    if (XLGEnabled()) return YES;
    if (gOrigDummyFeature) {
        return ((BOOL (*)(id, SEL))gOrigDummyFeature)(self, _cmd);
    }
    return NO;
}

static void XLGInstallGateWithRedesignEnabled(id self,
                                               SEL _cmd,
                                               BOOL requestedState) {
    if (!gOrigInstallGate) return;

    BOOL forwarded = XLGEnabled() ? YES : requestedState;
    ((void (*)(id, SEL, BOOL))gOrigInstallGate)(self, _cmd, forwarded);
}

static void XLGInstallGateForAccount(id self, SEL _cmd, id account) {
    if (gOrigInstallGateForAccount) {
        ((void (*)(id, SEL, id))gOrigInstallGateForAccount)(self, _cmd, account);
    }

    if (!XLGEnabled()) return;

    SEL gateSEL = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    if ([self respondsToSelector:gateSEL]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, gateSEL, YES);
    }
}

static void XLGSyncCompatibilityGate(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if (XLGEnabled()) {
        [defaults setBool:YES forKey:kXLGPersistedGateKey];

        Class compatibility =
            NSClassFromString(@"_TtC17TFSUtilitiesSwift32LiquidGlassCompatibilityOverride");
        SEL applySEL = NSSelectorFromString(@"applyOverrideIfNeeded");

        if (compatibility && [compatibility respondsToSelector:applySEL]) {
            ((void (*)(id, SEL))objc_msgSend)(compatibility, applySEL);
        }
    } else {
        [defaults removeObjectForKey:kXLGPersistedGateKey];
    }

    Class installer = NSClassFromString(@"T1LiquidGlassGateInstaller");
    SEL gateSEL = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    if (installer && [installer respondsToSelector:gateSEL] && XLGEnabled()) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(installer, gateSEL, YES);
    }
}

@interface XLiquidGlassSettingsViewController : UITableViewController
@end

@implementation XLiquidGlassSettingsViewController

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
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return @"Reinicie o X após alterar esta opção para aplicar completamente a interface.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"XLiquidGlassToggleCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }

    cell.textLabel.text=nil;
    cell.detailTextLabel.text=nil;
    cell.accessoryView=nil;
    cell.accessoryType=UITableViewCellAccessoryNone;
    cell.selectionStyle=UITableViewCellSelectionStyleNone;

    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];

    if (indexPath.row == 0) {
        cell.textLabel.text = @"Ativar Liquid Glass";
        cell.detailTextLabel.text = @"Usa o redesign nativo presente no X.";
        toggle.on = XLGEnabled();
        [toggle addTarget:self
                   action:@selector(xlgToggleChanged:)
         forControlEvents:UIControlEventValueChanged];
    } else {
        cell.textLabel.text = @"Mostrar rótulos da Tab Bar";
        cell.detailTextLabel.text = @"Exibe rótulos nativos quando disponíveis.";
        toggle.on = XLGTabLabelsEnabled();
        [toggle addTarget:self
                   action:@selector(xlgTabLabelsToggleChanged:)
         forControlEvents:UIControlEventValueChanged];
    }

    cell.accessoryView = toggle;
    return cell;
}

- (void)xlgToggleChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:kXLGEnabledKey];
    XLGSyncCompatibilityGate();

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Liquid Glass"
                                            message:@"Reinicie o X para aplicar completamente a alteração."
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)xlgTabLabelsToggleChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:kXLGTabLabelsKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"XLiquidGlassRefreshTabBar"
                                                        object:nil];
}

@end

static BOOL XLGArrayContainsAction(NSArray *entries, NSString *action) {
    for (id entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"action"] isEqualToString:action]) return YES;
    }
    return NO;
}

static void XLGSetArrayForKey(id controller, NSString *key, NSArray *value) {
    if (!controller || !key.length || !value) return;
    @try {
        [controller setValue:value forKey:key];
    } @catch (__unused NSException *exception) {
    }
}

static NSArray *XLGArrayForKey(id controller, NSString *key) {
    if (!controller || !key.length) return nil;
    @try {
        id value=[controller valueForKey:key];
        return [value isKindOfClass:NSArray.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void XLGReloadControllerTable(id controller) {
    UITableView *tableView=nil;
    @try {
        id value=[controller valueForKey:@"tableView"];
        if ([value isKindOfClass:UITableView.class]) tableView=value;
    } @catch (__unused NSException *exception) {
    }
    [tableView reloadData];
}

static void XLGRemoveLiquidGlassFromRoot(id controller) {
    NSArray *sections=XLGArrayForKey(controller,@"sections");
    if (!sections || !XLGArrayContainsAction(sections,@"showXLiquidGlassSettings")) return;

    NSMutableArray *updated=[NSMutableArray arrayWithCapacity:sections.count];
    for (id entry in sections) {
        if ([entry isKindOfClass:NSDictionary.class] &&
            [entry[@"action"] isEqualToString:@"showXLiquidGlassSettings"]) {
            continue;
        }
        [updated addObject:entry];
    }
    XLGSetArrayForKey(controller,@"sections",[updated copy]);
}

static void XLGNFBSetupSections(id self, SEL _cmd) {
    if (gOrigNFBSetupSections) {
        ((void (*)(id, SEL))gOrigNFBSetupSections)(self, _cmd);
    }
    XLGRemoveLiquidGlassFromRoot(self);
    XLGB6InjectNFBProbeEntry(self);
}

static void XLGNFBViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigNFBViewWillAppear) {
        ((void (*)(id, SEL, BOOL))gOrigNFBViewWillAppear)(self, _cmd, animated);
    }
    XLGRemoveLiquidGlassFromRoot(self);
    XLGB6InjectNFBProbeEntry(self);
    XLGReloadControllerTable(self);
}

static void XLGShowSettings(id self, SEL _cmd) {
    (void)_cmd;

    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassSettingsViewController *settings =
        [[XLiquidGlassSettingsViewController alloc] init];

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

static void XLGShowSettingsFromAppearance(id self, SEL _cmd, id sender) {
    (void)sender;
    XLGShowSettings(self,_cmd);
}

static void XLGInjectAppearanceButton(id controller) {
    NSArray *visible=XLGArrayForKey(controller,@"visibleToggles");
    if (!visible) return;

    if (XLGArrayContainsAction(visible,@"showXLiquidGlassSettings:")) return;

    NSDictionary *entry=@{
        @"type": @"button",
        @"key": @"xlg_liquid_glass_button",
        @"titleKey": @"Liquid Glass",
        @"action": @"showXLiquidGlassSettings:"
    };

    NSMutableArray *updated=[visible mutableCopy];

    // Native appearance page starts with Theme, App Icon and Custom Tab Bar.
    // Place Liquid Glass immediately after those three native buttons.
    NSUInteger insertIndex=MIN((NSUInteger)3,updated.count);
    [updated insertObject:entry atIndex:insertIndex];

    XLGSetArrayForKey(controller,@"visibleToggles",[updated copy]);
}

static void XLGAppearanceUpdateVisibleToggles(id self, SEL _cmd) {
    if (gOrigAppearanceUpdateVisibleToggles) {
        ((void (*)(id,SEL))gOrigAppearanceUpdateVisibleToggles)(self,_cmd);
    }
    XLGInjectAppearanceButton(self);
}

static void XLGAppearanceViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigAppearanceViewWillAppear) {
        ((void (*)(id,SEL,BOOL))gOrigAppearanceViewWillAppear)(self,_cmd,animated);
    }
    XLGInjectAppearanceButton(self);
    XLGReloadControllerTable(self);
}

static void XLGInstallNFBSettingsIntegration(void) {
    Class rootClass=NSClassFromString(@"ModernSettingsViewController");
    if (rootClass && !gNFBSettingsHooked) {
        SEL probeSEL=NSSelectorFromString(@"showXLiquidGlassBeta6Probe");
        if (![rootClass instancesRespondToSelector:probeSEL]) {
            class_addMethod(rootClass,
                            probeSEL,
                            (IMP)XLGB6ShowProbeSettings,
                            "v@:");
        }

        BOOL setupHooked=
            XLGHookMethod(rootClass,
                          NSSelectorFromString(@"setupSections"),
                          NO,
                          (IMP)XLGNFBSetupSections,
                          &gOrigNFBSetupSections);

        BOOL appearHooked=
            XLGHookMethod(rootClass,
                          @selector(viewWillAppear:),
                          NO,
                          (IMP)XLGNFBViewWillAppear,
                          &gOrigNFBViewWillAppear);

        gNFBSettingsHooked=setupHooked || appearHooked;
    }

    Class appearanceClass=NSClassFromString(@"AppearanceSettingsViewController");
    if (appearanceClass && !gAppearanceSettingsHooked) {
        SEL showSEL=NSSelectorFromString(@"showXLiquidGlassSettings:");
        if (![appearanceClass instancesRespondToSelector:showSEL]) {
            class_addMethod(appearanceClass,
                            showSEL,
                            (IMP)XLGShowSettingsFromAppearance,
                            "v@:@");
        }

        BOOL updateHooked=
            XLGHookMethod(appearanceClass,
                          NSSelectorFromString(@"updateVisibleToggles"),
                          NO,
                          (IMP)XLGAppearanceUpdateVisibleToggles,
                          &gOrigAppearanceUpdateVisibleToggles);

        BOOL appearHooked=
            XLGHookMethod(appearanceClass,
                          @selector(viewWillAppear:),
                          NO,
                          (IMP)XLGAppearanceViewWillAppear,
                          &gOrigAppearanceViewWillAppear);

        gAppearanceSettingsHooked=updateHooked || appearHooked;
    }
}



#pragma mark - Liquid Glass sidebar swipe fix

static IMP gOrigTabLoad = NULL;
static IMP gOrigTabAppear = NULL;
static IMP gOrigOwnNotificationCellDidMoveToWindow = NULL;
static char kXLGSidebarEdgePanKey;
static char kXLGOwnNotificationTapKey;
static BOOL gXLGOwnNotificationRouterHooked = NO;

@class XLiquidGlassSidebarDrawerViewController;

@interface XLiquidGlassSidebarCoordinator : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) id account;
@property (nonatomic, strong) id interactionsTimelineBridge;
@property (nonatomic, strong) id dashContentController;
@property (nonatomic, strong) XLiquidGlassSidebarDrawerViewController *drawer;
@property (nonatomic, assign) BOOL presenting;
+ (instancetype)sharedCoordinator;
- (UIViewController *)xlg_buildDashViewControllerForAccount:(id)account;
- (BOOL)xlg_presentAnimated:(BOOL)animated;
- (void)xlg_dismissAnimated:(BOOL)animated completion:(dispatch_block_t)completion;
- (void)xlg_didRecognizeEdgePan:(UIScreenEdgePanGestureRecognizer *)gesture;
@end

@interface XLiquidGlassSidebarDrawerViewController : UIViewController
@property (nonatomic, strong) UIViewController *dashViewController;
@property (nonatomic, copy) void (^dismissRequestHandler)(BOOL animated);
@property (nonatomic, strong) UIView *dimmingView;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIPanGestureRecognizer *panRecognizer;
@property (nonatomic, assign) CGFloat progress;
@property (nonatomic, assign) CGFloat panStartProgress;
- (CGFloat)xlg_panelWidth;
- (void)xlg_applyProgress;
@end

static UIWindow *XLGSidebarActiveWindow(void) {
    UIWindow *fallback=nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene=(UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (!fallback && !window.hidden) fallback=window;
            if (window.isKeyWindow) return window;
        }
    }
    return fallback;
}

// Moe presents from the active window's root controller, following only the
// presentedViewController chain. Do not descend into nav/tab children here.
static UIViewController *XLGSidebarPresenter(void) {
    UIViewController *controller=XLGSidebarActiveWindow().rootViewController;
    while (controller.presentedViewController) {
        controller=controller.presentedViewController;
    }
    return controller;
}

static id XLGSidebarAppNavigation(void) {
    UIViewController *root=XLGSidebarActiveWindow().rootViewController;
    NSMutableArray<UIViewController *> *queue=[NSMutableArray array];
    if (root) [queue addObject:root];

    for (NSUInteger i=0;i<queue.count && i<192;i++) {
        UIViewController *vc=queue[i];

        // Moe's redesign path resolves the host appNavigation first.
        SEL appNavigationSEL=NSSelectorFromString(@"appNavigation");
        if ([vc respondsToSelector:appNavigationSEL]) {
            id appNavigation=((id(*)(id,SEL))objc_msgSend)(vc,appNavigationSEL);
            if (appNavigation) return appNavigation;
        }

        Class hostClass=NSClassFromString(@"_TtC14T1TwitterSwift34XTabbedAppNavigationViewController");
        if (hostClass && [vc isKindOfClass:hostClass]) return vc;

        Class legacyClass=NSClassFromString(@"T1TabbedAppNavigationViewController");
        if (legacyClass && [vc isKindOfClass:legacyClass]) return vc;

        if (vc.presentedViewController && ![queue containsObject:vc.presentedViewController])
            [queue addObject:vc.presentedViewController];

        for (UIViewController *child in vc.childViewControllers ?: @[]) {
            if (![queue containsObject:child]) [queue addObject:child];
        }
    }

    return nil;
}

static id XLGSidebarCurrentAccount(void) {
    // Match Moe first: the current account belongs to redesign appNavigation.
    id appNavigation=XLGSidebarAppNavigation();
    SEL accountSEL=NSSelectorFromString(@"account");
    if (appNavigation && [appNavigation respondsToSelector:accountSEL]) {
        id account=((id(*)(id,SEL))objc_msgSend)(appNavigation,accountSEL);
        if (account) return account;
    }

    // Secondary fallback only if the redesign navigation did not expose it.
    Class twitterClass=NSClassFromString(@"TFNTwitter");
    for (NSString *sharedName in @[@"sharedTwitter",@"sharedInstance",@"shared"]) {
        SEL sharedSEL=NSSelectorFromString(sharedName);
        if (!twitterClass || ![twitterClass respondsToSelector:sharedSEL]) continue;

        id twitter=((id(*)(id,SEL))objc_msgSend)(twitterClass,sharedSEL);
        for (NSString *accountName in @[@"activeAccount",@"currentAccount",@"account"]) {
            SEL sel=NSSelectorFromString(accountName);
            if (twitter && [twitter respondsToSelector:sel]) {
                id account=((id(*)(id,SEL))objc_msgSend)(twitter,sel);
                if (account) return account;
            }
        }
    }

    return nil;
}


static void XLGRouteContentViewController(UIViewController *viewController);
static void XLGRouteModalViewController(UIViewController *viewController);
static BOOL XLGHierarchyContainsViewController(UIViewController *root,
                                               UIViewController *target);

static UIViewController *XLGSidebarContentPresentingViewController(void) {
    id appNavigation=XLGSidebarAppNavigation();
    SEL currentPanelSEL=NSSelectorFromString(@"currentPanelNavigationController");

    if (appNavigation && [appNavigation respondsToSelector:currentPanelSEL]) {
        id panel=((id(*)(id,SEL))objc_msgSend)(appNavigation,currentPanelSEL);
        if ([panel isKindOfClass:UIViewController.class]) {
            return panel;
        }
    }

    return XLGSidebarPresenter();
}

static UINavigationController *XLGNavigationControllerForPresenter(
    UIViewController *presenter) {
    if (!presenter) return nil;
    if ([presenter isKindOfClass:UINavigationController.class]) {
        return (UINavigationController *)presenter;
    }
    return presenter.navigationController;
}


#pragma mark - XLiquidGlass 1.9.2 native toast bridge

static void XLGToastBridgeLog(NSString *format, ...) {
    // Stable build: keep call sites for low-risk diagnostics but do not
    // persist reports or emit runtime logging.
    (void)format;
}

static BOOL XLGToastBridgeIsToaster(id object) {
    Class cls=NSClassFromString(@"TFNToaster");
    return object && cls && [object isKindOfClass:cls];
}

static id XLGToastBridgeValueBySelector(id object, NSString *name) {
    if (!object || !name.length) return nil;
    SEL selector=NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;

    Method method=class_getInstanceMethod([object class],selector);
    if (!method || method_getNumberOfArguments(method)!=2) return nil;

    char returnType[32]={0};
    method_getReturnType(method,returnType,sizeof(returnType));
    const char *p=returnType;
    while (*p && strchr("rnNoORV",*p)) p++;
    if (*p!='@' && *p!='#') return nil;

    @try {
        return ((id(*)(id,SEL))objc_msgSend)(object,selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void XLGToastBridgeCaptureToaster(id toaster,
                                         NSString *reason) {
    if (!XLGToastBridgeIsToaster(toaster)) return;
    if (gXLGToastBridgeToaster!=toaster) {
        gXLGToastBridgeToaster=toaster;
        XLGToastBridgeLog(
            @"TOASTER_CAPTURE reason=%@ ptr=%p class=%@",
            reason ?: @"-",
            toaster,
            NSStringFromClass([toaster class]));
    }
}

static id XLGToastBridgeFindToaster(void) {
    if (XLGToastBridgeIsToaster(gXLGToastBridgeToaster)) {
        return gXLGToastBridgeToaster;
    }

    NSMutableArray *objects=[NSMutableArray array];

    id appNavigation=XLGSidebarAppNavigation();
    if (appNavigation) [objects addObject:appNavigation];

    UIViewController *presenter=XLGSidebarContentPresentingViewController();
    if (presenter) [objects addObject:presenter];

    UIWindow *activeWindow=XLGSidebarActiveWindow();
    if (activeWindow.rootViewController) {
        NSMutableArray<UIViewController *> *queue=
            [NSMutableArray arrayWithObject:activeWindow.rootViewController];
        for (NSUInteger i=0;i<queue.count && i<160;i++) {
            UIViewController *vc=queue[i];
            [objects addObject:vc];
            if (vc.presentedViewController &&
                ![queue containsObject:vc.presentedViewController]) {
                [queue addObject:vc.presentedViewController];
            }
            for (UIViewController *child in vc.childViewControllers ?: @[]) {
                if (![queue containsObject:child]) [queue addObject:child];
            }
        }
    }

    id appDelegate=UIApplication.sharedApplication.delegate;
    if (appDelegate) [objects addObject:appDelegate];

    for (id object in objects) {
        if (XLGToastBridgeIsToaster(object)) {
            XLGToastBridgeCaptureToaster(object,@"hierarchy-object");
            return object;
        }

        for (NSString *selectorName in @[
                @"defaultToaster",
                @"toaster"
            ]) {
            id candidate=XLGToastBridgeValueBySelector(
                object,selectorName);
            if (XLGToastBridgeIsToaster(candidate)) {
                XLGToastBridgeCaptureToaster(
                    candidate,
                    [NSString stringWithFormat:@"%@.%@",
                        NSStringFromClass([object class]),
                        selectorName]);
                return candidate;
            }
        }
    }

    return nil;
}

static UIWindow *XLGToastBridgeExistingToastWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) {
            if ([NSStringFromClass(window.class)
                    isEqualToString:@"TFNToastWindow"]) {
                return window;
            }
        }
    }
    return nil;
}

static BOOL XLGToastBridgeEnsureHost(id toaster) {
    if (!XLGEnabled() || !XLGToastBridgeIsToaster(toaster)) return NO;

    SEL toastVCSEL=NSSelectorFromString(@"toastViewController");
    if ([toaster respondsToSelector:toastVCSEL]) {
        id existing=((id(*)(id,SEL))objc_msgSend)(
            toaster,toastVCSEL);
        if ([existing isKindOfClass:UIViewController.class]) {
            XLGToastBridgeLog(
                @"HOST_READY existingVC=%@ ptr=%p",
                NSStringFromClass([existing class]),
                existing);
            return YES;
        }
    }

    UIWindow *window=XLGToastBridgeExistingToastWindow();
    if (!window) window=gXLGToastBridgeWindow;

    id toastVC=nil;
    if (window &&
        [window respondsToSelector:
            NSSelectorFromString(@"toastViewController")]) {
        toastVC=((id(*)(id,SEL))objc_msgSend)(
            window,NSSelectorFromString(@"toastViewController"));
    }

    if (!window) {
        Class windowClass=NSClassFromString(@"TFNToastWindow");
        SEL initSEL=NSSelectorFromString(@"initWithFrame:toaster:");
        if (!windowClass ||
            !class_getInstanceMethod(windowClass,initSEL)) {
            XLGToastBridgeLog(@"HOST_FAIL missing-TFNToastWindow-init");
            return NO;
        }

        UIWindow *active=XLGSidebarActiveWindow();
        CGRect frame=active ? active.bounds : UIScreen.mainScreen.bounds;

        id allocated=((id(*)(id,SEL))objc_msgSend)(
            windowClass,@selector(alloc));
        window=((id(*)(id,SEL,CGRect,id))objc_msgSend)(
            allocated,initSEL,frame,toaster);

        if (![window isKindOfClass:UIWindow.class]) {
            XLGToastBridgeLog(@"HOST_FAIL window-create returned=%@",
                              window ? NSStringFromClass([window class])
                                     : @"nil");
            return NO;
        }

        if (@available(iOS 13.0,*)) {
            if (active.windowScene) {
                window.windowScene=active.windowScene;
            }
        }

        if ([window respondsToSelector:toastVCSEL]) {
            toastVC=((id(*)(id,SEL))objc_msgSend)(
                window,toastVCSEL);
        }

        gXLGToastBridgeWindow=window;
        XLGToastBridgeLog(
            @"HOST_WINDOW_CREATED class=%@ ptr=%p toastVC=%@ ptr=%p frame=%@",
            NSStringFromClass(window.class),
            window,
            toastVC ? NSStringFromClass([toastVC class]) : @"nil",
            toastVC,
            NSStringFromCGRect(window.frame));
    }

    if (![toastVC isKindOfClass:UIViewController.class]) {
        Class vcClass=NSClassFromString(@"TFNToastViewController");
        if (vcClass) {
            id candidate=((id(*)(id,SEL))objc_msgSend)(
                vcClass,@selector(new));
            if ([candidate isKindOfClass:UIViewController.class]) {
                toastVC=candidate;
                XLGToastBridgeLog(
                    @"HOST_VC_FALLBACK_CREATED class=%@ ptr=%p",
                    NSStringFromClass([candidate class]),
                    candidate);
            }
        }
    }

    if (![toastVC isKindOfClass:UIViewController.class]) {
        XLGToastBridgeLog(@"HOST_FAIL no-toast-view-controller");
        return NO;
    }

    if (!window.rootViewController) {
        window.rootViewController=toastVC;
    }

    SEL registerSEL=NSSelectorFromString(@"registerToastViewController:");
    if ([toaster respondsToSelector:registerSEL]) {
        ((void(*)(id,SEL,id))objc_msgSend)(
            toaster,registerSEL,toastVC);
    } else {
        SEL setSEL=NSSelectorFromString(@"setToastViewController:");
        if ([toaster respondsToSelector:setSEL]) {
            ((void(*)(id,SEL,id))objc_msgSend)(
                toaster,setSEL,toastVC);
        }
    }

    id registered=nil;
    if ([toaster respondsToSelector:toastVCSEL]) {
        registered=((id(*)(id,SEL))objc_msgSend)(
            toaster,toastVCSEL);
    }

    BOOL ready=[registered isKindOfClass:UIViewController.class];
    XLGToastBridgeLog(
        @"HOST_RESULT ready=%@ window=%@ hidden=%@ root=%@ registered=%@",
        ready ? @"YES" : @"NO",
        window ? NSStringFromClass(window.class) : @"nil",
        window.hidden ? @"YES" : @"NO",
        window.rootViewController
            ? NSStringFromClass(window.rootViewController.class) : @"nil",
        registered ? NSStringFromClass([registered class]) : @"nil");
    return ready;
}

static id XLGToastBridgeToasterInit(id self, SEL cmd) {
    id result=self;
    if (gOrigToastBridgeToasterInit) {
        result=((id(*)(id,SEL))
            gOrigToastBridgeToasterInit)(self,cmd);
    }
    XLGToastBridgeCaptureToaster(result,@"TFNToaster.init");
    if (XLGEnabled()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            XLGToastBridgeEnsureHost(result);
        });
    }
    return result;
}

static void XLGToastBridgeRegisterVC(id self,
                                     SEL cmd,
                                     id controller) {
    XLGToastBridgeCaptureToaster(self,@"registerToastViewController");
    if (gOrigToastBridgeRegisterVC) {
        ((void(*)(id,SEL,id))
            gOrigToastBridgeRegisterVC)(self,cmd,controller);
    }
    XLGToastBridgeLog(
        @"REGISTER_VC controller=%@ ptr=%p",
        controller ? NSStringFromClass([controller class]) : @"nil",
        controller);
}

static void XLGToastBridgePushToast(id self,
                                    SEL cmd,
                                    id toast) {
    XLGToastBridgeCaptureToaster(self,@"pushToast:");
    if (toast) {
        objc_setAssociatedObject(
            toast,&kXLGToastBridgePushedKey,@YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (XLGEnabled()) {
        XLGToastBridgeEnsureHost(self);
    }

    XLGToastBridgeLog(
        @"PUSH toastClass=%@ ptr=%p message=%@",
        toast ? NSStringFromClass([toast class]) : @"nil",
        toast,
        XLGToastBridgeValueBySelector(toast,@"messageText") ?: @"-");

    if (gOrigToastBridgePushToast) {
        ((void(*)(id,SEL,id))
            gOrigToastBridgePushToast)(self,cmd,toast);
    }
}

static void XLGToastBridgePushToastPriority(id self,
                                            SEL cmd,
                                            id toast,
                                            unsigned long long priority) {
    XLGToastBridgeCaptureToaster(self,@"pushToast:withPriority:");
    if (toast) {
        objc_setAssociatedObject(
            toast,&kXLGToastBridgePushedKey,@YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (XLGEnabled()) {
        XLGToastBridgeEnsureHost(self);
    }

    XLGToastBridgeLog(
        @"PUSH_PRIORITY toastClass=%@ ptr=%p priority=%llu",
        toast ? NSStringFromClass([toast class]) : @"nil",
        toast,
        priority);

    if (gOrigToastBridgePushToastPriority) {
        ((void(*)(id,SEL,id,unsigned long long))
            gOrigToastBridgePushToastPriority)(
                self,cmd,toast,priority);
    }
}

static id XLGToastBridgeTweetSentInit(
    id self,
    SEL cmd,
    id status,
    id communityReference,
    unsigned long long sendCount,
    BOOL editEnabled,
    id account,
    id tweetText,
    id presentingViewController) {

    id result=nil;
    if (gOrigToastBridgeTweetSentInit) {
        result=((id(*)(id,SEL,id,id,unsigned long long,BOOL,id,id,id))
            gOrigToastBridgeTweetSentInit)(
                self,cmd,status,communityReference,sendCount,editEnabled,
                account,tweetText,presentingViewController);
    }

    if (!result) return result;

    if (status) {
        objc_setAssociatedObject(
            status,
            &kXLGToastBridgeStatusHasToastKey,
            @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    XLGToastBridgeLog(
        @"TWEET_TOAST_INIT ptr=%p message=%@ sendCount=%llu presenter=%@ liquidGlass=%@",
        result,
        XLGToastBridgeValueBySelector(result,@"messageText") ?: @"-",
        sendCount,
        presentingViewController
            ? NSStringFromClass([presentingViewController class]) : @"nil",
        XLGEnabled() ? @"ON" : @"OFF");

    if (!XLGEnabled()) return result;

    if (![objc_getAssociatedObject(
            result,&kXLGToastBridgeScheduledKey) boolValue]) {
        objc_setAssociatedObject(
            result,&kXLGToastBridgeScheduledKey,@YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        __weak id weakToast=result;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(0.08*NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                id toast=weakToast;
                if (!toast || !XLGEnabled()) return;

                if ([objc_getAssociatedObject(
                        toast,&kXLGToastBridgePushedKey) boolValue]) {
                    XLGToastBridgeLog(
                        @"DIRECT_SKIP already-pushed ptr=%p",
                        toast);
                    return;
                }

                id toaster=XLGToastBridgeFindToaster();
                if (!toaster) {
                    XLGToastBridgeLog(
                        @"DIRECT_FAIL no-toaster toast=%p",
                        toast);
                    return;
                }

                if (!XLGToastBridgeEnsureHost(toaster)) {
                    XLGToastBridgeLog(
                        @"DIRECT_FAIL no-host toaster=%p toast=%p",
                        toaster,toast);
                    return;
                }

                XLGToastBridgeLog(
                    @"DIRECT_PUSH toast=%p message=%@ toaster=%p",
                    toast,
                    XLGToastBridgeValueBySelector(
                        toast,@"messageText") ?: @"-",
                    toaster);

                SEL pushSEL=NSSelectorFromString(@"pushToast:");
                if ([toaster respondsToSelector:pushSEL]) {
                    ((void(*)(id,SEL,id))objc_msgSend)(
                        toaster,pushSEL,toast);
                }
            });
    }

    return result;
}


static void XLGToastBridgeHandleCompositionDidSend(
    NSNotification *notification) {

    if (!XLGEnabled() || !notification) return;

    id composition=notification.object;
    id status=
        [notification.userInfo isKindOfClass:NSDictionary.class]
            ? notification.userInfo[@"status"] : nil;

    if (!composition || !status) {
        XLGToastBridgeLog(
            @"COMPOSITION_SKIP missing composition/status object=%@ status=%@",
            composition ? NSStringFromClass([composition class]) : @"nil",
            status ? NSStringFromClass([status class]) : @"nil");
        return;
    }

    if ([objc_getAssociatedObject(
            composition,
            &kXLGToastBridgeCompositionHandledKey) boolValue]) {
        XLGToastBridgeLog(
            @"COMPOSITION_SKIP already-handled composition=%p status=%p",
            composition,status);
        return;
    }

    objc_setAssociatedObject(
        composition,
        &kXLGToastBridgeCompositionHandledKey,
        @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    XLGToastBridgeLog(
        @"COMPOSITION_EVENT object=%@ ptr=%p status=%@ ptr=%p",
        NSStringFromClass([composition class]),
        composition,
        NSStringFromClass([status class]),
        status);

    // Keep both payload objects alive until the deferred presentation. The
    // did-send notification owns them only for the duration of delivery.
    // Beta 4 used weak references here, which allowed them to disappear
    // before the 60 ms presentation window elapsed.
    id capturedComposition=composition;
    id capturedStatus=status;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(0.06*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            id strongComposition=capturedComposition;
            id strongStatus=capturedStatus;
            if (!strongComposition || !strongStatus || !XLGEnabled()) {
                XLGToastBridgeLog(
                    @"COMPOSITION_ABORT composition=%p status=%p liquidGlass=%@",
                    strongComposition,
                    strongStatus,
                    XLGEnabled() ? @"ON" : @"OFF");
                return;
            }

            if ([objc_getAssociatedObject(
                    strongStatus,
                    &kXLGToastBridgeStatusHasToastKey) boolValue]) {
                XLGToastBridgeLog(
                    @"COMPOSITION_SKIP native-toast-exists status=%p",
                    strongStatus);
                return;
            }

            id account=XLGSidebarCurrentAccount();
            UIViewController *presenter=
                XLGSidebarContentPresentingViewController();

            UINavigationController *presenterNavigation=
                XLGNavigationControllerForPresenter(presenter);
            if (presenterNavigation.topViewController) {
                presenter=presenterNavigation.topViewController;
            }

            id toaster=XLGToastBridgeFindToaster();

            if (!account || !presenter || !toaster) {
                XLGToastBridgeLog(
                    @"COMPOSITION_FAIL account=%@ presenter=%@ toaster=%@",
                    account ? NSStringFromClass([account class]) : @"nil",
                    presenter ? NSStringFromClass(presenter.class) : @"nil",
                    toaster ? NSStringFromClass([toaster class]) : @"nil");
                return;
            }

            if (!XLGToastBridgeEnsureHost(toaster)) {
                XLGToastBridgeLog(
                    @"COMPOSITION_FAIL host-not-ready toaster=%p",
                    toaster);
                return;
            }

            Class toastClass=NSClassFromString(@"T1TweetSentToast");
            SEL initSEL=NSSelectorFromString(
                @"initWithStatus:communityReference:sendCount:isStatusEditCreationEnabled:account:tweetText:presentingViewController:");

            Method initMethod=
                toastClass ? class_getInstanceMethod(toastClass,initSEL) : NULL;
            if (!toastClass ||
                !initMethod ||
                method_getNumberOfArguments(initMethod)!=9) {
                XLGToastBridgeLog(
                    @"COMPOSITION_FAIL toast-constructor-missing");
                return;
            }

            id communityReference=
                XLGToastBridgeValueBySelector(
                    strongComposition,@"communityReference");
            id tweetText=
                XLGToastBridgeValueBySelector(
                    strongComposition,@"text");

            if (![tweetText isKindOfClass:NSString.class]) {
                tweetText=
                    XLGToastBridgeValueBySelector(
                        strongStatus,@"text");
            }

            id allocated=((id(*)(id,SEL))objc_msgSend)(
                toastClass,@selector(alloc));

            // A did-send notification represents one successfully sent
            // composition. Edit eligibility only controls the optional edit
            // action; keeping it NO preserves the sent confirmation itself.
            id toast=
                ((id(*)(id,SEL,id,id,unsigned long long,BOOL,id,id,id))
                    objc_msgSend)(
                        allocated,
                        initSEL,
                        strongStatus,
                        communityReference,
                        1,
                        NO,
                        account,
                        tweetText,
                        presenter);

            if (!toast) {
                XLGToastBridgeLog(
                    @"COMPOSITION_FAIL toast-init-returned-nil status=%p",
                    strongStatus);
                return;
            }

            XLGToastBridgeLog(
                @"COMPOSITION_TOAST_CREATED toast=%p status=%p message=%@ presenter=%@",
                toast,
                strongStatus,
                XLGToastBridgeValueBySelector(
                    toast,@"messageText") ?: @"-",
                NSStringFromClass(presenter.class));

            // XLGToastBridgeTweetSentInit schedules the native push. If this
            // initializer is ever no longer hooked, use the same native
            // toaster as a fallback.
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(0.12*NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    if ([objc_getAssociatedObject(
                            toast,
                            &kXLGToastBridgePushedKey) boolValue]) {
                        return;
                    }

                    SEL pushSEL=NSSelectorFromString(@"pushToast:");
                    if ([toaster respondsToSelector:pushSEL]) {
                        XLGToastBridgeLog(
                            @"COMPOSITION_FALLBACK_PUSH toast=%p",
                            toast);
                        ((void(*)(id,SEL,id))objc_msgSend)(
                            toaster,pushSEL,toast);
                    }
                });
        });
}

static void XLGInstallCompositionSentToastBridge(void) {
    if (gXLGToastBridgeCompositionObserver) return;

    NSString *name=@"TwitterCompositionDidSendNotification";
    gXLGToastBridgeCompositionObserver=
        [NSNotificationCenter.defaultCenter
            addObserverForName:name
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *notification) {
                        XLGToastBridgeHandleCompositionDidSend(notification);
                    }];

    XLGToastBridgeLog(
        @"COMPOSITION_BRIDGE observer=%p name=%@",
        gXLGToastBridgeCompositionObserver,
        name);
}

static void XLGInstallToastBridge(void) {
    if (gXLGToastBridgeInstalled) return;

    Class toasterClass=NSClassFromString(@"TFNToaster");
    Class toastClass=NSClassFromString(@"T1TweetSentToast");
    if (!toasterClass || !toastClass) return;

    BOOL any=NO;

    any |= XLGHookMethod(
        toasterClass,@selector(init),NO,
        (IMP)XLGToastBridgeToasterInit,
        &gOrigToastBridgeToasterInit);

    any |= XLGHookMethod(
        toasterClass,
        NSSelectorFromString(@"registerToastViewController:"),
        NO,
        (IMP)XLGToastBridgeRegisterVC,
        &gOrigToastBridgeRegisterVC);

    any |= XLGHookMethod(
        toasterClass,
        NSSelectorFromString(@"pushToast:"),
        NO,
        (IMP)XLGToastBridgePushToast,
        &gOrigToastBridgePushToast);

    any |= XLGHookMethod(
        toasterClass,
        NSSelectorFromString(@"pushToast:withPriority:"),
        NO,
        (IMP)XLGToastBridgePushToastPriority,
        &gOrigToastBridgePushToastPriority);

    SEL initSEL=NSSelectorFromString(
        @"initWithStatus:communityReference:sendCount:isStatusEditCreationEnabled:account:tweetText:presentingViewController:");
    Method initMethod=class_getInstanceMethod(toastClass,initSEL);
    if (initMethod &&
        method_getNumberOfArguments(initMethod)==9) {
        any |= XLGHookMethod(
            toastClass,initSEL,NO,
            (IMP)XLGToastBridgeTweetSentInit,
            &gOrigToastBridgeTweetSentInit);
    }

    gXLGToastBridgeInstalled=any;

    if (any) {
        XLGToastBridgeLog(
            @"liquidGlass=%@ appNavigation=%@",
            XLGEnabled() ? @"ON" : @"OFF",
            XLGSidebarAppNavigation()
                ? NSStringFromClass([XLGSidebarAppNavigation() class])
                : @"nil");

        XLGInstallCompositionSentToastBridge();

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(0.35*NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (!XLGEnabled()) return;
                id toaster=XLGToastBridgeFindToaster();
                XLGToastBridgeLog(
                    @"STARTUP_FIND toaster=%@ ptr=%p",
                    toaster ? NSStringFromClass([toaster class]) : @"nil",
                    toaster);
                if (toaster) XLGToastBridgeEnsureHost(toaster);
            });
    }
}

#pragma mark - XLiquidGlass Beta 3 native Guide router + navigation probe

static NSString *XLGNavigationProbeLogPath(void) {
    NSString *documents=
        NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    if (!documents.length) return nil;
    return [documents
        stringByAppendingPathComponent:
            @"XLiquidGlass190Beta3.log"];
}

static NSString *XLGNavigationProbeTimestamp(void) {
    NSDateFormatter *formatter=[[NSDateFormatter alloc] init];
    formatter.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat=@"yyyy-MM-dd HH:mm:ss.SSS";
    return [formatter stringFromDate:NSDate.date] ?: @"-";
}

static void XLGNavigationProbeLog(NSString *format, ...) {
    if (!gXLGNavigationProbeActive || !format.length) return;

    va_list args;
    va_start(args,format);
    NSString *message=
        [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line=[NSString stringWithFormat:@"[%@] %@\n",
                    XLGNavigationProbeTimestamp(),
                    message ?: @"-"];
    NSLog(@"[XLiquidGlass/NavProbe] %@",message ?: @"-");

    NSString *path=XLGNavigationProbeLogPath();
    if (!path.length) return;

    @synchronized(NSFileManager.defaultManager) {
        NSData *data=[line dataUsingEncoding:NSUTF8StringEncoding];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [NSFileManager.defaultManager createFileAtPath:path
                                                  contents:nil
                                                attributes:nil];
        }
        @try {
            NSFileHandle *handle=
                [NSFileHandle fileHandleForWritingAtPath:path];
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        } @catch (__unused NSException *exception) {
        }
    }
}

static __attribute__((unused)) NSString *XLGNavigationProbeRead(void) {
    NSString *path=XLGNavigationProbeLogPath();
    if (!path.length) return @"";
    NSData *data=[NSData dataWithContentsOfFile:path];
    if (!data.length) return @"";
    return [[NSString alloc] initWithData:data
                                encoding:NSUTF8StringEncoding] ?: @"";
}

static __attribute__((unused)) void XLGNavigationProbeClear(void) {
    NSString *path=XLGNavigationProbeLogPath();
    if (!path.length) return;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

static NSString *XLGNavigationProbeTypeEncodingForSelector(
    id object,
    NSString *selectorName) {
    if (!object || !selectorName.length) return @"-";
    SEL selector=NSSelectorFromString(selectorName);
    Method method=class_getInstanceMethod([object class],selector);
    if (!method) return @"-";
    const char *types=method_getTypeEncoding(method);
    return types ? [NSString stringWithUTF8String:types] : @"-";
}

static NSString *XLGNavigationProbeStackDescription(
    UINavigationController *navigation) {
    if (!navigation) return @"-";
    NSMutableArray<NSString *> *names=[NSMutableArray array];
    for (UIViewController *vc in navigation.viewControllers ?: @[]) {
        [names addObject:NSStringFromClass(vc.class) ?: @"?"];
    }
    return [names componentsJoinedByString:@" -> "];
}

static void XLGNavigationProbeRuntimeSnapshot(NSString *reason) {
    if (!gXLGNavigationProbeActive) return;

    id appNavigation=XLGSidebarAppNavigation();
    id account=XLGSidebarCurrentAccount();
    UIViewController *presenter=XLGSidebarContentPresentingViewController();
    UINavigationController *navigation=
        XLGNavigationControllerForPresenter(presenter);

    XLGNavigationProbeLog(
        @"========== RUNTIME %@ ==========",reason ?: @"snapshot");
    XLGNavigationProbeLog(
        @"liquidGlass=%@ appNavigationClass=%@ ptr=%p accountClass=%@ userID=%@",
        XLGEnabled() ? @"ON" : @"OFF",
        appNavigation ? NSStringFromClass([appNavigation class]) : @"nil",
        appNavigation,
        account ? NSStringFromClass([account class]) : @"nil",
        XLGTryResolveUserID(account,0) ?: @"-");
    XLGNavigationProbeLog(
        @"presenterClass=%@ ptr=%p navigationClass=%@ ptr=%p top=%@ presented=%@",
        presenter ? NSStringFromClass(presenter.class) : @"nil",
        presenter,
        navigation ? NSStringFromClass(navigation.class) : @"nil",
        navigation,
        navigation.topViewController
            ? NSStringFromClass(navigation.topViewController.class)
            : @"nil",
        presenter.presentedViewController
            ? NSStringFromClass(presenter.presentedViewController.class)
            : @"nil");
    XLGNavigationProbeLog(
        @"stack=%@",XLGNavigationProbeStackDescription(navigation));

    NSArray<NSString *> *selectors=@[
        @"showProfileForUsername:orUserID:fromPanel:source:sourceNavigationMetadata:completion:",
        @"showAiTrendDetailsWithID:mode:account:source:completion:",
        @"showTrendsWithSource:scribeContext:completion:",
        @"showTrendsSettingsWithSource:completion:",
        @"showExploreWithSource:completion:",
        @"showExploreWithSource:scribeContext:completion:",
        @"showSearchWithQuery:source:completion:",
        @"showSearchWithQuery:querySource:completion:",
        @"showSearchWithQuery:querySource:scribeContext:completion:",
        @"showSearchSettingsWithSource:completion:",
        @"showNewsWithSource:completion:",
        @"showNewsWithSource:scribeContext:completion:",
        @"showPremiumHubWithSource:withCompletion:",
        @"showPremiumHubAfterPurchaseWithSource:withCompletion:",
        @"showPremiumHubPremiumSettingsWithSource:withCompletion:",
        @"showDisplaySettingsWithSource:withCompletion:",
        @"showPremiumPageWithReferringPage:tier:plan:source:paywallThresholdTier:withCompletion:",
        @"showPremiumPageWithReferringPage:tier:plan:source:withCompletion:",
        @"showPremiumPageWithReferringPage:tier:source:withCompletion:",
        @"showSubscriptionsTab",
        @"handlePremiumHubPanelKeyCommand",
        @"currentPanelNavigationController",
        @"presentPanelIfNeededWithPanelID:animated:successCompletion:"
    ];

    for (NSString *name in selectors) {
        SEL selector=NSSelectorFromString(name);
        BOOL responds=appNavigation &&
            [appNavigation respondsToSelector:selector];
        XLGNavigationProbeLog(
            @"SELECTOR %@ responds=%@ types=%@",
            name,
            responds ? @"YES" : @"NO",
            responds
                ? XLGNavigationProbeTypeEncodingForSelector(
                    appNavigation,name)
                : @"-");
    }

    if (appNavigation) {
        unsigned int methodCount=0;
        Method *methods=class_copyMethodList(
            [appNavigation class],&methodCount);
        for (unsigned int i=0;i<methodCount;i++) {
            SEL sel=method_getName(methods[i]);
            NSString *name=NSStringFromSelector(sel);
            NSString *lower=name.lowercaseString;
            if ([lower containsString:@"trend"] ||
                [lower containsString:@"explore"] ||
                [lower containsString:@"search"] ||
                [lower containsString:@"news"] ||
                [lower containsString:@"premium"] ||
                [lower containsString:@"display"] ||
                [lower containsString:@"subscription"] ||
                [lower containsString:@"profile"] ||
                [lower containsString:@"user"]) {
                const char *types=method_getTypeEncoding(methods[i]);
                XLGNavigationProbeLog(
                    @"APPNAV_METHOD %@ types=%s",
                    name,
                    types ?: "-");
            }
        }
        if (methods) free(methods);
    }

    for (NSString *className in @[
        @"T1TwitterSwift.GuideContainerViewController",
        @"_TtC14T1TwitterSwift28GuideContainerViewController",
        @"T1TrendingPageViewControllerFactory",
        @"T1TwitterSwift.GuideContainerViewController",
        @"_TtC14T1TwitterSwift28GuideContainerViewController",
        @"T1TrendsLandingViewController",
        @"T1SearchViewController",
        @"T1SearchResultsViewController",
        @"T1ExploreViewController",
        @"T1ExploreLandingViewController",
        @"T1NewsViewController",
        @"_TtC14T1TwitterSwift26TrendingPageViewController",
        @"_TtC14T1TwitterSwift27TrendURTUrlNavigationHelper",
        @"_TtC14T1TwitterSwift33PremiumHubContainerViewController",
        @"_TtC14T1TwitterSwift30PremiumHubNavigationController",
        @"_TtC14T1TwitterSwift31PremiumHubAppNavigationTabEntry",
        @"_TtC14T1TwitterSwift22T1PremiumHubNavigation",
        @"T1PremiumSettingsViewController",
        @"T1DisplaySettingsViewController"
    ]) {
        Class cls=NSClassFromString(className);
        XLGNavigationProbeLog(
            @"CLASS %@ present=%@",
            className,cls ? @"YES" : @"NO");
    }

    XLGNavigationProbeLog(@"========== END RUNTIME ==========");
}

static void XLGNavProbePushViewController(
    id self,
    SEL cmd,
    UIViewController *viewController,
    BOOL animated) {
    UINavigationController *nav=
        [self isKindOfClass:UINavigationController.class]
            ? (UINavigationController *)self : nil;

    if (gXLGNavigationProbeActive) {
        XLGNavigationProbeLog(
            @"PUSH nav=%@ ptr=%p from=%@ to=%@ ptr=%p animated=%@ stackBefore=%@",
            NSStringFromClass([self class]),
            self,
            nav.topViewController
                ? NSStringFromClass(nav.topViewController.class)
                : @"nil",
            viewController
                ? NSStringFromClass(viewController.class)
                : @"nil",
            viewController,
            animated ? @"YES" : @"NO",
            XLGNavigationProbeStackDescription(nav));
    }

    // Beta 4: T1GuideNavigationController is still the native router used by
    // Explore in the classic hierarchy. Under Liquid Glass we keep an
    // off-screen native instance alive only for routing. If that router tries
    // to push, forward the exact destination into the visible XNavigation
    // controller instead of placing it on the detached legacy stack.
    BOOL guideBridge=
        XLGEnabled() &&
        nav &&
        [objc_getAssociatedObject(nav,&kXLGGuideBridgeMarkerKey) boolValue];

    if (guideBridge && viewController) {
        UIViewController *presenter=
            XLGSidebarContentPresentingViewController();
        UINavigationController *visibleNavigation=
            XLGNavigationControllerForPresenter(presenter);

        if (visibleNavigation &&
            visibleNavigation!=nav &&
            !viewController.parentViewController &&
            !viewController.navigationController) {

            if (gXLGNavigationProbeActive) {
                XLGNavigationProbeLog(
                    @"GUIDE_BRIDGE forward hiddenNav=%@ ptr=%p visibleNav=%@ ptr=%p destination=%@ ptr=%p visibleStack=%@",
                    NSStringFromClass(nav.class),
                    nav,
                    NSStringFromClass(visibleNavigation.class),
                    visibleNavigation,
                    NSStringFromClass(viewController.class),
                    viewController,
                    XLGNavigationProbeStackDescription(visibleNavigation));
            }

            [visibleNavigation pushViewController:viewController
                                         animated:animated];
            return;
        }

        if (gXLGNavigationProbeActive) {
            XLGNavigationProbeLog(
                @"GUIDE_BRIDGE could-not-forward visibleNav=%@ destinationParent=%@ destinationNav=%@",
                visibleNavigation
                    ? NSStringFromClass(visibleNavigation.class) : @"nil",
                viewController.parentViewController
                    ? NSStringFromClass(viewController.parentViewController.class)
                    : @"nil",
                viewController.navigationController
                    ? NSStringFromClass(viewController.navigationController.class)
                    : @"nil");
        }
    }

    if (gOrigNavProbePushViewController) {
        ((void(*)(id,SEL,id,BOOL))gOrigNavProbePushViewController)(
            self,cmd,viewController,animated);
    }
}

static void XLGNavProbePresentViewController(
    id self,
    SEL cmd,
    UIViewController *viewController,
    BOOL animated,
    id completion) {
    if (gXLGNavigationProbeActive) {
        XLGNavigationProbeLog(
            @"PRESENT from=%@ ptr=%p to=%@ ptr=%p animated=%@",
            NSStringFromClass([self class]),
            self,
            viewController
                ? NSStringFromClass(viewController.class)
                : @"nil",
            viewController,
            animated ? @"YES" : @"NO");
    }

    if (gOrigNavProbePresentViewController) {
        ((void(*)(id,SEL,id,BOOL,id))gOrigNavProbePresentViewController)(
            self,cmd,viewController,animated,completion);
    }
}

static void XLGNavProbeOpenURL(
    id self,
    SEL cmd,
    NSURL *url,
    NSDictionary *options,
    id completion) {
    if (gXLGNavigationProbeActive) {
        XLGNavigationProbeLog(
            @"UIAPPLICATION_OPENURL url=%@ options=%@",
            url.absoluteString ?: [url description] ?: @"-",
            options ?: @{});
    }

    if (gOrigNavProbeOpenURL) {
        ((void(*)(id,SEL,id,id,id))gOrigNavProbeOpenURL)(
            self,cmd,url,options,completion);
    }
}

static void XLGNavProbeT1OpenURL(
    id self,
    SEL cmd,
    id url) {
    if (gXLGNavigationProbeActive) {
        XLGNavigationProbeLog(
            @"T1_OPENURL owner=%@ urlClass=%@ value=%@",
            NSStringFromClass([self class]),
            url ? NSStringFromClass([url class]) : @"nil",
            url ?: @"-");
    }

    if (gOrigNavProbeT1OpenURL) {
        ((void(*)(id,SEL,id))gOrigNavProbeT1OpenURL)(
            self,cmd,url);
    }
}

static IMP XLGNavProbeOriginalViewDidAppear(id self) {
    Class cls=[self class];
    while (cls) {
        NSValue *value=
            gXLGNavProbeViewAppearOriginals[NSStringFromClass(cls)];
        if (value) return [value pointerValue];
        cls=class_getSuperclass(cls);
    }
    return NULL;
}

static void XLGNavProbeTargetViewDidAppear(
    id self,
    SEL cmd,
    BOOL animated) {
    IMP original=XLGNavProbeOriginalViewDidAppear(self);
    if (original && original!=(IMP)XLGNavProbeTargetViewDidAppear) {
        ((void(*)(id,SEL,BOOL))original)(self,cmd,animated);
    }

    if (gXLGNavigationProbeActive) {
        XLGNavigationProbeLog(
            @"TARGET_APPEAR class=%@ ptr=%p animated=%@ nav=%@",
            NSStringFromClass([self class]),
            self,
            animated ? @"YES" : @"NO",
            [self navigationController]
                ? NSStringFromClass([[self navigationController] class])
                : @"nil");
        XLGNavigationProbeRuntimeSnapshot(@"target-appeared");
    }
}

static id XLGNavProbeTrendingFactoryCreate(
    id self,
    SEL cmd,
    id account,
    long long trendID,
    id mode) {
    UIViewController *beforePresenter=
        XLGSidebarContentPresentingViewController();
    UINavigationController *beforeNavigation=
        XLGNavigationControllerForPresenter(beforePresenter);
    UIViewController *beforeTop=beforeNavigation.topViewController;
    UIViewController *beforePresented=
        beforePresenter.presentedViewController;

    if (gXLGNavigationProbeActive) {
        XLGNavigationProbeLog(
            @"GUIDE_FACTORY before accountClass=%@ userID=%@ trendID=%lld modeClass=%@ mode=%@ nav=%@ top=%@",
            account ? NSStringFromClass([account class]) : @"nil",
            XLGTryResolveUserID(account,0) ?: @"-",
            trendID,
            mode ? NSStringFromClass([mode class]) : @"nil",
            mode ?: @"-",
            beforeNavigation ? NSStringFromClass(beforeNavigation.class) : @"nil",
            beforeTop ? NSStringFromClass(beforeTop.class) : @"nil");
    }

    id result=nil;
    if (gOrigNavProbeTrendingFactoryCreate) {
        result=((id(*)(id,SEL,id,long long,id))
                gOrigNavProbeTrendingFactoryCreate)(
                    self,cmd,account,trendID,mode);
    }

    if (gXLGNavigationProbeActive) {
        XLGNavigationProbeLog(
            @"GUIDE_FACTORY after resultClass=%@ ptr=%p",
            result ? NSStringFromClass([result class]) : @"nil",
            result);
    }

    // Beta 3: keep XNavigation as the outer architecture. The factory already
    // gives us X's native destination. Give X a short window to route it itself;
    // only if the Liquid Glass hierarchy stays unchanged do we push that exact
    // native destination onto the current navigation stack.
    if (XLGEnabled() &&
        [result isKindOfClass:UIViewController.class]) {
        UIViewController *destination=(UIViewController *)result;

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(0.18*NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (!XLGEnabled()) return;

                UIWindow *window=XLGSidebarActiveWindow();
                UIViewController *root=window.rootViewController;
                if (root &&
                    XLGHierarchyContainsViewController(root,destination)) {
                    if (gXLGNavigationProbeActive) {
                        XLGNavigationProbeLog(
                            @"GUIDE_ROUTER native-success destination=%@ ptr=%p",
                            NSStringFromClass(destination.class),
                            destination);
                    }
                    return;
                }

                UIViewController *afterPresenter=
                    XLGSidebarContentPresentingViewController();
                UINavigationController *afterNavigation=
                    XLGNavigationControllerForPresenter(afterPresenter);
                UIViewController *afterTop=
                    afterNavigation.topViewController;
                UIViewController *afterPresented=
                    afterPresenter.presentedViewController;

                BOOL hierarchyChanged=
                    (beforeTop && afterTop && beforeTop!=afterTop) ||
                    (afterPresented &&
                     afterPresented!=beforePresented) ||
                    (beforePresenter && afterPresenter &&
                     beforePresenter!=afterPresenter);

                if (hierarchyChanged) {
                    if (gXLGNavigationProbeActive) {
                        XLGNavigationProbeLog(
                            @"GUIDE_ROUTER native-changed destination=%@ currentTop=%@",
                            NSStringFromClass(destination.class),
                            afterTop ? NSStringFromClass(afterTop.class) : @"nil");
                    }
                    return;
                }

                UINavigationController *navigation=
                    afterNavigation ?: beforeNavigation;

                if (!navigation ||
                    destination.navigationController ||
                    destination.parentViewController) {
                    if (gXLGNavigationProbeActive) {
                        XLGNavigationProbeLog(
                            @"GUIDE_ROUTER fallback-skipped nav=%@ parent=%@ destinationNav=%@",
                            navigation ? NSStringFromClass(navigation.class) : @"nil",
                            destination.parentViewController
                                ? NSStringFromClass(destination.parentViewController.class)
                                : @"nil",
                            destination.navigationController
                                ? NSStringFromClass(destination.navigationController.class)
                                : @"nil");
                    }
                    return;
                }

                if ([navigation.viewControllers containsObject:destination]) {
                    return;
                }

                if (gXLGNavigationProbeActive) {
                    XLGNavigationProbeLog(
                        @"GUIDE_ROUTER fallback-push nav=%@ ptr=%p destination=%@ ptr=%p stackBefore=%@",
                        NSStringFromClass(navigation.class),
                        navigation,
                        NSStringFromClass(destination.class),
                        destination,
                        XLGNavigationProbeStackDescription(navigation));
                }

                [navigation pushViewController:destination animated:YES];
            });
    }

    return result;
}

static BOOL XLGNavProbeMethodMatchesTrendingFactory(
    Class cls,
    SEL selector) {
    Method method=class_getClassMethod(cls,selector);
    if (!method || method_getNumberOfArguments(method)!=5) return NO;

    char ret[32]={0},a2[32]={0},a3[32]={0},a4[32]={0};
    method_getReturnType(method,ret,sizeof(ret));
    method_getArgumentType(method,2,a2,sizeof(a2));
    method_getArgumentType(method,3,a3,sizeof(a3));
    method_getArgumentType(method,4,a4,sizeof(a4));

    const char *r=ret,*p2=a2,*p3=a3,*p4=a4;
    while (*r && strchr("rnNoORV",*r)) r++;
    while (*p2 && strchr("rnNoORV",*p2)) p2++;
    while (*p3 && strchr("rnNoORV",*p3)) p3++;
    while (*p4 && strchr("rnNoORV",*p4)) p4++;

    BOOL integer=
        *p3=='q' || *p3=='Q' || *p3=='l' || *p3=='L' ||
        *p3=='i' || *p3=='I';
    return (*r=='@' || *r=='#') &&
           (*p2=='@' || *p2=='#') &&
           integer &&
           (*p4=='@' || *p4=='#');
}

static void XLGInstallNavigationProbeTargetViewHook(
    NSString *className) {
    Class cls=NSClassFromString(className);
    if (!cls) return;

    SEL selector=@selector(viewDidAppear:);
    Method method=class_getInstanceMethod(cls,selector);
    if (!method) return;

    IMP current=class_getMethodImplementation(cls,selector);
    if (!current || current==(IMP)XLGNavProbeTargetViewDidAppear) return;

    if (!gXLGNavProbeViewAppearOriginals) {
        gXLGNavProbeViewAppearOriginals=[NSMutableDictionary dictionary];
    }
    gXLGNavProbeViewAppearOriginals[className]=
        [NSValue valueWithPointer:current];

    class_replaceMethod(
        cls,
        selector,
        (IMP)XLGNavProbeTargetViewDidAppear,
        method_getTypeEncoding(method));
}

static NSString *XLGNavProbeControlLabel(id sender) {
    if (!sender) return @"-";

    NSMutableArray<NSString *> *parts=[NSMutableArray array];
    if ([sender isKindOfClass:UIButton.class]) {
        NSString *title=((UIButton *)sender).titleLabel.text;
        if (title.length) [parts addObject:title];
    }

    if ([sender respondsToSelector:@selector(accessibilityLabel)]) {
        NSString *label=[sender accessibilityLabel];
        if (label.length) [parts addObject:label];
    }
    if ([sender respondsToSelector:@selector(accessibilityIdentifier)]) {
        NSString *identifier=[sender accessibilityIdentifier];
        if (identifier.length) [parts addObject:identifier];
    }

    return parts.count
        ? [parts componentsJoinedByString:@" | "]
        : @"-";
}

static BOOL XLGNavProbeTopIsGuideContainer(void) {
    UIViewController *presenter=XLGSidebarContentPresentingViewController();
    UINavigationController *navigation=
        XLGNavigationControllerForPresenter(presenter);
    NSString *name=navigation.topViewController
        ? NSStringFromClass(navigation.topViewController.class)
        : @"";
    return [name containsString:@"GuideContainerViewController"];
}

static BOOL XLGNavProbeSendAction(
    id self,
    SEL cmd,
    SEL action,
    id target,
    id sender,
    UIEvent *event) {

    if (gXLGNavigationProbeActive) {
        NSString *actionName=action ? NSStringFromSelector(action) : @"-";
        NSString *targetName=target
            ? NSStringFromClass([target class]) : @"nil";
        NSString *senderName=sender
            ? NSStringFromClass([sender class]) : @"nil";
        NSString *label=XLGNavProbeControlLabel(sender);
        NSString *combined=
            [NSString stringWithFormat:@"%@ %@ %@ %@",
             actionName,targetName,senderName,label].lowercaseString;

        BOOL interesting=
            XLGNavProbeTopIsGuideContainer() ||
            [combined containsString:@"guide"] ||
            [combined containsString:@"trend"] ||
            [combined containsString:@"news"] ||
            [combined containsString:@"explore"] ||
            [combined containsString:@"search"];

        if (interesting) {
            XLGNavigationProbeLog(
                @"UI_ACTION action=%@ target=%@ ptr=%p sender=%@ ptr=%p label=%@ event=%@",
                actionName,
                targetName,
                target,
                senderName,
                sender,
                label,
                event ? NSStringFromClass(event.class) : @"nil");

            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(0.20*NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    XLGNavigationProbeRuntimeSnapshot(
                        @"after-guide-ui-action");
                });
        }
    }

    if (gOrigNavProbeSendAction) {
        return ((BOOL(*)(id,SEL,SEL,id,id,id))
                gOrigNavProbeSendAction)(
                    self,cmd,action,target,sender,event);
    }
    return NO;
}

static NSString *XLGContainerProbeKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%@::%@",
            NSStringFromClass(cls) ?: @"?",
            NSStringFromSelector(sel) ?: @"?"];
}

static IMP XLGContainerProbeOriginalIMP(id self, SEL sel) {
    if (!self || !sel) return NULL;
    Class cls=[self class];
    while (cls) {
        NSValue *value=
            gXLGContainerProbeOriginals[
                XLGContainerProbeKey(cls,sel)];
        if (value) return [value pointerValue];
        cls=class_getSuperclass(cls);
    }
    return NULL;
}

static NSString *XLGContainerProbeControllerSummary(id object) {
    if (!object) return @"nil";
    if (![object isKindOfClass:UIViewController.class]) {
        return [NSString stringWithFormat:@"%@ ptr=%p",
                NSStringFromClass([object class]),object];
    }

    UIViewController *vc=(UIViewController *)object;
    NSMutableArray<NSString *> *children=[NSMutableArray array];
    for (UIViewController *child in vc.childViewControllers ?: @[]) {
        [children addObject:NSStringFromClass(child.class) ?: @"?"];
    }

    NSString *stack=@"-";
    if ([vc isKindOfClass:UINavigationController.class]) {
        stack=XLGNavigationProbeStackDescription(
            (UINavigationController *)vc);
    }

    return [NSString stringWithFormat:
        @"class=%@ ptr=%p nav=%@ parent=%@ children=[%@] stack=%@",
        NSStringFromClass(vc.class),
        vc,
        vc.navigationController
            ? NSStringFromClass(vc.navigationController.class)
            : @"nil",
        vc.parentViewController
            ? NSStringFromClass(vc.parentViewController.class)
            : @"nil",
        [children componentsJoinedByString:@","],
        stack];
}

static UINavigationController *XLGEnsureGuideBridgeNavigation(id entry) {
    if (!entry || !XLGEnabled()) return nil;

    NSString *entryName=NSStringFromClass([entry class]);
    if (![entryName containsString:@"GuideAppNavigationTabEntry"]) {
        return nil;
    }

    UINavigationController *cached=
        objc_getAssociatedObject(entry,&kXLGGuideBridgeNavigationKey);
    if (cached) return cached;

    SEL createSEL=NSSelectorFromString(@"createContentController");
    IMP createIMP=XLGContainerProbeOriginalIMP(entry,createSEL);
    if (!createIMP) {
        if (gXLGNavigationProbeActive) {
            XLGNavigationProbeLog(
                @"GUIDE_BRIDGE setup failed=no-original-createContentController owner=%@",
                entryName);
        }
        return nil;
    }

    id created=((id(*)(id,SEL))createIMP)(entry,createSEL);
    if (![created isKindOfClass:UINavigationController.class]) {
        if (gXLGNavigationProbeActive) {
            XLGNavigationProbeLog(
                @"GUIDE_BRIDGE setup failed=create-result-%@ owner=%@",
                created ? NSStringFromClass([created class]) : @"nil",
                entryName);
        }
        return nil;
    }

    UINavigationController *navigation=
        (UINavigationController *)created;
    if (![NSStringFromClass(navigation.class)
            isEqualToString:@"T1GuideNavigationController"]) {
        if (gXLGNavigationProbeActive) {
            XLGNavigationProbeLog(
                @"GUIDE_BRIDGE setup failed=unexpected-nav-%@",
                NSStringFromClass(navigation.class));
        }
        return nil;
    }

    objc_setAssociatedObject(
        navigation,
        &kXLGGuideBridgeMarkerKey,
        @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    objc_setAssociatedObject(
        entry,
        &kXLGGuideBridgeNavigationKey,
        navigation,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (gXLGNavigationProbeActive) {
        XLGNavigationProbeLog(
            @"GUIDE_BRIDGE ready owner=%@ hiddenNav=%@ ptr=%p stack=%@",
            entryName,
            NSStringFromClass(navigation.class),
            navigation,
            XLGNavigationProbeStackDescription(navigation));
    }

    return navigation;
}

static id XLGContainerProbeObjectNoArg(id self, SEL cmd) {
    IMP original=XLGContainerProbeOriginalIMP(self,cmd);
    id result=nil;
    if (original) {
        result=((id(*)(id,SEL))original)(self,cmd);
    }

    NSString *ownerName=NSStringFromClass([self class]);
    BOOL guideEntry=[ownerName containsString:@"GuideAppNavigationTabEntry"];

    // If X itself asks for the legacy content controller, remember that exact
    // native T1GuideNavigationController as our bridge instead of creating a
    // second instance.
    if (XLGEnabled() &&
        guideEntry &&
        sel_isEqual(cmd,NSSelectorFromString(@"createContentController")) &&
        [result isKindOfClass:UINavigationController.class] &&
        [NSStringFromClass([result class])
            isEqualToString:@"T1GuideNavigationController"]) {
        objc_setAssociatedObject(
            result,
            &kXLGGuideBridgeMarkerKey,
            @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(
            self,
            &kXLGGuideBridgeNavigationKey,
            result,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (gXLGNavigationProbeActive) {
            XLGNavigationProbeLog(
                @"GUIDE_BRIDGE captured-native hiddenNav=%@ ptr=%p stack=%@",
                NSStringFromClass([result class]),
                result,
                XLGNavigationProbeStackDescription(result));
        }
    }

    // XTabbedAppNavigation normally skips createContentController. Prime the
    // classic Guide router when its root is requested, but leave the returned
    // root controller completely untouched for XNavigation to own.
    if (XLGEnabled() &&
        guideEntry &&
        sel_isEqual(cmd,NSSelectorFromString(@"rootTabViewController"))) {
        XLGEnsureGuideBridgeNavigation(self);
    }

    if (gXLGNavigationProbeActive) {
        XLGNavigationProbeLog(
            @"CONTAINER %@ owner=%@ ptr=%p result={%@}",
            NSStringFromSelector(cmd),
            ownerName,
            self,
            XLGContainerProbeControllerSummary(result));
    }
    return result;
}

static void XLGContainerProbeVoidNoArg(id self, SEL cmd) {
    if (gXLGNavigationProbeActive) {
        XLGNavigationProbeLog(
            @"CONTAINER %@ BEGIN owner=%@ ptr=%p",
            NSStringFromSelector(cmd),
            NSStringFromClass([self class]),
            self);
    }

    IMP original=XLGContainerProbeOriginalIMP(self,cmd);
    if (original) {
        ((void(*)(id,SEL))original)(self,cmd);
    }

    if (gXLGNavigationProbeActive) {
        id root=nil;
        SEL rootSEL=NSSelectorFromString(@"rootTabViewController");
        if ([self respondsToSelector:rootSEL]) {
            Method method=class_getInstanceMethod([self class],rootSEL);
            if (method && method_getNumberOfArguments(method)==2) {
                char ret[32]={0};
                method_getReturnType(method,ret,sizeof(ret));
                const char *r=ret;
                while (*r && strchr("rnNoORV",*r)) r++;
                if (*r=='@' || *r=='#') {
                    root=((id(*)(id,SEL))objc_msgSend)(self,rootSEL);
                }
            }
        }

        XLGNavigationProbeLog(
            @"CONTAINER %@ END owner=%@ root={%@}",
            NSStringFromSelector(cmd),
            NSStringFromClass([self class]),
            XLGContainerProbeControllerSummary(root));
    }
}

static void XLGInstallContainerProbeForClass(NSString *className) {
    Class cls=NSClassFromString(className);
    if (!cls) {
        return;
    }

    if (!gXLGContainerProbeOriginals) {
        gXLGContainerProbeOriginals=[NSMutableDictionary dictionary];
    }

    XLGNavigationProbeLog(
        @"CONTAINER_CLASS %@ present=YES",
        className);

    for (NSString *selectorName in @[
        @"createContentController",
        @"rootTabViewController"
    ]) {
        SEL sel=NSSelectorFromString(selectorName);
        Method method=class_getInstanceMethod(cls,sel);
        if (!method) {
            XLGNavigationProbeLog(
                @"CONTAINER_METHOD %@ %@ present=NO",
                className,selectorName);
            continue;
        }

        const char *types=method_getTypeEncoding(method);
        XLGNavigationProbeLog(
            @"CONTAINER_METHOD %@ %@ types=%s args=%u",
            className,
            selectorName,
            types ?: "-",
            method_getNumberOfArguments(method));

        if (method_getNumberOfArguments(method)!=2) continue;

        char ret[32]={0};
        method_getReturnType(method,ret,sizeof(ret));
        const char *r=ret;
        while (*r && strchr("rnNoORV",*r)) r++;
        if (*r!='@' && *r!='#') continue;

        IMP current=class_getMethodImplementation(cls,sel);
        if (!current || current==(IMP)XLGContainerProbeObjectNoArg) {
            continue;
        }

        gXLGContainerProbeOriginals[
            XLGContainerProbeKey(cls,sel)]=
            [NSValue valueWithPointer:current];

        class_replaceMethod(
            cls,
            sel,
            (IMP)XLGContainerProbeObjectNoArg,
            types);
    }

    SEL setupSEL=NSSelectorFromString(@"setupForTabBarPresentation");
    Method setupMethod=class_getInstanceMethod(cls,setupSEL);
    if (setupMethod) {
        const char *types=method_getTypeEncoding(setupMethod);
        XLGNavigationProbeLog(
            @"CONTAINER_METHOD %@ setupForTabBarPresentation types=%s args=%u",
            className,
            types ?: "-",
            method_getNumberOfArguments(setupMethod));

        if (method_getNumberOfArguments(setupMethod)==2) {
            char ret[32]={0};
            method_getReturnType(setupMethod,ret,sizeof(ret));
            const char *r=ret;
            while (*r && strchr("rnNoORV",*r)) r++;
            if (*r=='v') {
                IMP current=
                    class_getMethodImplementation(cls,setupSEL);
                if (current &&
                    current!=(IMP)XLGContainerProbeVoidNoArg) {
                    gXLGContainerProbeOriginals[
                        XLGContainerProbeKey(cls,setupSEL)]=
                        [NSValue valueWithPointer:current];
                    class_replaceMethod(
                        cls,
                        setupSEL,
                        (IMP)XLGContainerProbeVoidNoArg,
                        types);
                }
            }
        }
    }
}

static __attribute__((unused)) void XLGInstallContainerProbeHooks(void) {
    if (gXLGContainerProbeHooksInstalled) return;

    for (NSString *className in @[
        @"_TtC14T1TwitterSwift26GuideAppNavigationTabEntry",
        @"_TtC14T1TwitterSwift34NotificationsAppNavigationTabEntry",
        @"_TtC14T1TwitterSwift31PremiumHubAppNavigationTabEntry"
    ]) {
        XLGInstallContainerProbeForClass(className);
    }

    gXLGContainerProbeHooksInstalled=YES;
}

static __attribute__((unused)) void XLGInstallNavigationProbeHooks(void) {
    if (gXLGNavigationProbeHooksInstalled) return;

    Class navClass=UINavigationController.class;
    if (!gOrigNavProbePushViewController) {
        XLGHookMethod(
            navClass,
            @selector(pushViewController:animated:),
            NO,
            (IMP)XLGNavProbePushViewController,
            &gOrigNavProbePushViewController);
    }

    Class vcClass=UIViewController.class;
    if (!gOrigNavProbePresentViewController) {
        XLGHookMethod(
            vcClass,
            @selector(presentViewController:animated:completion:),
            NO,
            (IMP)XLGNavProbePresentViewController,
            &gOrigNavProbePresentViewController);
    }

    Class appClass=UIApplication.class;

    SEL sendActionSEL=
        @selector(sendAction:to:from:forEvent:);
    if (!gOrigNavProbeSendAction &&
        [appClass instancesRespondToSelector:sendActionSEL]) {
        XLGHookMethod(
            appClass,
            sendActionSEL,
            NO,
            (IMP)XLGNavProbeSendAction,
            &gOrigNavProbeSendAction);
    }

    SEL openSEL=
        @selector(openURL:options:completionHandler:);
    if (!gOrigNavProbeOpenURL &&
        [appClass instancesRespondToSelector:openSEL]) {
        XLGHookMethod(
            appClass,
            openSEL,
            NO,
            (IMP)XLGNavProbeOpenURL,
            &gOrigNavProbeOpenURL);
    }

    Class eventClass=NSClassFromString(@"T1AppEventHandler");
    SEL t1OpenSEL=NSSelectorFromString(@"_t1_openURL:");
    Method t1OpenMethod=
        eventClass ? class_getInstanceMethod(eventClass,t1OpenSEL) : NULL;
    if (t1OpenMethod &&
        method_getNumberOfArguments(t1OpenMethod)==3 &&
        !gOrigNavProbeT1OpenURL) {
        char ret[16]={0};
        method_getReturnType(t1OpenMethod,ret,sizeof(ret));
        const char *r=ret;
        while (*r && strchr("rnNoORV",*r)) r++;
        if (*r=='v') {
            XLGHookMethod(
                eventClass,
                t1OpenSEL,
                NO,
                (IMP)XLGNavProbeT1OpenURL,
                &gOrigNavProbeT1OpenURL);
        }
    }

    for (NSString *className in @[
        @"T1TrendsLandingViewController",
        @"T1SearchViewController",
        @"T1SearchResultsViewController",
        @"T1ExploreViewController",
        @"T1ExploreLandingViewController",
        @"T1NewsViewController",
        @"_TtC14T1TwitterSwift26TrendingPageViewController",
        @"_TtC14T1TwitterSwift33PremiumHubContainerViewController",
        @"_TtC14T1TwitterSwift30PremiumHubNavigationController",
        @"T1PremiumSettingsViewController"
    ]) {
        XLGInstallNavigationProbeTargetViewHook(className);
    }

    Class trendFactory=
        NSClassFromString(@"T1TrendingPageViewControllerFactory");
    SEL createSEL=
        NSSelectorFromString(@"createWithAccount:trendID:mode:");
    if (trendFactory &&
        XLGNavProbeMethodMatchesTrendingFactory(
            trendFactory,createSEL) &&
        !gOrigNavProbeTrendingFactoryCreate) {
        XLGHookMethod(
            trendFactory,
            createSEL,
            YES,
            (IMP)XLGNavProbeTrendingFactoryCreate,
            &gOrigNavProbeTrendingFactoryCreate);
    }

    gXLGNavigationProbeHooksInstalled=YES;
}

#pragma mark - XLiquidGlass native notification router

static id XLGNotifObjectIvar(id object, const char *ivarName) {
    if (!object || !ivarName) return nil;
    Ivar ivar=class_getInstanceVariable([object class],ivarName);
    if (!ivar) return nil;
    @try {
        return object_getIvar(object,ivar);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id XLGNotifObjectGetter(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector=NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;

    Method method=class_getInstanceMethod([object class],selector);
    if (!method) return nil;

    char returnType[64]={0};
    method_getReturnType(method,returnType,sizeof(returnType));
    const char *type=returnType;
    while (*type=='r' || *type=='n' || *type=='N' ||
           *type=='o' || *type=='O' || *type=='R' || *type=='V') {
        type++;
    }
    if (*type!='@' && *type!='#') return nil;

    @try {
        return ((id(*)(id,SEL))objc_msgSend)(object,selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static long long XLGNotifIntegerGetter(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return 0;
    SEL selector=NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return 0;

    Method method=class_getInstanceMethod([object class],selector);
    if (!method) return 0;

    char returnType[64]={0};
    method_getReturnType(method,returnType,sizeof(returnType));
    const char *type=returnType;
    while (*type=='r' || *type=='n' || *type=='N' ||
           *type=='o' || *type=='O' || *type=='R' || *type=='V') {
        type++;
    }

    @try {
        if (*type=='@' || *type=='#') {
            id value=((id(*)(id,SEL))objc_msgSend)(object,selector);
            if ([value respondsToSelector:@selector(longLongValue)]) {
                return [value longLongValue];
            }
            return 0;
        }

        switch (*type) {
            case 'q':
            case 'Q':
            case 'l':
            case 'L':
            case 'i':
            case 'I':
            case 's':
            case 'S':
            case 'c':
            case 'C':
                return ((long long(*)(id,SEL))objc_msgSend)(object,selector);
            default:
                return 0;
        }
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

static long long XLGNotifStatusIDRecursive(id object,
                                           NSUInteger depth,
                                           NSHashTable *visited) {
    if (!object || depth>4) return 0;
    if ([visited containsObject:object]) return 0;
    [visited addObject:object];

    if ([object isKindOfClass:NSNumber.class] ||
        [object isKindOfClass:NSString.class]) {
        long long value=[object longLongValue];
        return value>0 ? value : 0;
    }

    for (NSString *selectorName in @[
        @"statusIDNumber",
        @"targetStatusIDNumber",
        @"statusIDString",
        @"statusID"
    ]) {
        long long value=XLGNotifIntegerGetter(object,selectorName);
        if (value>0) return value;
    }

    for (NSString *selectorName in @[
        @"targetStatusModel",
        @"targetStatus",
        @"status",
        @"tweet",
        @"representedStatus",
        @"representeeStatus",
        @"underlyingViewModel",
        @"canonicalStatus"
    ]) {
        id nested=XLGNotifObjectGetter(object,selectorName);
        long long value=XLGNotifStatusIDRecursive(
            nested,depth+1,visited);
        if (value>0) return value;
    }

    for (NSString *ivarName in @[
        @"targetStatusModel",
        @"targetStatus",
        @"status",
        @"tweet"
    ]) {
        id nested=XLGNotifObjectIvar(object,ivarName.UTF8String);
        long long value=XLGNotifStatusIDRecursive(
            nested,depth+1,visited);
        if (value>0) return value;
    }

    return 0;
}

static long long XLGNotifStatusIDFromCell(id cell) {
    if (!cell) return 0;

    id viewModel=XLGNotifObjectIvar(cell,"viewModel");
    if (!viewModel) {
        @try {
            viewModel=[cell valueForKey:@"viewModel"];
        } @catch (__unused NSException *exception) {
        }
    }

    NSHashTable *visited=[NSHashTable weakObjectsHashTable];
    return XLGNotifStatusIDRecursive(viewModel ?: cell,0,visited);
}

static NSString *XLGNotifFoldedText(NSString *text) {
    if (![text isKindOfClass:NSString.class] || !text.length) return @"";
    NSString *folded=[text stringByFoldingWithOptions:
                      (NSDiacriticInsensitiveSearch|NSCaseInsensitiveSearch)
                                               locale:NSLocale.currentLocale];
    return folded.lowercaseString ?: @"";
}

static NSString *XLGNotifVisibleText(UIView *root) {
    if (!root) return @"";

    NSMutableString *output=[NSMutableString string];
    NSMutableArray<UIView *> *queue=[NSMutableArray arrayWithObject:root];

    for (NSUInteger i=0;i<queue.count && i<180;i++) {
        UIView *view=queue[i];
        NSString *piece=nil;

        if ([view isKindOfClass:UILabel.class]) {
            piece=((UILabel *)view).text;
        } else if ([view isKindOfClass:UITextView.class]) {
            piece=((UITextView *)view).text;
        } else if ([view isKindOfClass:UIButton.class]) {
            piece=((UIButton *)view).titleLabel.text;
        }

        if (!piece.length) piece=view.accessibilityLabel;
        if (piece.length) {
            if (output.length) [output appendString:@" | "];
            [output appendString:piece];
        }

        for (UIView *subview in view.subviews ?: @[]) {
            if (![queue containsObject:subview]) {
                [queue addObject:subview];
            }
        }
    }

    return output;
}

static BOOL XLGNotifIsGroupedNewPostCell(id cell) {
    if (![cell isKindOfClass:UIView.class]) return NO;

    NSString *text=
        XLGNotifFoldedText(XLGNotifVisibleText((UIView *)cell));

    for (NSString *needle in @[
        @"novas notificacoes do post",
        @"novas notificacoes de post",
        @"new post notifications",
        @"new posts from",
        @"new tweet notifications",
        @"new tweets from"
    ]) {
        if ([text containsString:needle]) return YES;
    }

    return NO;
}

static BOOL XLGNotifOpenConversation(long long statusID) {
    if (statusID<=0) return NO;

    id appNavigation=XLGSidebarAppNavigation();
    id account=XLGSidebarCurrentAccount();
    UIViewController *presenter=
        XLGSidebarContentPresentingViewController();

    SEL selector=NSSelectorFromString(
        @"showConversationViewControllerForViewModel:statusID:account:"
         "statusNavigationContext:scribeContext:sourceNavigationMetadata:"
         "fromViewController:animated:");

    if (appNavigation &&
        account &&
        presenter &&
        [appNavigation respondsToSelector:selector]) {
        typedef void (*ConversationFn)(
            id,SEL,id,long long,id,id,id,id,id,BOOL);
        ((ConversationFn)objc_msgSend)(
            appNavigation,
            selector,
            nil,
            statusID,
            account,
            nil,
            nil,
            nil,
            presenter,
            YES);
        return YES;
    }

    NSString *urlString=
        [NSString stringWithFormat:@"twitter://status?id=%lld",statusID];
    NSURL *url=[NSURL URLWithString:urlString];
    if (!url) return NO;

    [UIApplication.sharedApplication
        openURL:url
        options:@{}
        completionHandler:nil];
    return YES;
}

static BOOL XLGNotifOpenGroupedNewPosts(void) {
    id account=XLGSidebarCurrentAccount();
    if (!account) return NO;

    Class factory=NSClassFromString(
        @"_TtC14T1TwitterSwift30URTNotificationTimelineFactory");
    SEL selector=NSSelectorFromString(
        @"makeTweetNotificationViewControllerWithTimelineType:account:");

    if (!factory || ![factory respondsToSelector:selector]) return NO;

    // X 12.28.1:
    // 0 = device_follow
    // 1 = subscriber_device_follow
    // 2 = verified_device_follow
    id controller=((id(*)(id,SEL,long long,id))objc_msgSend)(
        factory,
        selector,
        0,
        account);

    if (![controller isKindOfClass:UIViewController.class]) return NO;

    UIViewController *presenter=
        XLGSidebarContentPresentingViewController();
    UINavigationController *navigation=
        XLGNavigationControllerForPresenter(presenter);

    if (navigation) {
        [navigation pushViewController:(UIViewController *)controller
                              animated:YES];
        return YES;
    }

    if (presenter) {
        [presenter presentViewController:(UIViewController *)controller
                                animated:YES
                              completion:nil];
        return YES;
    }

    return NO;
}

static BOOL XLGNotifTouchIsInteractive(UIView *view, UIView *cell) {
    UIView *cursor=view;
    for (NSUInteger depth=0;
         cursor && cursor!=cell && depth<16;
         depth++,cursor=cursor.superview) {
        if ([cursor isKindOfClass:UIControl.class]) return YES;

        NSString *name=NSStringFromClass(cursor.class).lowercaseString;
        if ([name containsString:@"button"] ||
            [name containsString:@"link"] ||
            [name containsString:@"avatar"] ||
            [name containsString:@"feedback"] ||
            [name containsString:@"dismiss"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL XLGOwnNotifShouldReceiveTouch(
    id self,
    SEL _cmd,
    UIGestureRecognizer *gesture,
    UITouch *touch) {
    (void)_cmd;
    (void)gesture;
    UIView *view=touch.view;
    if (!view) return YES;
    return !XLGNotifTouchIsInteractive(view,(UIView *)self);
}

static BOOL XLGNotifNavigationChanged(
    UIViewController *beforePresenter,
    UIViewController *beforeTop,
    UIViewController *beforePresented) {

    UIViewController *afterPresenter=
        XLGSidebarContentPresentingViewController();
    UINavigationController *afterNavigation=
        XLGNavigationControllerForPresenter(afterPresenter);
    UIViewController *afterTop=afterNavigation.topViewController;
    UIViewController *afterPresented=
        afterPresenter.presentedViewController;

    if (beforeTop && afterTop && beforeTop!=afterTop) return YES;
    if (afterPresented && afterPresented!=beforePresented) return YES;
    if (beforePresenter && afterPresenter &&
        beforePresenter!=afterPresenter) return YES;

    return NO;
}

static void XLGOwnNotifHandleTap(
    id self,
    SEL _cmd,
    UITapGestureRecognizer *recognizer) {
    (void)_cmd;

    if (!XLGEnabled()) return;
    if (recognizer.state!=UIGestureRecognizerStateEnded) return;

    long long statusID=XLGNotifStatusIDFromCell(self);
    BOOL grouped=(statusID<=0) && XLGNotifIsGroupedNewPostCell(self);

    if (gXLGNavigationProbeActive) {
        id viewModel=XLGNotifObjectIvar(self,"viewModel");
        if (!viewModel) {
            @try {
                viewModel=[self valueForKey:@"viewModel"];
            } @catch (__unused NSException *exception) {
            }
        }

        id displayUsers=XLGNotifObjectGetter(viewModel,@"displayUsers");
        if (!displayUsers) {
            displayUsers=XLGNotifObjectIvar(viewModel,"displayUsers");
        }

        NSArray *users=
            [displayUsers isKindOfClass:NSArray.class]
                ? (NSArray *)displayUsers
                : (displayUsers ? @[displayUsers] : @[]);

        XLGNavigationProbeLog(
            @"NOTIFICATION_MODEL viewModelClass=%@ displayUsersClass=%@ count=%lu",
            viewModel ? NSStringFromClass([viewModel class]) : @"nil",
            displayUsers ? NSStringFromClass([displayUsers class]) : @"nil",
            (unsigned long)users.count);

        NSUInteger userIndex=0;
        for (id user in users) {
            if (userIndex>=8) break;
            id username=XLGNotifObjectGetter(user,@"username");
            if (!username) username=XLGNotifObjectGetter(user,@"screenName");
            if (!username) username=XLGNotifObjectGetter(user,@"userName");
            id name=XLGNotifObjectGetter(user,@"name");
            XLGNavigationProbeLog(
                @"NOTIFICATION_USER index=%lu class=%@ ptr=%p userID=%@ username=%@ name=%@",
                (unsigned long)userIndex,
                NSStringFromClass([user class]),
                user,
                XLGTryResolveUserID(user,0) ?: @"-",
                username ?: @"-",
                name ?: @"-");
            userIndex++;
        }

        NSString *visibleText=
            [self isKindOfClass:UIView.class]
                ? XLGNotifVisibleText((UIView *)self)
                : @"";
        XLGNavigationProbeLog(
            @"NOTIFICATION_TAP cell=%@ ptr=%p statusID=%lld groupedNewPosts=%@ text=%@",
            NSStringFromClass([self class]),
            self,
            statusID,
            grouped ? @"YES" : @"NO",
            visibleText.length ? visibleText : @"-");

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(0.25*NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                XLGNavigationProbeRuntimeSnapshot(
                    @"after-notification-tap");
            });
    }

    if (statusID<=0 && !grouped) return;

    UIViewController *beforePresenter=
        XLGSidebarContentPresentingViewController();
    UINavigationController *beforeNavigation=
        XLGNavigationControllerForPresenter(beforePresenter);
    UIViewController *beforeTop=beforeNavigation.topViewController;
    UIViewController *beforePresented=
        beforePresenter.presentedViewController;

    // Native-first: let X handle the tap. Only repair the route if the
    // Liquid Glass navigation hierarchy did not change.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(0.18*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (XLGNotifNavigationChanged(
                    beforePresenter,
                    beforeTop,
                    beforePresented)) {
                return;
            }

            if (statusID>0) {
                XLGNotifOpenConversation(statusID);
            } else if (grouped) {
                XLGNotifOpenGroupedNewPosts();
            }
        });
}

static void XLGOwnNotifCellDidMoveToWindow(id self, SEL _cmd) {
    if (gOrigOwnNotificationCellDidMoveToWindow) {
        ((void(*)(id,SEL))gOrigOwnNotificationCellDidMoveToWindow)(
            self,_cmd);
    }

    if (!XLGEnabled()) return;
    if (![self isKindOfClass:UIView.class]) return;

    UIView *cell=(UIView *)self;
    if (!cell.window) return;

    UITapGestureRecognizer *recognizer=
        objc_getAssociatedObject(self,&kXLGOwnNotificationTapKey);
    if (recognizer) return;

    recognizer=[[UITapGestureRecognizer alloc]
        initWithTarget:self
                action:NSSelectorFromString(@"xlg_handleOwnNotificationTap:")];
    recognizer.cancelsTouchesInView=NO;
    recognizer.delegate=(id<UIGestureRecognizerDelegate>)self;

    [cell addGestureRecognizer:recognizer];

    objc_setAssociatedObject(
        self,
        &kXLGOwnNotificationTapKey,
        recognizer,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void XLGInstallOwnNotificationRouter(void) {
    if (gXLGOwnNotificationRouterHooked) return;

    Class cls=NSClassFromString(@"T1URTTimelineNotificationCell");
    if (!cls) return;

    SEL tapSEL=NSSelectorFromString(@"xlg_handleOwnNotificationTap:");
    if (![cls instancesRespondToSelector:tapSEL]) {
        class_addMethod(
            cls,
            tapSEL,
            (IMP)XLGOwnNotifHandleTap,
            "v@:@");
    }

    SEL receiveSEL=@selector(gestureRecognizer:shouldReceiveTouch:);
    if (![cls instancesRespondToSelector:receiveSEL]) {
        class_addMethod(
            cls,
            receiveSEL,
            (IMP)XLGOwnNotifShouldReceiveTouch,
            "B@:@@");
    }

    gXLGOwnNotificationRouterHooked=
        XLGHookMethod(
            cls,
            @selector(didMoveToWindow),
            NO,
            (IMP)XLGOwnNotifCellDidMoveToWindow,
            &gOrigOwnNotificationCellDidMoveToWindow);
}

static UIViewController *XLGDeepestVisibleViewController(
    UIViewController *controller) {
    UIViewController *cursor=controller;
    for (NSUInteger depth=0; cursor && depth<12; depth++) {
        UIViewController *next=nil;

        if (cursor.presentedViewController) {
            next=cursor.presentedViewController;
        } else if ([cursor isKindOfClass:UINavigationController.class]) {
            next=((UINavigationController *)cursor).topViewController;
        } else if ([cursor isKindOfClass:UITabBarController.class]) {
            next=((UITabBarController *)cursor).selectedViewController;
        }

        if (!next || next==cursor) break;
        cursor=next;
    }
    return cursor;
}

static BOOL XLGHierarchyContainsViewController(UIViewController *root,
                                               UIViewController *target) {
    if (!root || !target) return NO;
    NSMutableArray<UIViewController *> *queue=
        [NSMutableArray arrayWithObject:root];

    for (NSUInteger i=0; i<queue.count && i<256; i++) {
        UIViewController *vc=queue[i];
        if (vc==target) return YES;

        UIViewController *presented=vc.presentedViewController;
        if (presented && ![queue containsObject:presented]) {
            [queue addObject:presented];
        }

        if ([vc isKindOfClass:UINavigationController.class]) {
            for (UIViewController *child in
                 ((UINavigationController *)vc).viewControllers ?: @[]) {
                if (![queue containsObject:child]) [queue addObject:child];
            }
        }

        for (UIViewController *child in vc.childViewControllers ?: @[]) {
            if (![queue containsObject:child]) [queue addObject:child];
        }
    }
    return NO;
}

static BOOL XLGNativeDrawerRouteAlreadyHandled(
    UIViewController *target,
    UIViewController *beforePresenter,
    UIViewController *beforeTop,
    UIViewController *beforePresented,
    NSString **reasonOut) {

    UIViewController *afterPresenter=XLGSidebarContentPresentingViewController();
    UINavigationController *afterNavigation=
        XLGNavigationControllerForPresenter(afterPresenter);
    UIViewController *afterTop=afterNavigation.topViewController;
    UIViewController *afterPresented=afterPresenter.presentedViewController;
    UIViewController *afterVisible=
        XLGDeepestVisibleViewController(afterPresenter);

    if (target &&
        (target.presentingViewController ||
         target.parentViewController ||
         (target.navigationController &&
          [target.navigationController.viewControllers containsObject:target]) ||
         XLGHierarchyContainsViewController(afterPresenter,target))) {
        if (reasonOut) *reasonOut=@"target-attached";
        return YES;
    }

    if (afterTop && beforeTop && afterTop!=beforeTop) {
        if (target && [afterTop isKindOfClass:[target class]]) {
            if (reasonOut) *reasonOut=@"top-changed-target-class";
            return YES;
        }
        if (reasonOut) *reasonOut=@"top-changed";
        return YES;
    }

    if (afterPresented && afterPresented!=beforePresented) {
        if (reasonOut) *reasonOut=@"presented-changed";
        return YES;
    }

    if (afterPresenter && beforePresenter &&
        afterPresenter!=beforePresenter &&
        afterVisible &&
        target &&
        [afterVisible isKindOfClass:[target class]]) {
        if (reasonOut) *reasonOut=@"presenter-changed-target-class";
        return YES;
    }

    return NO;
}

static void XLGRouteDrawerNativeFirst(
    UIViewController *viewController,
    BOOL modal,
    dispatch_block_t dismissAction) {

    if (![viewController isKindOfClass:UIViewController.class]) return;

    UIViewController *beforePresenter=
        XLGSidebarContentPresentingViewController();
    UINavigationController *beforeNavigation=
        XLGNavigationControllerForPresenter(beforePresenter);
    UIViewController *beforeTop=beforeNavigation.topViewController;
    UIViewController *beforePresented=beforePresenter.presentedViewController;

    XLGDiagLog(@"DRAWER_ROUTE phase=begin mode=%@ target=%@ beforePresenter=%@ beforeTop=%@ beforePresented=%@",
                   modal ? @"modal" : @"content",
                   NSStringFromClass(viewController.class),
                   beforePresenter ? NSStringFromClass(beforePresenter.class) : @"-",
                   beforeTop ? NSStringFromClass(beforeTop.class) : @"-",
                   beforePresented ? NSStringFromClass(beforePresented.class) : @"-");

    dispatch_block_t verify=^{
        // Give X's own drawer routing one run-loop window after dismissal.
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(0.16 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                NSString *reason=nil;
                BOOL handled=XLGNativeDrawerRouteAlreadyHandled(
                    viewController,
                    beforePresenter,
                    beforeTop,
                    beforePresented,
                    &reason);

                if (handled) {
                    XLGDiagLog(@"DRAWER_ROUTE native-handled mode=%@ target=%@ reason=%@",
                                   modal ? @"modal" : @"content",
                                   NSStringFromClass(viewController.class),
                                   reason ?: @"hierarchy-changed");
                    return;
                }

                XLGDiagLog(@"DRAWER_ROUTE fallback-manual mode=%@ target=%@",
                               modal ? @"modal" : @"content",
                               NSStringFromClass(viewController.class));

                if (modal) {
                    XLGRouteModalViewController(viewController);
                } else {
                    XLGRouteContentViewController(viewController);
                }
            });
    };

    if (dismissAction) {
        dismissAction();
        verify();
    } else {
        verify();
    }
}

static void XLGRouteContentViewController(UIViewController *viewController) {
    if (![viewController isKindOfClass:UIViewController.class]) return;

    UIViewController *presenter=XLGSidebarContentPresentingViewController();
    if (!presenter) return;

    // This is Moe's first-choice route. X settings controllers implement this
    // and construct their own navigation context, which preserves Back and the
    // normal NeoFreeBird settings injection.
    SEL tfnPresentSEL=NSSelectorFromString(@"tfn_presentFromViewController:animated:");
    if ([viewController respondsToSelector:tfnPresentSEL]) {
        ((void(*)(id,SEL,id,BOOL))objc_msgSend)(
            viewController,
            tfnPresentSEL,
            presenter,
            YES
        );
        return;
    }

    UINavigationController *navigation=nil;
    if ([presenter isKindOfClass:UINavigationController.class]) {
        navigation=(UINavigationController *)presenter;
    } else {
        navigation=presenter.navigationController;
    }

    if (navigation) {
        [navigation pushViewController:viewController animated:YES];
    } else {
        [presenter presentViewController:viewController animated:YES completion:nil];
    }
}

static void XLGRouteModalViewController(UIViewController *viewController) {
    if (![viewController isKindOfClass:UIViewController.class]) return;

    UIViewController *presenter=XLGSidebarContentPresentingViewController();
    if (presenter) {
        [presenter presentViewController:viewController animated:YES completion:nil];
    }
}

@implementation XLiquidGlassSidebarDrawerViewController

- (instancetype)init {
    self=[super initWithNibName:nil bundle:nil];
    if (self) {
        _progress=0.0;
        self.modalPresentationStyle=UIModalPresentationOverFullScreen;
        self.modalPresentationCapturesStatusBarAppearance=NO;
    }
    return self;
}

- (CGFloat)xlg_panelWidth {
    CGFloat width=CGRectGetWidth(self.view.bounds);
    if (width<=0.0) width=CGRectGetWidth(UIScreen.mainScreen.bounds);
    return MIN(320.0,width*0.82);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.clearColor;

    self.dimmingView=[[UIView alloc] initWithFrame:self.view.bounds];
    self.dimmingView.backgroundColor=UIColor.blackColor;
    self.dimmingView.alpha=0.0;
    self.dimmingView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.dimmingView];

    UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(xlg_didTapDimmingView:)];
    [self.dimmingView addGestureRecognizer:tap];

    self.panelView=[[UIView alloc] initWithFrame:CGRectZero];
    self.panelView.backgroundColor=UIColor.systemBackgroundColor;
    self.panelView.clipsToBounds=YES;
    [self.view addSubview:self.panelView];

    self.panRecognizer=[[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(xlg_didPanPanel:)];
    [self.view addGestureRecognizer:self.panRecognizer];

    if (self.dashViewController) {
        [self addChildViewController:self.dashViewController];
        [self.panelView addSubview:self.dashViewController.view];
        [self.dashViewController didMoveToParentViewController:self];
    }

    [self xlg_applyProgress];
}

- (void)setDashViewController:(UIViewController *)dashViewController {
    if (_dashViewController==dashViewController) return;

    if (_dashViewController.parentViewController==self) {
        [_dashViewController willMoveToParentViewController:nil];
        [_dashViewController.view removeFromSuperview];
        [_dashViewController removeFromParentViewController];
    }

    _dashViewController=dashViewController;

    if (self.isViewLoaded && dashViewController) {
        [self addChildViewController:dashViewController];
        [self.panelView addSubview:dashViewController.view];
        [dashViewController didMoveToParentViewController:self];
        [self.view setNeedsLayout];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.dimmingView.frame=self.view.bounds;
    [self xlg_applyProgress];
    self.dashViewController.view.frame=self.panelView.bounds;
}

- (void)setProgress:(CGFloat)progress {
    _progress=MAX(0.0,MIN(1.0,progress));
    if (self.isViewLoaded) [self xlg_applyProgress];
}

- (void)xlg_applyProgress {
    CGFloat width=[self xlg_panelWidth];
    CGFloat height=CGRectGetHeight(self.view.bounds);
    CGFloat x=width*self.progress-width;
    self.panelView.frame=CGRectMake(x,0,width,height);
    self.dimmingView.alpha=0.40*self.progress;
    self.dashViewController.view.frame=self.panelView.bounds;
}

- (void)xlg_didTapDimmingView:(id)sender {
    (void)sender;
    if (self.dismissRequestHandler) self.dismissRequestHandler(YES);
}

- (void)xlg_didPanPanel:(UIPanGestureRecognizer *)gesture {
    CGFloat width=[self xlg_panelWidth];
    if (width<=0.0) return;

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.panStartProgress=self.progress;
            break;

        case UIGestureRecognizerStateChanged: {
            CGFloat dx=[gesture translationInView:self.view].x;
            self.progress=self.panStartProgress+(dx/width);
            break;
        }

        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            CGFloat velocity=[gesture velocityInView:self.view].x;
            BOOL dismiss;
            if (velocity < -200.0) dismiss=YES;
            else if (velocity > 200.0) dismiss=NO;
            else dismiss=self.progress<0.5;

            if (dismiss) {
                if (self.dismissRequestHandler) self.dismissRequestHandler(YES);
            } else {
                [UIView animateWithDuration:0.28
                                      delay:0
                     usingSpringWithDamping:1.0
                      initialSpringVelocity:0.0
                                    options:UIViewAnimationOptionCurveEaseOut
                                 animations:^{ self.progress=1.0; }
                                 completion:nil];
            }
            break;
        }

        default:
            break;
    }
}
@end

@implementation XLiquidGlassSidebarCoordinator

+ (instancetype)sharedCoordinator {
    static XLiquidGlassSidebarCoordinator *coordinator=nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{ coordinator=[XLiquidGlassSidebarCoordinator new]; });
    return coordinator;
}

- (UIViewController *)xlg_buildDashViewControllerForAccount:(id)account {
    if (!account) return nil;

    Class bridgeClass=NSClassFromString(@"T1URTNotificationsInteractionsTimelineBridge");
    Class contentClass=NSClassFromString(@"T1DashContentController");
    Class factoryClass=NSClassFromString(@"T1DashNavigationViewFactory");
    if (!bridgeClass || !contentClass || !factoryClass) return nil;

    id bridge=self.interactionsTimelineBridge;
    if (!bridge) {
        id alloc=((id(*)(id,SEL))objc_msgSend)(bridgeClass,@selector(alloc));
        SEL initSEL=NSSelectorFromString(@"initWithAccount:");
        if ([alloc respondsToSelector:initSEL]) {
            bridge=((id(*)(id,SEL,id))objc_msgSend)(alloc,initSEL,account);
        }
        if (!bridge) bridge=((id(*)(id,SEL))objc_msgSend)(alloc,@selector(init));
        self.interactionsTimelineBridge=bridge;
    }
    if (!bridge) return nil;

    id contentAlloc=((id(*)(id,SEL))objc_msgSend)(contentClass,@selector(alloc));
    SEL contentInit=NSSelectorFromString(@"initWithAccount:interactionsTimelineBridge:");
    id content=nil;
    if ([contentAlloc respondsToSelector:contentInit]) {
        content=((id(*)(id,SEL,id,id))objc_msgSend)(
            contentAlloc,contentInit,account,bridge);
    }
    if (!content) return nil;

    self.dashContentController=content;

    SEL presenterSEL=NSSelectorFromString(@"presenter");
    SEL delegateSEL=NSSelectorFromString(@"setDelegate:");
    if ([content respondsToSelector:presenterSEL]) {
        id presenter=((id(*)(id,SEL))objc_msgSend)(content,presenterSEL);
        if (presenter && [presenter respondsToSelector:delegateSEL]) {
            ((void(*)(id,SEL,id))objc_msgSend)(presenter,delegateSEL,self);
        }
    }

    SEL buildSEL=NSSelectorFromString(
        @"buildDashViewControllerForAccount:dashContentController:");
    if (![factoryClass respondsToSelector:buildSEL]) return nil;

    id result=((id(*)(id,SEL,id,id))objc_msgSend)(
        factoryClass,buildSEL,account,content);
    return [result isKindOfClass:UIViewController.class] ? result : nil;
}

- (XLiquidGlassSidebarDrawerViewController *)xlg_makeDrawer {
    id account=XLGSidebarCurrentAccount();
    if (!account) return nil;

    UIViewController *dash=[self xlg_buildDashViewControllerForAccount:account];
    if (!dash) return nil;

    self.account=account;

    XLiquidGlassSidebarDrawerViewController *drawer=
        [XLiquidGlassSidebarDrawerViewController new];
    drawer.dashViewController=dash;

    __weak typeof(self) weakSelf=self;
    drawer.dismissRequestHandler=^(BOOL animated) {
        [weakSelf xlg_dismissAnimated:animated completion:nil];
    };
    return drawer;
}

- (BOOL)xlg_presentAnimated:(BOOL)animated {
    if (!XLGEnabled()) return NO;
    if (self.drawer || self.presenting) return YES;

    UIViewController *presenter=XLGSidebarPresenter();
    if (!presenter) return NO;

    XLiquidGlassSidebarDrawerViewController *drawer=[self xlg_makeDrawer];
    if (!drawer) {
        NSLog(@"[XLiquidGlass] Swipe sidebar could not build native Dash");
        return NO;
    }

    self.drawer=drawer;
    self.presenting=YES;

    [presenter presentViewController:drawer animated:NO completion:^{
        self.presenting=NO;
        void (^open)(void)=^{ drawer.progress=1.0; };
        if (animated) {
            [UIView animateWithDuration:0.28
                                  delay:0
                 usingSpringWithDamping:1.0
                  initialSpringVelocity:0.0
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:open
                             completion:nil];
        } else {
            open();
        }
        NSLog(@"[XLiquidGlass] Moe-style left-edge sidebar presented");
    }];

    return YES;
}

- (void)xlg_dismissAnimated:(BOOL)animated completion:(dispatch_block_t)completion {
    XLiquidGlassSidebarDrawerViewController *drawer=self.drawer;
    if (!drawer) {
        if (completion) completion();
        return;
    }

    void (^finish)(void)=^{
        [drawer dismissViewControllerAnimated:NO completion:^{
            self.drawer=nil;
            self.dashContentController=nil;
            self.account=nil;
            if (completion) completion();
        }];
    };

    if (animated) {
        [UIView animateWithDuration:0.22
                         animations:^{ drawer.progress=0.0; }
                         completion:^(__unused BOOL finished){ finish(); }];
    } else {
        drawer.progress=0.0;
        finish();
    }
}

- (void)xlg_didRecognizeEdgePan:(UIScreenEdgePanGestureRecognizer *)gesture {
    if (gXLGNavigationProbeActive) {
        XLGNavigationProbeLog(
            @"EDGE_OURS state=%ld ptr=%p viewClass=%@ drawer=%@ presenting=%@ translationX=%.1f velocityX=%.1f",
            (long)gesture.state,
            gesture,
            gesture.view ? NSStringFromClass(gesture.view.class) : @"nil",
            self.drawer ? @"YES" : @"NO",
            self.presenting ? @"YES" : @"NO",
            [gesture translationInView:gesture.view].x,
            [gesture velocityInView:gesture.view].x);
    }

    // Existing behavior preserved for diagnosis.
    if (gesture.state==UIGestureRecognizerStateBegan) {
        [self xlg_presentAnimated:YES];

        if (gXLGNavigationProbeActive) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(0.25*NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    XLGNavigationProbeRuntimeSnapshot(@"after-our-edge-swipe");
                });
        }
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    (void)gestureRecognizer;
    return XLGEnabled() && self.drawer==nil && !self.presenting;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
 shouldRecognizeSimultaneouslyWithGestureRecognizer:
    (UIGestureRecognizer *)otherGestureRecognizer {
    if (gXLGNavigationProbeActive) {
        XLGNavigationProbeLog(
            @"EDGE_SIMULTANEOUS ours=%@ ptr=%p other=%@ ptr=%p otherView=%@ decision=YES",
            NSStringFromClass(gestureRecognizer.class),
            gestureRecognizer,
            NSStringFromClass(otherGestureRecognizer.class),
            otherGestureRecognizer,
            otherGestureRecognizer.view
                ? NSStringFromClass(otherGestureRecognizer.view.class)
                : @"nil");
    }
    return YES;
}

- (void)dashContentPresenterDismissDashAnimated:(BOOL)animated completion:(id)completion {
    [self xlg_dismissAnimated:animated completion:^{
        if (completion) ((void(^)(void))completion)();
    }];
}

- (void)dashContentPresenterDismissViewControllerAnimated:(BOOL)animated {
    [self xlg_dismissAnimated:animated completion:nil];
}

- (void)dashContentPresenterPresentContentViewController:(UIViewController *)viewController
                                        dismissDashBlock:(id)dismissDashBlock {
    if (dismissDashBlock) {
        void (^dismiss)(BOOL,dispatch_block_t)=dismissDashBlock;
        XLGRouteDrawerNativeFirst(
            viewController,
            NO,
            ^{
                // Do not pass our route as the completion anymore. Let X finish
                // its own selection/dismiss flow; Final verifies afterwards.
                dismiss(YES,nil);
            });
    } else {
        // No native dismiss callback exists, so our custom drawer still owns
        // dismissal. Verification then falls back to the existing manual route.
        XLGRouteDrawerNativeFirst(
            viewController,
            NO,
            ^{
                [self xlg_dismissAnimated:YES completion:nil];
            });
    }
}

- (void)dashContentPresenterPresentModalViewController:(UIViewController *)viewController
                                      dismissDashBlock:(id)dismissDashBlock {
    if (dismissDashBlock) {
        void (^dismiss)(BOOL,dispatch_block_t)=dismissDashBlock;
        XLGRouteDrawerNativeFirst(
            viewController,
            YES,
            ^{
                dismiss(YES,nil);
            });
    } else {
        XLGRouteDrawerNativeFirst(
            viewController,
            YES,
            ^{
                [self xlg_dismissAnimated:YES completion:nil];
            });
    }
}

- (void)dashContentPresenterSwitchAccountWithBlock:(id)block
                                  dismissDashBlock:(id)dismissDashBlock {
    dispatch_block_t switchAccount=^{
        if (block) ((void(^)(void))block)();
    };

    if (dismissDashBlock) {
        void (^dismiss)(BOOL,dispatch_block_t)=dismissDashBlock;
        dismiss(YES,switchAccount);
    } else {
        [self xlg_dismissAnimated:YES completion:switchAccount];
    }
}
@end

static void XLGInstallEdgeGesture(UIViewController *controller) {
    if (!XLGEnabled() || !controller || !controller.isViewLoaded) return;
    if (objc_getAssociatedObject(controller,&kXLGSidebarEdgePanKey)) return;

    if (gXLGNavigationProbeActive) {
        NSUInteger leftEdgeCount=0;
        for (UIGestureRecognizer *existing in
             controller.view.gestureRecognizers ?: @[]) {
            if ([existing isKindOfClass:UIScreenEdgePanGestureRecognizer.class]) {
                UIScreenEdgePanGestureRecognizer *edge=
                    (UIScreenEdgePanGestureRecognizer *)existing;
                if ((edge.edges & UIRectEdgeLeft)!=0) leftEdgeCount++;
                XLGNavigationProbeLog(
                    @"EDGE_EXISTING controller=%@ recognizer=%@ ptr=%p edges=%lu enabled=%@ state=%ld",
                    NSStringFromClass(controller.class),
                    NSStringFromClass(existing.class),
                    existing,
                    (unsigned long)edge.edges,
                    existing.enabled ? @"YES" : @"NO",
                    (long)existing.state);
            }
        }
        XLGNavigationProbeLog(
            @"EDGE_BEFORE_INSTALL controller=%@ leftEdgeCount=%lu",
            NSStringFromClass(controller.class),
            (unsigned long)leftEdgeCount);
    }

    XLiquidGlassSidebarCoordinator *coordinator=
        [XLiquidGlassSidebarCoordinator sharedCoordinator];

    UIScreenEdgePanGestureRecognizer *gesture=
        [[UIScreenEdgePanGestureRecognizer alloc]
            initWithTarget:coordinator
                    action:@selector(xlg_didRecognizeEdgePan:)];

    // UIRectEdgeLeft == 2, exactly what Moe writes with setEdges:.
    gesture.edges=UIRectEdgeLeft;
    gesture.delegate=coordinator;

    [controller.view addGestureRecognizer:gesture];
    objc_setAssociatedObject(
        controller,
        &kXLGSidebarEdgePanKey,
        gesture,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    NSLog(@"[XLiquidGlass] Moe-style left-edge swipe installed");
}

static void XLGTabLoad(id self,SEL cmd) {
    if (gOrigTabLoad) ((void(*)(id,SEL))gOrigTabLoad)(self,cmd);
    if ([self isKindOfClass:UIViewController.class]) XLGInstallEdgeGesture(self);
}

static void XLGTabAppear(id self,SEL cmd,BOOL animated) {
    if (gOrigTabAppear) ((void(*)(id,SEL,BOOL))gOrigTabAppear)(self,cmd,animated);
    if ([self isKindOfClass:UIViewController.class]) XLGInstallEdgeGesture(self);
}

static __attribute__((unused)) void XLGInstallSidebarFix(void) {
    Class tabClass=NSClassFromString(@"_TtC11XNavigation16TabBarController");
    if (!tabClass) return;

    XLGHookMethod(tabClass,
                  @selector(viewDidLoad),
                  NO,
                  (IMP)XLGTabLoad,
                  &gOrigTabLoad);

    XLGHookMethod(tabClass,
                  @selector(viewDidAppear:),
                  NO,
                  (IMP)XLGTabAppear,
                  &gOrigTabAppear);
}


#pragma mark - XLiquidGlass 1.6 global Tab Bar / badge bridge

static NSString *const kXLGBadgePrefix = @"XLiquidGlass.Badges.";
static NSString *const kXLGBadgeAccountsKey = @"XLiquidGlass.Badges.accounts";
static NSInteger gXLGLastRootBadgeCount = -1;
static NSString *gXLGBadgeActiveUserID = nil;
static NSDictionary *gXLGLastBadgeCountsByUserID = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *gXLGBadgeStateByUserID = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *gXLGBadgeSourceStateByUserID = nil;
static const NSTimeInterval kXLGBadgeReconcileWindow = 0.75;
static const NSTimeInterval kXLGNotificationsViewedGraceWindow = 5.0;
static const NSTimeInterval kXLGNativeBadgeSignalGraceWindow = 1.25;
static const NSTimeInterval kXLGDirectRemoteAuthorityWindow = 1.0;
static BOOL gXLGBadgePersistenceLoaded = NO;
static IMP gOrigXNavItemLayout = NULL;
static IMP gOrigActiveAccountDidChange = NULL;
static IMP gOrigAppBadgingSetCurrentUserID = NULL;
static IMP gOrigAppBadgingSetUserIDsCurrentUserID = NULL;
static IMP gOrigAppBadgingSetLocalUnseenDMCountUserIDDate = NULL;
static IMP gOrigAppBadgingSetLocalUnseenXChatCountUserIDDate = NULL;
static IMP gOrigTFNApplyRemoteBadgeCounts = NULL;
static IMP gOrigT1TabViewSetBadgeCountAnimated = NULL;
static IMP gOrigT1TabViewSetBadgeCount = NULL;
static id gXLGBadgeNotificationObserver = nil;
static id gXLGDefaultsObserver = nil;
static char kXLGBadgeLabelKey;
static char kXLGBadgeSignatureKey;

static id XLGSafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}



#pragma mark - XLiquidGlass 1.9.3 Beta 6 correction + probe

static NSMutableDictionary<NSString *,NSValue *> *gXLGB6VisibleSetterOriginals=nil;
static NSMutableDictionary<NSString *,NSValue *> *gXLGB6DataSourceSetterOriginals=nil;
static BOOL gXLGB6VisibleHooksInstalled=NO;
static BOOL gXLGB6DataSourceHooksInstalled=NO;
static BOOL gXLGB6ProbeScheduled=NO;
static char kXLGB6LastAppliedSignatureKey;

// Beta 6.1: the live Liquid Glass path in X 12.28.1 does not call
// setVisibleTabEntries:/setTabContent:. It asks the legacy navigation owner
// for visible panel IDs and rebuilds content/controllers from those IDs.
static IMP gOrigXLGB61VisiblePanelIDsForAppNavigation=NULL;
static IMP gOrigXLGB61UpdateTabContentWithPanelIDs=NULL;
static IMP gOrigXLGB61UpdateTabVCsWithPanelIDs=NULL;
static IMP gOrigXLGB61RecalculateWithPanelIDs=NULL;
static IMP gOrigXLGB61InitializeTabContent=NULL;
static BOOL gXLGB61PanelPipelineHooksInstalled=NO;

// Beta 6.2: active post-initialization reconcile on the real Swift navigation VC.
static char kXLGB62ActiveReconcileAttemptsKey;
static BOOL gXLGB62ActiveReconcileScheduled=NO;

// Beta 6.4: target the real Swift appNavigation object instead of its VC.
static IMP gOrigXLGB64SwiftVisiblePanelIDs=NULL;
static IMP gOrigXLGB64SwiftRecalcWithPanelIDs=NULL;
static BOOL gXLGB64SwiftAppNavHooksInstalled=NO;
static char kXLGB64SwiftReconcileAttemptsKey;


// Beta 6.7: reconnect NFB's list only when X performs its own native
// recalculate calls. These counters survive "Limpar relatório".
static NSUInteger gXLGB67NativeRecalcWithIDsCount=0;
static NSUInteger gXLGB67NativeRecalcCount=0;
static NSString *gXLGB67LastInputDescription=nil;
static NSString *gXLGB67LastForwardedDescription=nil;
static NSString *gXLGB67LastAfterDescription=nil;

static NSString *XLGB6LogPath(void) {
    NSString *documents=NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    return documents.length
        ? [documents stringByAppendingPathComponent:
            @"XLiquidGlass193Beta69SwiftSymbolSourceProbe.log"]
        : nil;
}

static NSString *XLGB6Timestamp(void) {
    NSDateFormatter *formatter=[[NSDateFormatter alloc] init];
    formatter.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat=@"yyyy-MM-dd HH:mm:ss.SSS";
    return [formatter stringFromDate:NSDate.date] ?: @"-";
}

static void XLGB6Log(NSString *format, ...) {
    if (!format.length) return;
    va_list args;
    va_start(args,format);
    NSString *message=[[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line=[NSString stringWithFormat:@"[%@] %@\n",
                    XLGB6Timestamp(),message ?: @"-"];
    NSString *path=XLGB6LogPath();
    if (!path.length) return;

    @synchronized(NSFileManager.defaultManager) {
        NSData *data=[line dataUsingEncoding:NSUTF8StringEncoding];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [NSFileManager.defaultManager createFileAtPath:path
                                                  contents:nil
                                                attributes:nil];
        }
        @try {
            NSFileHandle *handle=[NSFileHandle fileHandleForWritingAtPath:path];
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        } @catch (__unused NSException *exception) {
        }
    }
}

static id XLGB6ObjectBySelector(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector=NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;

    Method method=class_getInstanceMethod([object class],selector);
    if (!method || method_getNumberOfArguments(method)!=2) return nil;

    char returnType[32]={0};
    method_getReturnType(method,returnType,sizeof(returnType));
    const char *p=returnType;
    while (*p && strchr("rnNoORV",*p)) p++;
    if (*p!='@' && *p!='#') return nil;

    @try {
        return ((id(*)(id,SEL))objc_msgSend)(object,selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id XLGB6ClassObjectBySelector(Class cls, NSString *selectorName) {
    if (!cls || !selectorName.length) return nil;
    SEL selector=NSSelectorFromString(selectorName);
    if (![cls respondsToSelector:selector]) return nil;

    Method method=class_getClassMethod(cls,selector);
    if (!method || method_getNumberOfArguments(method)!=2) return nil;

    char returnType[32]={0};
    method_getReturnType(method,returnType,sizeof(returnType));
    const char *p=returnType;
    while (*p && strchr("rnNoORV",*p)) p++;
    if (*p!='@' && *p!='#') return nil;

    @try {
        return ((id(*)(id,SEL))objc_msgSend)(cls,selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSArray<NSString *> *XLGB6NormalizePageArray(id raw) {
    if (![raw isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<NSString *> *pages=[NSMutableArray array];

    for (id item in (NSArray *)raw) {
        NSString *page=nil;
        if ([item isKindOfClass:NSString.class]) {
            page=[(NSString *)item lowercaseString];
        } else {
            id candidate=XLGSafeValueForKey(item,@"pageID");
            if (![candidate isKindOfClass:NSString.class]) {
                candidate=XLGSafeValueForKey(item,@"identifier");
            }
            if ([candidate isKindOfClass:NSString.class]) {
                page=[(NSString *)candidate lowercaseString];
            }
        }
        if (!page.length || [pages containsObject:page]) continue;
        [pages addObject:page];
    }

    return pages.count ? [pages copy] : nil;
}

static NSArray<NSString *> *XLGB6DesiredPages(void) {
    id raw=[[NSUserDefaults standardUserDefaults]
        objectForKey:@"bh_tabs_visible"];
    NSArray<NSString *> *pages=XLGB6NormalizePageArray(raw);
    if (pages.count) return pages;

    Class utility=NSClassFromString(@"CustomTabBarUtility");
    pages=XLGB6NormalizePageArray(
        XLGB6ClassObjectBySelector(utility,@"visiblePageIDsInOrder"));
    return pages;
}

static NSString *XLGB6PageForEntry(id entry) {
    if (!entry) return nil;

    NSString *className=
        NSStringFromClass([entry class]).lowercaseString ?: @"";

    if ([className containsString:@"hometimelineappnavigationtabentry"] ||
        [className containsString:@"homeappnavigationtabentry"]) return @"home";
    if ([className containsString:@"newsappnavigationtabentry"]) return @"news";
    if ([className containsString:@"grokappnavigationtabentry"]) return @"grok";
    if ([className containsString:@"guideappnavigationtabentry"] ||
        [className containsString:@"exploreappnavigationtabentry"]) return @"guide";
    if ([className containsString:@"notificationsappnavigationtabentry"]) return @"ntab";
    if ([className containsString:@"xchatappnavigationtabentry"] ||
        [className containsString:@"messagesappnavigationtabentry"] ||
        [className containsString:@"dmappnavigationtabentry"]) return @"messages";
    if ([className containsString:@"communitiesappnavigationtabentry"]) return @"communities";
    if ([className containsString:@"profileappnavigationtabentry"]) return @"profile";
    if ([className containsString:@"listsappnavigationtabentry"]) return @"lists";
    if ([className containsString:@"bookmarksappnavigationtabentry"]) return @"bookmarks";
    if ([className containsString:@"premiumhubappnavigationtabentry"]) return @"premium";
    if ([className containsString:@"jobsappnavigationtabentry"]) return @"jobs";
    if ([className containsString:@"paymentsappnavigationtabentry"]) return @"payments";
    if ([className containsString:@"birdwatchappnavigationtabentry"]) return @"birdwatch";
    if ([className containsString:@"connectappnavigationtabentry"]) return @"connect";

    for (NSString *key in @[
        @"identifier",@"tabIdentifier",@"itemIdentifier",
        @"pageID",@"pageId",@"displayName",@"tabDisplayName",
        @"title",@"name",@"key"
    ]) {
        id value=XLGSafeValueForKey(entry,key);
        if (![value isKindOfClass:NSString.class]) continue;
        NSString *text=[(NSString *)value lowercaseString];

        if ([text isEqualToString:@"home"] ||
            [text containsString:@"início"] ||
            [text containsString:@"inicio"]) return @"home";
        if ([text isEqualToString:@"news"] ||
            [text containsString:@"notícias"] ||
            [text containsString:@"noticias"]) return @"news";
        if ([text containsString:@"grok"]) return @"grok";
        if ([text isEqualToString:@"guide"] ||
            [text containsString:@"explorar"] ||
            [text containsString:@"explore"] ||
            [text containsString:@"search"]) return @"guide";
        if ([text isEqualToString:@"ntab"] ||
            [text containsString:@"notifica"] ||
            [text containsString:@"notification"]) return @"ntab";
        if ([text isEqualToString:@"messages"] ||
            [text containsString:@"mensag"] ||
            [text containsString:@"message"] ||
            [text containsString:@"chat"] ||
            [text containsString:@"dm"]) return @"messages";
        if ([text containsString:@"comunidade"] ||
            [text containsString:@"communit"]) return @"communities";
        if ([text containsString:@"perfil"] ||
            [text containsString:@"profile"]) return @"profile";
    }

    return nil;
}

static NSString *XLGB6DescribeArray(NSArray *array) {
    if (![array isKindOfClass:NSArray.class]) return @"not-array";
    NSMutableArray<NSString *> *parts=[NSMutableArray array];

    [array enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        (void)stop;
        NSString *page=XLGB6PageForEntry(obj);
        NSString *className=NSStringFromClass([obj class]) ?: @"?";
        [parts addObject:[NSString stringWithFormat:
            @"%lu:%@<%@>",
            (unsigned long)idx,
            page.length ? page : @"?",
            className]];
    }];
    return [parts componentsJoinedByString:@","];
}

static void XLGB6AddPoolValue(id value, NSMutableArray *pool) {
    if (!value || !pool) return;

    if ([value isKindOfClass:NSArray.class]) {
        for (id obj in (NSArray *)value) {
            if (obj && ![pool containsObject:obj]) [pool addObject:obj];
        }
        return;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        for (id obj in [(NSDictionary *)value allValues]) {
            if (obj && ![pool containsObject:obj]) [pool addObject:obj];
        }
        return;
    }
    if ([value isKindOfClass:NSSet.class]) {
        for (id obj in (NSSet *)value) {
            if (obj && ![pool containsObject:obj]) [pool addObject:obj];
        }
    }
}

static void XLGB6CollectFromObject(id object,
                                   NSMutableArray *pool,
                                   NSString *source) {
    if (!object || !pool) return;

    for (NSString *key in @[
        @"visibleTabEntries",
        @"tabContent",
        @"tabContentByIdentifier",
        @"allTabEntries",
        @"availableTabEntries",
        @"tabEntries",
        @"entries",
        @"tabs",
        @"items"
    ]) {
        id value=XLGB6ObjectBySelector(object,key);
        if (!value) value=XLGSafeValueForKey(object,key);
        NSUInteger before=pool.count;
        XLGB6AddPoolValue(value,pool);
        if (pool.count!=before) {
            XLGB6Log(@"POOL source=%@ owner=%@ key=%@ added=%lu total=%lu valueClass=%@",
                     source ?: @"-",
                     NSStringFromClass([object class]) ?: @"?",
                     key,
                     (unsigned long)(pool.count-before),
                     (unsigned long)pool.count,
                     value ? NSStringFromClass([value class]) : @"nil");
        }
    }
}

static NSArray *XLGB6CorrectedEntries(id owner,
                                      NSArray *current,
                                      NSString *stage,
                                      NSString **missingOut) {
    if (!XLGEnabled() || ![current isKindOfClass:NSArray.class]) {
        return current;
    }

    NSArray<NSString *> *desired=XLGB6DesiredPages();
    if (!desired.count) {
        XLGB6Log(@"CORRECTION stage=%@ skipped=no-bh-pages current=%@",
                 stage ?: @"-",XLGB6DescribeArray(current));
        return current;
    }

    NSMutableArray *pool=[NSMutableArray array];
    XLGB6AddPoolValue(current,pool);
    XLGB6CollectFromObject(owner,pool,@"owner");

    id dataSource=XLGB6ObjectBySelector(owner,@"dataSource");
    if (!dataSource) dataSource=XLGSafeValueForKey(owner,@"dataSource");
    if (!dataSource) dataSource=XLGSafeValueForKey(owner,@"_dataSource");
    if (dataSource && dataSource!=owner) {
        XLGB6CollectFromObject(dataSource,pool,@"dataSource");
    }

    id appNavigation=XLGB6ObjectBySelector(owner,@"appNavigation");
    if (!appNavigation) appNavigation=XLGSafeValueForKey(owner,@"appNavigation");
    if (appNavigation && appNavigation!=owner && appNavigation!=dataSource) {
        XLGB6CollectFromObject(appNavigation,pool,@"appNavigation");
    }

    Class utility=NSClassFromString(@"CustomTabBarUtility");
    id registry=XLGB6ClassObjectBySelector(utility,@"registry");
    XLGB6AddPoolValue(registry,pool);

    NSMutableDictionary<NSString *,id> *byPage=[NSMutableDictionary dictionary];
    for (id entry in pool) {
        NSString *page=XLGB6PageForEntry(entry);
        if (page.length && !byPage[page]) byPage[page]=entry;
    }

    NSMutableArray *ordered=[NSMutableArray arrayWithCapacity:desired.count];
    NSMutableArray<NSString *> *missing=[NSMutableArray array];

    for (NSString *page in desired) {
        id entry=byPage[page];
        if (entry) [ordered addObject:entry];
        else [missing addObject:page];
    }

    if (missing.count) {
        NSString *missingString=[missing componentsJoinedByString:@","];
        if (missingOut) *missingOut=missingString;
        XLGB6Log(@"CORRECTION stage=%@ result=INCOMPLETE desired=%@ current=%@ pool=%@ missing=%@",
                 stage ?: @"-",
                 [desired componentsJoinedByString:@","],
                 XLGB6DescribeArray(current),
                 XLGB6DescribeArray(pool),
                 missingString);
        return current;
    }

    NSString *signature=[desired componentsJoinedByString:@","];
    XLGB6Log(@"CORRECTION stage=%@ result=READY desired=%@ current=%@ corrected=%@",
             stage ?: @"-",
             signature,
             XLGB6DescribeArray(current),
             XLGB6DescribeArray(ordered));

    if (ordered.count==current.count &&
        [ordered isEqualToArray:current]) {
        return current;
    }

    if (owner && signature.length) {
        objc_setAssociatedObject(
            owner,&kXLGB6LastAppliedSignatureKey,
            signature,OBJC_ASSOCIATION_COPY_NONATOMIC);
    }

    return [ordered copy];
}

static IMP XLGB6OriginalForObject(
    id object,
    NSMutableDictionary<NSString *,NSValue *> *table) {
    if (!object || !table.count) return NULL;
    for (Class cls=[object class]; cls; cls=class_getSuperclass(cls)) {
        NSValue *value=table[NSStringFromClass(cls) ?: @""];
        if (value) return (IMP)[value pointerValue];
    }
    return NULL;
}

static void XLGB6ProbeRuntimeMethods(Class cls, NSString *label) {
    if (!cls) return;

    XLGB6Log(@"RUNTIME class=%@ label=%@ ptr=%p",
             NSStringFromClass(cls) ?: @"?",
             label ?: @"-",cls);

    unsigned int count=0;
    Method *methods=class_copyMethodList(cls,&count);
    for (unsigned int i=0;i<count;i++) {
        Method method=methods[i];
        NSString *name=NSStringFromSelector(method_getName(method));
        NSString *lower=name.lowercaseString ?: @"";
        if (![lower containsString:@"tab"] &&
            ![lower containsString:@"entry"] &&
            ![lower containsString:@"content"] &&
            ![lower containsString:@"visible"] &&
            ![lower containsString:@"descriptor"] &&
            ![lower containsString:@"navigation"]) {
            continue;
        }
        XLGB6Log(@"METHOD class=%@ selector=%@ types=%s",
                 NSStringFromClass(cls) ?: @"?",
                 name,
                 method_getTypeEncoding(method) ?: "-");
    }
    if (methods) free(methods);
}

static void XLGB6ProbeView(UIView *view, NSUInteger depth) {
    if (!view || depth>60) return;
    NSString *name=NSStringFromClass(view.class) ?: @"";
    NSString *lower=name.lowercaseString ?: @"";

    if ([lower containsString:@"tabbarview"] ||
        [lower containsString:@"tabviewgroup"]) {
        id tabs=XLGSafeValueForKey(view,@"tabs");
        id itemViews=XLGSafeValueForKey(view,@"itemViews");
        id tabViews=XLGSafeValueForKey(view,@"tabViews");

        XLGB6Log(@"VIEW class=%@ ptr=%p tabs=%lu itemViews=%lu tabViews=%lu frame=%@",
                 name,view,
                 [tabs isKindOfClass:NSArray.class]
                    ? (unsigned long)[(NSArray *)tabs count] : 0,
                 [itemViews isKindOfClass:NSArray.class]
                    ? (unsigned long)[(NSArray *)itemViews count] : 0,
                 [tabViews isKindOfClass:NSArray.class]
                    ? (unsigned long)[(NSArray *)tabViews count] : 0,
                 NSStringFromCGRect(view.frame));

        if ([tabs isKindOfClass:NSArray.class]) {
            XLGB6Log(@"VIEW_TABS class=%@ entries=%@",
                     name,XLGB6DescribeArray((NSArray *)tabs));
        }
    }

    for (UIView *subview in view.subviews ?: @[]) {
        XLGB6ProbeView(subview,depth+1);
    }
}


static BOOL XLGB63InterestingName(NSString *name) {
    NSString *lower=name.lowercaseString ?: @"";
    return [lower containsString:@"tab"] ||
           [lower containsString:@"descriptor"] ||
           [lower containsString:@"item"] ||
           [lower containsString:@"navigation"] ||
           [lower containsString:@"dock"] ||
           [lower containsString:@"visible"] ||
           [lower containsString:@"selected"];
}

static void XLGB63DumpClassMetadata(Class cls, NSString *origin) {
    for (Class cursor=cls; cursor; cursor=nil) {
        NSString *className=NSStringFromClass(cursor) ?: @"?";
        XLGB6Log(@"SWIFT_CLASS origin=%@ class=%@ superclass=%@ ptr=%p",
                 origin ?: @"-",
                 className,
                 class_getSuperclass(cursor)
                    ? NSStringFromClass(class_getSuperclass(cursor)) : @"nil",
                 cursor);

        unsigned int propertyCount=0;
        objc_property_t *properties=class_copyPropertyList(cursor,&propertyCount);
        for (unsigned int i=0;i<propertyCount;i++) {
            const char *rawName=property_getName(properties[i]);
            NSString *name=rawName ? [NSString stringWithUTF8String:rawName] : @"";
            if (!XLGB63InterestingName(name)) continue;
            XLGB6Log(@"SWIFT_PROPERTY class=%@ name=%@ attrs=%s",
                     className,
                     name,
                     property_getAttributes(properties[i]) ?: "-");
        }
        if (properties) free(properties);

        unsigned int ivarCount=0;
        Ivar *ivars=class_copyIvarList(cursor,&ivarCount);
        for (unsigned int i=0;i<ivarCount;i++) {
            const char *rawName=ivar_getName(ivars[i]);
            NSString *name=rawName ? [NSString stringWithUTF8String:rawName] : @"";
            if (!XLGB63InterestingName(name)) continue;
            XLGB6Log(@"SWIFT_IVAR class=%@ name=%@ type=%s offset=%td",
                     className,
                     name,
                     ivar_getTypeEncoding(ivars[i]) ?: "-",
                     ivar_getOffset(ivars[i]));
        }
        if (ivars) free(ivars);

        unsigned int methodCount=0;
        Method *methods=class_copyMethodList(cursor,&methodCount);
        for (unsigned int i=0;i<methodCount;i++) {
            NSString *name=NSStringFromSelector(method_getName(methods[i]));
            if (!XLGB63InterestingName(name)) continue;
            XLGB6Log(@"SWIFT_METHOD class=%@ selector=%@ types=%s",
                     className,
                     name,
                     method_getTypeEncoding(methods[i]) ?: "-");
        }
        if (methods) free(methods);

        if (cursor==NSObject.class) break;
    }
}

static void XLGB63DumpGetterValue(id object,
                                  NSString *key,
                                  NSString *origin) {
    if (!object || !key.length) return;

    id value=XLGB6ObjectBySelector(object,key);
    if (!value) value=XLGSafeValueForKey(object,key);
    if (!value) return;

    NSString *description=nil;
    @try {
        description=[value description] ?: @"-";
    } @catch (__unused NSException *exception) {
        description=@"<description-error>";
    }

    if (description.length>1200) {
        description=[[description substringToIndex:1200]
            stringByAppendingString:@"…"];
    }

    XLGB6Log(@"SWIFT_VALUE origin=%@ owner=%@ key=%@ valueClass=%@ value=%@",
             origin ?: @"-",
             NSStringFromClass([object class]) ?: @"?",
             key,
             NSStringFromClass([value class]) ?: @"?",
             description);
}

static void XLGB63DumpSwiftAppNavigation(NSString *reason) {
    id appNavigation=XLGSidebarAppNavigation();

    XLGB6Log(@"========== SWIFT_APPNAV_PROBE %@ ==========",reason ?: @"-");
    XLGB6Log(@"SWIFT_APPNAV object=%@ ptr=%p",
             appNavigation ? NSStringFromClass([appNavigation class]) : @"nil",
             appNavigation);

    if (!appNavigation) {
        XLGB6Log(@"========== SWIFT_APPNAV_PROBE_END %@ ==========",reason ?: @"-");
        return;
    }

    XLGB63DumpClassMetadata([appNavigation class],@"appNavigation");

    for (NSString *key in @[
        @"tabs",
        @"tabItems",
        @"items",
        @"navigationItems",
        @"appTabs",
        @"entries",
        @"descriptors",
        @"tabDescriptors",
        @"availableTabs",
        @"visiblePanelIDs",
        @"visibleTabs",
        @"visibleTabEntries",
        @"tabBar",
        @"tabBarView",
        @"tabBarController",
        @"selectedTab",
        @"selectedIndex",
        @"currentTab",
        @"customizedTabs"
    ]) {
        XLGB63DumpGetterValue(appNavigation,key,@"appNavigation");
    }

    NSMutableArray<UIViewController *> *queue=[NSMutableArray array];
    NSMutableSet<NSValue *> *visited=[NSMutableSet set];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) {
            if (window.rootViewController) [queue addObject:window.rootViewController];
        }
    }

    for (NSUInteger i=0;i<queue.count && i<260;i++) {
        UIViewController *vc=queue[i];
        NSValue *pointer=[NSValue valueWithPointer:(__bridge const void *)vc];
        if ([visited containsObject:pointer]) continue;
        [visited addObject:pointer];

        NSString *name=NSStringFromClass(vc.class) ?: @"";
        if ([name containsString:@"XTabbedAppNavigationViewController"]) {
            BOOL respondsLegacy=
                [vc respondsToSelector:
                    NSSelectorFromString(@"recalculateVisiblePanelsWithUpdatedPanelIDs:")];

            id vcAppNavigation=XLGB6ObjectBySelector(vc,@"appNavigation");
            XLGB6Log(@"SWIFT_VC class=%@ ptr=%p superclass=%@ respondsLegacyRecalc=%@ appNavigationClass=%@ appNavigationPtr=%p sameAsSidebar=%@",
                     name,
                     vc,
                     class_getSuperclass(vc.class)
                        ? NSStringFromClass(class_getSuperclass(vc.class)) : @"nil",
                     respondsLegacy ? @"YES" : @"NO",
                     vcAppNavigation
                        ? NSStringFromClass([vcAppNavigation class]) : @"nil",
                     vcAppNavigation,
                     (vcAppNavigation && vcAppNavigation==appNavigation)
                        ? @"YES" : @"NO");

            for (NSString *key in @[
                @"tabBarContainer",
                @"tabBarController",
                @"tabbedAppNavigation",
                @"appNavigation",
                @"tabs",
                @"descriptors",
                @"tabDescriptors",
                @"items"
            ]) {
                XLGB63DumpGetterValue(vc,key,@"swift-view-controller");
            }
        }

        for (UIViewController *child in vc.childViewControllers ?: @[]) {
            if (child) [queue addObject:child];
        }
        if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
    }

    XLGB6Log(@"========== SWIFT_APPNAV_PROBE_END %@ ==========",reason ?: @"-");
}


static void XLGB6ProbeSnapshot(NSString *reason) {
    NSArray<NSString *> *desired=XLGB6DesiredPages();
    XLGB6Log(@"========== SNAPSHOT %@ ==========",reason ?: @"-");
    XLGB6Log(@"STATE liquidGlass=%@ bh_tabs_visible=%@",
             XLGEnabled() ? @"ON" : @"OFF",
             desired.count ? [desired componentsJoinedByString:@","] : @"nil");

    XLGB6Log(@"NATIVE_CONNECTION_SUMMARY withIDsCalls=%lu noArgCalls=%lu lastInput=%@ lastForwarded=%@ lastAfter=%@",
             (unsigned long)gXLGB67NativeRecalcWithIDsCount,
             (unsigned long)gXLGB67NativeRecalcCount,
             gXLGB67LastInputDescription ?: @"-",
             gXLGB67LastForwardedDescription ?: @"-",
             gXLGB67LastAfterDescription ?: @"-");

    XLGB68DumpConstructorProbe(reason);
    XLGB69DumpSwiftSymbolSources(reason);
    XLGB63DumpSwiftAppNavigation(reason);

    Class utility=NSClassFromString(@"CustomTabBarUtility");
    XLGB6Log(@"BH utility=%@ registryClass=%@ available=%@ visible=%@ defaults=%@",
             utility ? NSStringFromClass(utility) : @"nil",
             XLGB6ClassObjectBySelector(utility,@"registry")
                ? NSStringFromClass([XLGB6ClassObjectBySelector(utility,@"registry") class])
                : @"nil",
             XLGB6ClassObjectBySelector(utility,@"availableTabs") ?: @"nil",
             XLGB6ClassObjectBySelector(utility,@"visiblePageIDsInOrder") ?: @"nil",
             XLGB6ClassObjectBySelector(utility,@"defaultVisiblePageIDs") ?: @"nil");

    NSMutableArray<UIViewController *> *queue=[NSMutableArray array];
    NSMutableSet<NSValue *> *visited=[NSMutableSet set];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) {
            if (window.rootViewController) [queue addObject:window.rootViewController];
            XLGB6ProbeView(window,0);
        }
    }

    for (NSUInteger i=0;i<queue.count && i<220;i++) {
        UIViewController *vc=queue[i];
        NSValue *pointer=[NSValue valueWithPointer:(__bridge const void *)vc];
        if ([visited containsObject:pointer]) continue;
        [visited addObject:pointer];

        NSString *name=NSStringFromClass(vc.class) ?: @"";
        NSString *lower=name.lowercaseString ?: @"";
        if ([lower containsString:@"tabbedappnavigation"] ||
            [lower containsString:@"tabbarcontroller"]) {
            id visible=XLGB6ObjectBySelector(vc,@"visibleTabEntries");
            if (!visible) visible=XLGSafeValueForKey(vc,@"visibleTabEntries");
            id tabs=XLGB6ObjectBySelector(vc,@"tabs");
            if (!tabs) tabs=XLGSafeValueForKey(vc,@"tabs");
            id dataSource=XLGB6ObjectBySelector(vc,@"dataSource");
            if (!dataSource) dataSource=XLGSafeValueForKey(vc,@"dataSource");
            if (!dataSource) dataSource=XLGSafeValueForKey(vc,@"_dataSource");

            XLGB6Log(@"VC class=%@ ptr=%p visible=%@ tabs=%@ dataSource=%@",
                     name,vc,
                     [visible isKindOfClass:NSArray.class]
                        ? XLGB6DescribeArray((NSArray *)visible) : @"-",
                     [tabs isKindOfClass:NSArray.class]
                        ? XLGB6DescribeArray((NSArray *)tabs) : @"-",
                     dataSource
                        ? NSStringFromClass([dataSource class]) : @"nil");

            if (dataSource) {
                for (NSString *key in @[
                    @"tabContent",@"tabContentByIdentifier",
                    @"visibleTabEntries",@"allTabEntries",
                    @"availableTabEntries",@"tabEntries"
                ]) {
                    id value=XLGB6ObjectBySelector(dataSource,key);
                    if (!value) value=XLGSafeValueForKey(dataSource,key);
                    if (!value) continue;
                    XLGB6Log(@"DATASOURCE class=%@ key=%@ valueClass=%@ value=%@",
                             NSStringFromClass([dataSource class]) ?: @"?",
                             key,
                             NSStringFromClass([value class]) ?: @"?",
                             [value isKindOfClass:NSArray.class]
                                ? XLGB6DescribeArray((NSArray *)value)
                                : [value description]);
                }
            }
        }

        for (UIViewController *child in vc.childViewControllers ?: @[]) {
            if (child) [queue addObject:child];
        }
        if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
    }
}

static void XLGB6ScheduleSnapshot(NSString *reason, NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            XLGB6ProbeSnapshot(reason);
        });
}

static void XLGB6SetVisibleTabEntries(id self, SEL cmd, id value) {
    NSArray *current=[value isKindOfClass:NSArray.class] ? value : nil;
    XLGB6Log(@"HOOK setVisibleTabEntries owner=%@ ptr=%p inputCount=%lu input=%@",
             NSStringFromClass([self class]) ?: @"?",
             self,
             (unsigned long)current.count,
             current ? XLGB6DescribeArray(current) : @"not-array");

    NSString *missing=nil;
    NSArray *forwarded=current
        ? XLGB6CorrectedEntries(self,current,@"visibleTabEntries",&missing)
        : current;

    IMP original=XLGB6OriginalForObject(
        self,gXLGB6VisibleSetterOriginals);
    if (original) {
        ((void(*)(id,SEL,id))original)(
            self,cmd,forwarded ?: value);
    }

    XLGB6Log(@"HOOK setVisibleTabEntries forwardedCount=%lu forwarded=%@ missing=%@",
             (unsigned long)forwarded.count,
             forwarded ? XLGB6DescribeArray(forwarded) : @"not-array",
             missing ?: @"-");
    XLGB6ScheduleSnapshot(@"after-visibleTabEntries",0.08);
}

static void XLGB6SetTabContent(id self, SEL cmd, id value) {
    NSArray *current=[value isKindOfClass:NSArray.class] ? value : nil;
    XLGB6Log(@"HOOK setTabContent owner=%@ ptr=%p inputCount=%lu input=%@",
             NSStringFromClass([self class]) ?: @"?",
             self,
             (unsigned long)current.count,
             current ? XLGB6DescribeArray(current) : @"not-array");

    NSString *missing=nil;
    NSArray *forwarded=current
        ? XLGB6CorrectedEntries(self,current,@"tabContent",&missing)
        : current;

    IMP original=XLGB6OriginalForObject(
        self,gXLGB6DataSourceSetterOriginals);
    if (original) {
        ((void(*)(id,SEL,id))original)(
            self,cmd,forwarded ?: value);
    }

    XLGB6Log(@"HOOK setTabContent forwardedCount=%lu forwarded=%@ missing=%@",
             (unsigned long)forwarded.count,
             forwarded ? XLGB6DescribeArray(forwarded) : @"not-array",
             missing ?: @"-");
    XLGB6ScheduleSnapshot(@"after-tabContent",0.08);
}

static BOOL XLGB6HookSetterForClass(Class cls,
                                    SEL selector,
                                    IMP replacement,
                                    NSMutableDictionary<NSString *,NSValue *> *table) {
    if (!cls || !selector || !replacement || !table) return NO;
    Method method=class_getInstanceMethod(cls,selector);
    if (!method) return NO;

    IMP current=class_getMethodImplementation(cls,selector);
    if (!current) return NO;
    if (current==replacement) return YES;

    const char *types=method_getTypeEncoding(method);
    if (!types) return NO;

    NSString *name=NSStringFromClass(cls) ?: @"?";
    table[name]=[NSValue valueWithPointer:current];
    class_replaceMethod(cls,selector,replacement,types);

    BOOL ok=class_getMethodImplementation(cls,selector)==replacement;
    XLGB6Log(@"INSTALL class=%@ selector=%@ ok=%@ original=%p replacement=%p",
             name,NSStringFromSelector(selector),
             ok ? @"YES" : @"NO",current,replacement);
    return ok;
}


static NSArray *XLGB61DesiredPanelIDs(NSString **missingOut) {
    if (!XLGEnabled()) return nil;

    NSArray<NSString *> *desiredPages=XLGB6DesiredPages();
    if (!desiredPages.count) {
        if (missingOut) *missingOut=@"no-bh-pages";
        return nil;
    }

    Class utility=NSClassFromString(@"CustomTabBarUtility");
    id available=XLGB6ClassObjectBySelector(utility,@"availableTabs");
    if (![available isKindOfClass:NSArray.class]) {
        if (missingOut) *missingOut=@"availableTabs-unavailable";
        return nil;
    }

    NSMutableDictionary<NSString *,id> *pageToPanel=[NSMutableDictionary dictionary];

    for (id item in (NSArray *)available) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *entry=(NSDictionary *)item;

        id rawPage=entry[@"page"];
        id rawPanel=entry[@"panelID"];
        if (![rawPage isKindOfClass:NSString.class] || !rawPanel) continue;

        NSString *page=[(NSString *)rawPage lowercaseString];
        if (!page.length || pageToPanel[page]) continue;

        if ([rawPanel isKindOfClass:NSNumber.class]) {
            pageToPanel[page]=rawPanel;
        } else if ([rawPanel respondsToSelector:@selector(integerValue)]) {
            pageToPanel[page]=@([rawPanel integerValue]);
        }
    }

    NSMutableArray *ordered=[NSMutableArray arrayWithCapacity:desiredPages.count];
    NSMutableArray<NSString *> *missing=[NSMutableArray array];

    for (NSString *page in desiredPages) {
        id panelID=pageToPanel[page];
        if (panelID) [ordered addObject:panelID];
        else [missing addObject:page];
    }

    if (missing.count) {
        NSString *value=[missing componentsJoinedByString:@","];
        if (missingOut) *missingOut=value;
        XLGB6Log(@"PANEL_MAP result=INCOMPLETE desiredPages=%@ map=%@ missing=%@",
                 [desiredPages componentsJoinedByString:@","],
                 pageToPanel,
                 value);
        return nil;
    }

    XLGB6Log(@"PANEL_MAP result=READY desiredPages=%@ panelIDs=%@",
             [desiredPages componentsJoinedByString:@","],
             ordered);
    return [ordered copy];
}

static NSString *XLGB61DescribePanelValue(id value) {
    if (!value) return @"nil";
    if ([value isKindOfClass:NSArray.class]) {
        return [NSString stringWithFormat:@"%@ count=%lu values=%@",
                NSStringFromClass([value class]),
                (unsigned long)[(NSArray *)value count],
                value];
    }
    return [NSString stringWithFormat:@"%@ value=%@",
            NSStringFromClass([value class]) ?: @"?",
            value];
}

static id XLGB61CorrectPanelIDs(id current, NSString *stage) {
    NSString *missing=nil;
    NSArray *desired=XLGB61DesiredPanelIDs(&missing);

    if (!desired.count) {
        XLGB6Log(@"PANEL_CORRECTION stage=%@ result=FALLBACK reason=%@ current=%@",
                 stage ?: @"-",
                 missing ?: @"unknown",
                 XLGB61DescribePanelValue(current));
        return current;
    }

    if (![current isKindOfClass:NSArray.class]) {
        XLGB6Log(@"PANEL_CORRECTION stage=%@ result=SKIP nonArray current=%@ desired=%@",
                 stage ?: @"-",
                 XLGB61DescribePanelValue(current),
                 desired);
        return current;
    }

    XLGB6Log(@"PANEL_CORRECTION stage=%@ result=APPLY original=%@ corrected=%@",
             stage ?: @"-",
             current,
             desired);
    return desired;
}

static id XLGB61VisiblePanelIDsForAppNavigation(
    id self, SEL cmd, id appNavigation) {

    id original=nil;
    if (gOrigXLGB61VisiblePanelIDsForAppNavigation) {
        original=((id(*)(id,SEL,id))
            gOrigXLGB61VisiblePanelIDsForAppNavigation)(
                self,cmd,appNavigation);
    }

    XLGB6Log(@"HOOK visiblePanelIDsForAppNavigation owner=%@ ptr=%p appNavigation=%@ original=%@",
             NSStringFromClass([self class]) ?: @"?",
             self,
             appNavigation ? NSStringFromClass([appNavigation class]) : @"nil",
             XLGB61DescribePanelValue(original));

    id corrected=XLGB61CorrectPanelIDs(
        original,@"visiblePanelIDsForAppNavigation");

    XLGB6Log(@"HOOK visiblePanelIDsForAppNavigation return=%@",
             XLGB61DescribePanelValue(corrected));

    XLGB6ScheduleSnapshot(@"after-visiblePanelIDs",0.05);
    return corrected;
}

static void XLGB61UpdateTabContentWithPanelIDs(
    id self, SEL cmd, id panelIDs) {

    XLGB6Log(@"HOOK _t1_updateTabContentWithUpdatedPanelIDs owner=%@ input=%@",
             NSStringFromClass([self class]) ?: @"?",
             XLGB61DescribePanelValue(panelIDs));

    id corrected=XLGB61CorrectPanelIDs(
        panelIDs,@"_t1_updateTabContentWithUpdatedPanelIDs");

    if (gOrigXLGB61UpdateTabContentWithPanelIDs) {
        ((void(*)(id,SEL,id))
            gOrigXLGB61UpdateTabContentWithPanelIDs)(
                self,cmd,corrected);
    }

    XLGB6Log(@"HOOK _t1_updateTabContentWithUpdatedPanelIDs forwarded=%@",
             XLGB61DescribePanelValue(corrected));
    XLGB6ScheduleSnapshot(@"after-updateTabContent",0.05);
}

static void XLGB61UpdateTabVCsWithPanelIDs(
    id self, SEL cmd, id panelIDs) {

    XLGB6Log(@"HOOK _t1_updateTabViewControllersWithUpdatedPanelIDs owner=%@ input=%@",
             NSStringFromClass([self class]) ?: @"?",
             XLGB61DescribePanelValue(panelIDs));

    id corrected=XLGB61CorrectPanelIDs(
        panelIDs,@"_t1_updateTabViewControllersWithUpdatedPanelIDs");

    if (gOrigXLGB61UpdateTabVCsWithPanelIDs) {
        ((void(*)(id,SEL,id))
            gOrigXLGB61UpdateTabVCsWithPanelIDs)(
                self,cmd,corrected);
    }

    XLGB6Log(@"HOOK _t1_updateTabViewControllersWithUpdatedPanelIDs forwarded=%@",
             XLGB61DescribePanelValue(corrected));
    XLGB6ScheduleSnapshot(@"after-updateTabVCs",0.05);
}

static void XLGB61RecalculateWithPanelIDs(
    id self, SEL cmd, id panelIDs) {

    XLGB6Log(@"HOOK recalculateVisiblePanelsWithUpdatedPanelIDs owner=%@ input=%@",
             NSStringFromClass([self class]) ?: @"?",
             XLGB61DescribePanelValue(panelIDs));

    id corrected=XLGB61CorrectPanelIDs(
        panelIDs,@"recalculateVisiblePanelsWithUpdatedPanelIDs");

    if (gOrigXLGB61RecalculateWithPanelIDs) {
        ((void(*)(id,SEL,id))
            gOrigXLGB61RecalculateWithPanelIDs)(
                self,cmd,corrected);
    }

    XLGB6Log(@"HOOK recalculateVisiblePanelsWithUpdatedPanelIDs forwarded=%@",
             XLGB61DescribePanelValue(corrected));
    XLGB6ScheduleSnapshot(@"after-recalculateVisiblePanels",0.05);
}

static void XLGB61InitializeTabContent(id self, SEL cmd) {
    XLGB6Log(@"HOOK _t1_initializeTabContent BEGIN owner=%@ ptr=%p",
             NSStringFromClass([self class]) ?: @"?",self);

    if (gOrigXLGB61InitializeTabContent) {
        ((void(*)(id,SEL))gOrigXLGB61InitializeTabContent)(self,cmd);
    }

    id visible=XLGB6ObjectBySelector(self,@"visibleTabEntries");
    id tabbed=XLGB6ObjectBySelector(self,@"tabbedViewController");
    id appNavigation=XLGB6ObjectBySelector(self,@"appNavigation");

    XLGB6Log(@"HOOK _t1_initializeTabContent END visibleTabEntries=%@ tabbedViewController=%@ appNavigation=%@",
             XLGB61DescribePanelValue(visible),
             tabbed ? NSStringFromClass([tabbed class]) : @"nil",
             appNavigation ? NSStringFromClass([appNavigation class]) : @"nil");

    XLGB6ScheduleSnapshot(@"after-initializeTabContent",0.05);
}

static void XLGB61InstallPanelPipelineHooks(void) {
    if (gXLGB61PanelPipelineHooksInstalled) return;

    Class cls=NSClassFromString(@"T1TabbedAppNavigationViewController");
    if (!cls) {
        XLGB6Log(@"PANEL_PIPELINE_INSTALL class=T1TabbedAppNavigationViewController missing");
        return;
    }

    BOOL any=NO;

    SEL visibleSEL=NSSelectorFromString(@"visiblePanelIDsForAppNavigation:");
    if ([cls instancesRespondToSelector:visibleSEL]) {
        BOOL ok=XLGHookMethod(
            cls,visibleSEL,NO,
            (IMP)XLGB61VisiblePanelIDsForAppNavigation,
            &gOrigXLGB61VisiblePanelIDsForAppNavigation);
        XLGB6Log(@"PANEL_PIPELINE_INSTALL selector=visiblePanelIDsForAppNavigation: ok=%@",
                 ok ? @"YES" : @"NO");
        any = any || ok;
    }

    SEL contentSEL=NSSelectorFromString(@"_t1_updateTabContentWithUpdatedPanelIDs:");
    if ([cls instancesRespondToSelector:contentSEL]) {
        BOOL ok=XLGHookMethod(
            cls,contentSEL,NO,
            (IMP)XLGB61UpdateTabContentWithPanelIDs,
            &gOrigXLGB61UpdateTabContentWithPanelIDs);
        XLGB6Log(@"PANEL_PIPELINE_INSTALL selector=_t1_updateTabContentWithUpdatedPanelIDs: ok=%@",
                 ok ? @"YES" : @"NO");
        any = any || ok;
    }

    SEL vcsSEL=NSSelectorFromString(@"_t1_updateTabViewControllersWithUpdatedPanelIDs:");
    if ([cls instancesRespondToSelector:vcsSEL]) {
        BOOL ok=XLGHookMethod(
            cls,vcsSEL,NO,
            (IMP)XLGB61UpdateTabVCsWithPanelIDs,
            &gOrigXLGB61UpdateTabVCsWithPanelIDs);
        XLGB6Log(@"PANEL_PIPELINE_INSTALL selector=_t1_updateTabViewControllersWithUpdatedPanelIDs: ok=%@",
                 ok ? @"YES" : @"NO");
        any = any || ok;
    }

    SEL recalcSEL=NSSelectorFromString(@"recalculateVisiblePanelsWithUpdatedPanelIDs:");
    if ([cls instancesRespondToSelector:recalcSEL]) {
        BOOL ok=XLGHookMethod(
            cls,recalcSEL,NO,
            (IMP)XLGB61RecalculateWithPanelIDs,
            &gOrigXLGB61RecalculateWithPanelIDs);
        XLGB6Log(@"PANEL_PIPELINE_INSTALL selector=recalculateVisiblePanelsWithUpdatedPanelIDs: ok=%@",
                 ok ? @"YES" : @"NO");
        any = any || ok;
    }

    SEL initSEL=NSSelectorFromString(@"_t1_initializeTabContent");
    if ([cls instancesRespondToSelector:initSEL]) {
        BOOL ok=XLGHookMethod(
            cls,initSEL,NO,
            (IMP)XLGB61InitializeTabContent,
            &gOrigXLGB61InitializeTabContent);
        XLGB6Log(@"PANEL_PIPELINE_INSTALL selector=_t1_initializeTabContent ok=%@",
                 ok ? @"YES" : @"NO");
        any = any || ok;
    }

    gXLGB61PanelPipelineHooksInstalled=any;
}





#pragma mark - XLiquidGlass 1.9.3 Beta 6.5 Native tab connection bridge

static NSString *XLGB65MethodKey(Class cls, SEL selector) {
    if (!cls || !selector) return @"";
    return [NSString stringWithFormat:@"%@|%@",
            NSStringFromClass(cls) ?: @"?",
            NSStringFromSelector(selector) ?: @"?"];
}

static IMP XLGB65OriginalForObjectSelector(
    id object,
    SEL selector,
    NSMutableDictionary<NSString *,NSValue *> *table) {

    if (!object || !selector || !table.count) return NULL;
    for (Class cls=[object class]; cls; cls=class_getSuperclass(cls)) {
        NSValue *value=table[XLGB65MethodKey(cls,selector)];
        if (value) return (IMP)[value pointerValue];
    }
    return NULL;
}

static BOOL XLGB65IsGathering(void) {
    return [[[NSThread currentThread].threadDictionary
        objectForKey:@"XLGB65NativeBridgeGathering"] boolValue];
}

static void XLGB65SetGathering(BOOL value) {
    NSMutableDictionary *dict=[NSThread currentThread].threadDictionary;
    if (value) dict[@"XLGB65NativeBridgeGathering"]=@YES;
    else [dict removeObjectForKey:@"XLGB65NativeBridgeGathering"];
}

static NSString *XLGB65PageForPanelIDValue(id value) {
    if (![value respondsToSelector:@selector(integerValue)]) return nil;
    NSInteger panel=[value integerValue];

    Class utility=NSClassFromString(@"CustomTabBarUtility");
    id available=XLGB6ClassObjectBySelector(utility,@"availableTabs");
    if (![available isKindOfClass:NSArray.class]) return nil;

    for (id raw in (NSArray *)available) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *entry=(NSDictionary *)raw;
        id rawPanel=entry[@"panelID"];
        id rawPage=entry[@"page"];
        if (![rawPanel respondsToSelector:@selector(integerValue)] ||
            ![rawPage isKindOfClass:NSString.class]) {
            continue;
        }
        if ([rawPanel integerValue]==panel) {
            return [(NSString *)rawPage lowercaseString];
        }
    }
    return nil;
}

static NSString *XLGB65PageForItem(id item) {
    if (!item || item==NSNull.null) return nil;

    if ([item isKindOfClass:NSNumber.class]) {
        return XLGB65PageForPanelIDValue(item);
    }

    if ([item isKindOfClass:NSString.class]) {
        NSString *text=[(NSString *)item lowercaseString];
        for (NSString *page in @[
            @"home",@"news",@"grok",@"guide",@"ntab",@"messages",
            @"communities",@"profile",@"lists",@"bookmarks",
            @"premium",@"jobs",@"payments",@"birdwatch",@"connect",@"dash"
        ]) {
            if ([text isEqualToString:page]) return page;
        }
        if ([text containsString:@"home"]) return @"home";
        if ([text containsString:@"news"]) return @"news";
        if ([text containsString:@"grok"]) return @"grok";
        if ([text containsString:@"guide"] ||
            [text containsString:@"explore"] ||
            [text containsString:@"search"]) return @"guide";
        if ([text containsString:@"notif"]) return @"ntab";
        if ([text containsString:@"message"] ||
            [text containsString:@"xchat"] ||
            [text containsString:@"direct"]) return @"messages";
        if ([text containsString:@"communit"]) return @"communities";
        if ([text containsString:@"profile"]) return @"profile";
        if ([text containsString:@"bookmark"]) return @"bookmarks";
        if ([text containsString:@"premium"]) return @"premium";
        if ([text containsString:@"dash"]) return @"dash";
        return nil;
    }

    NSString *mapped=XLGB6PageForEntry(item);
    if (mapped.length) return mapped;

    for (NSString *key in @[@"panelID",@"panelId",@"panelIdentifier"]) {
        id value=XLGSafeValueForKey(item,key);
        NSString *page=XLGB65PageForPanelIDValue(value);
        if (page.length) return page;
    }
    return nil;
}

static NSInteger XLGB65ArrayKind(NSArray *array) {
    // 1 = NSNumber panel IDs, 2 = NSString identifiers, 3 = native objects.
    for (id item in array) {
        if (!item || item==NSNull.null) continue;
        if ([item isKindOfClass:NSNumber.class]) return 1;
        if ([item isKindOfClass:NSString.class]) return 2;
        return 3;
    }
    return 0;
}

static BOOL XLGB65CompatiblePoolItem(id item, NSInteger kind) {
    if (!item || item==NSNull.null) return NO;
    if (kind==1) return [item isKindOfClass:NSNumber.class];
    if (kind==2) return [item isKindOfClass:NSString.class];
    if (kind==3) {
        return ![item isKindOfClass:NSNumber.class] &&
               ![item isKindOfClass:NSString.class] &&
               ![item isKindOfClass:NSDictionary.class] &&
               ![item isKindOfClass:NSSet.class] &&
               ![item isKindOfClass:NSArray.class];
    }
    return NO;
}

static void XLGB65AppendPoolValue(
    id value,
    NSInteger kind,
    NSMutableArray *pool) {

    if (!value || !pool) return;

    if ([value isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)value) {
            if (XLGB65CompatiblePoolItem(item,kind) &&
                ![pool containsObject:item]) {
                [pool addObject:item];
            }
        }
        return;
    }

    if ([value isKindOfClass:NSSet.class]) {
        for (id item in (NSSet *)value) {
            if (XLGB65CompatiblePoolItem(item,kind) &&
                ![pool containsObject:item]) {
                [pool addObject:item];
            }
        }
        return;
    }

    if ([value isKindOfClass:NSDictionary.class]) {
        for (id item in [(NSDictionary *)value allValues]) {
            if (XLGB65CompatiblePoolItem(item,kind) &&
                ![pool containsObject:item]) {
                [pool addObject:item];
            }
        }
    }
}


static id XLGB65SafeObjectGetterUnhooked(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector=NSSelectorFromString(selectorName);
    Method method=class_getInstanceMethod([object class],selector);
    if (!method || method_getNumberOfArguments(method)!=2) return nil;

    char returnType[32]={0};
    method_getReturnType(method,returnType,sizeof(returnType));
    const char *p=returnType;
    while (*p && strchr("rnNoORV",*p)) p++;
    if (*p!='@' && *p!='#') return nil;

    IMP original=XLGB65OriginalForObjectSelector(
        object,selector,gXLGB65ArrayGetterOriginals);

    @try {
        if (original) {
            return ((id(*)(id,SEL))original)(object,selector);
        }
        return ((id(*)(id,SEL))objc_msgSend)(object,selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSArray *XLGB65BuildConnectedArray(
    id owner,
    SEL selector,
    NSArray *original,
    NSString **missingOut) {

    if (!XLGEnabled() || ![original isKindOfClass:NSArray.class]) {
        return original;
    }

    NSArray<NSString *> *desiredPages=XLGB6DesiredPages();
    if (!desiredPages.count) return original;

    NSInteger kind=XLGB65ArrayKind(original);
    if (!kind) return original;

    // Numeric arrays are already native panel IDs. Here the bridge can map the
    // NFB source directly without inventing Swift objects.
    if (kind==1) {
        NSString *missing=nil;
        NSArray *panelIDs=XLGB61DesiredPanelIDs(&missing);
        if (panelIDs.count==desiredPages.count) {
            XLGB6Log(@"CONNECTION_BRIDGE owner=%@ selector=%@ kind=panelIDs original=%@ connected=%@",
                     NSStringFromClass([owner class]) ?: @"?",
                     NSStringFromSelector(selector),
                     original,
                     panelIDs);
            return panelIDs;
        }
        if (missingOut) *missingOut=missing ?: @"panel-map";
        return original;
    }

    NSMutableArray *pool=[NSMutableArray array];
    XLGB65AppendPoolValue(original,kind,pool);

    NSArray<NSString *> *sourceGetters=@[
        @"availableTabIdentifiers",@"allTabIdentifiers",
        @"defaultTabIdentifiers",@"tabIdentifiers",
        @"visibleTabIdentifiers",@"configuredTabIdentifiers",
        @"tabBarItems",@"availableTabBarItems",@"allTabBarItems",
        @"tabItems",@"availableTabItems",@"allTabItems",
        @"tabs",@"availableTabs",@"allTabs",
        @"tabEntries",@"availableTabEntries",@"allTabEntries",
        @"tabContent",@"tabContentByIdentifier",
        @"panelIDs",@"availablePanelIDs",@"visiblePanelIDs",
        @"items",@"availableItems",@"allItems"
    ];

    XLGB65SetGathering(YES);
    for (NSString *name in sourceGetters) {
        SEL candidate=NSSelectorFromString(name);
        if (candidate==selector) continue;
        id value=XLGB65SafeObjectGetterUnhooked(owner,name);
        NSUInteger before=pool.count;
        XLGB65AppendPoolValue(value,kind,pool);
        if (pool.count!=before) {
            XLGB6Log(@"CONNECTION_POOL owner=%@ getter=%@ added=%lu total=%lu class=%@",
                     NSStringFromClass([owner class]) ?: @"?",
                     name,
                     (unsigned long)(pool.count-before),
                     (unsigned long)pool.count,
                     value ? NSStringFromClass([value class]) : @"nil");
        }
    }
    XLGB65SetGathering(NO);

    NSMutableDictionary<NSString *,id> *byPage=[NSMutableDictionary dictionary];
    for (id item in pool) {
        NSString *page=XLGB65PageForItem(item);
        if (page.length && !byPage[page]) byPage[page]=item;
    }

    NSMutableArray *ordered=[NSMutableArray arrayWithCapacity:desiredPages.count];
    NSMutableArray *missing=[NSMutableArray array];
    for (NSString *page in desiredPages) {
        id item=byPage[page];
        if (item) [ordered addObject:item];
        else [missing addObject:page];
    }

    if (missing.count) {
        // String arrays that are clearly page-name identifiers can be bridged
        // directly from the NFB source even when the old five-item array lacks
        // News. Opaque string identifiers are left untouched.
        if (kind==2) {
            BOOL pageStyle=YES;
            for (id item in original) {
                if (![item isKindOfClass:NSString.class] ||
                    !XLGB65PageForItem(item)) {
                    pageStyle=NO;
                    break;
                }
            }
            if (pageStyle) {
                XLGB6Log(@"CONNECTION_BRIDGE owner=%@ selector=%@ kind=pageIDs original=%@ connected=%@",
                         NSStringFromClass([owner class]) ?: @"?",
                         NSStringFromSelector(selector),
                         original,
                         desiredPages);
                return desiredPages;
            }
        }

        NSString *missingString=[missing componentsJoinedByString:@","];
        if (missingOut) *missingOut=missingString;
        XLGB6Log(@"CONNECTION_BRIDGE owner=%@ selector=%@ result=INCOMPLETE kind=%ld original=%@ poolCount=%lu missing=%@",
                 NSStringFromClass([owner class]) ?: @"?",
                 NSStringFromSelector(selector),
                 (long)kind,
                 original,
                 (unsigned long)pool.count,
                 missingString);
        return original;
    }

    XLGB6Log(@"CONNECTION_BRIDGE owner=%@ selector=%@ result=CONNECTED kind=%ld original=%@ connected=%@",
             NSStringFromClass([owner class]) ?: @"?",
             NSStringFromSelector(selector),
             (long)kind,
             original,
             ordered);
    return [ordered copy];
}

static id XLGB65NativeArrayGetter(id self, SEL cmd) {
    IMP original=XLGB65OriginalForObjectSelector(
        self,cmd,gXLGB65ArrayGetterOriginals);
    if (!original) return nil;

    id value=nil;
    @try {
        value=((id(*)(id,SEL))original)(self,cmd);
    } @catch (__unused NSException *exception) {
        return nil;
    }

    if (XLGB65IsGathering() ||
        !XLGEnabled() ||
        ![value isKindOfClass:NSArray.class]) {
        return value;
    }

    NSString *missing=nil;
    NSArray *connected=XLGB65BuildConnectedArray(
        self,cmd,(NSArray *)value,&missing);

    XLGB6Log(@"CONNECTION_GETTER class=%@ selector=%@ originalCount=%lu returnCount=%lu missing=%@",
             NSStringFromClass([self class]) ?: @"?",
             NSStringFromSelector(cmd),
             (unsigned long)[(NSArray *)value count],
             (unsigned long)[connected count],
             missing ?: @"-");
    return connected ?: value;
}

static BOOL XLGB65NativeBoolGetter(id self, SEL cmd) {
    IMP original=XLGB65OriginalForObjectSelector(
        self,cmd,gXLGB65BoolGetterOriginals);

    BOOL originalValue=NO;
    if (original) {
        originalValue=((BOOL(*)(id,SEL))original)(self,cmd);
    }

    BOOL result=XLGEnabled() ? YES : originalValue;
    XLGB6Log(@"CONNECTION_BOOL class=%@ selector=%@ original=%@ return=%@",
             NSStringFromClass([self class]) ?: @"?",
             NSStringFromSelector(cmd),
             originalValue ? @"YES" : @"NO",
             result ? @"YES" : @"NO");
    return result;
}

static BOOL XLGB65ShouldBridgeObjectGetter(NSString *name) {
    if (!name.length || [name containsString:@":"]) return NO;
    NSString *lower=name.lowercaseString;

    BOOL relevant=
        [lower containsString:@"tab"] ||
        [lower containsString:@"panel"];
    if (!relevant) return NO;

    for (NSString *blocked in @[
        @"controller",@"view",@"image",@"title",@"subtitle",
        @"delegate",@"handler",@"observer",@"account",
        @"navigationcontroller",@"presentation"
    ]) {
        if ([lower containsString:blocked]) return NO;
    }

    // "available/all/default" getters are useful as the native object pool,
    // but must remain complete rather than being filtered to the user's six.
    if ([lower containsString:@"available"] ||
        [lower containsString:@"all"] ||
        [lower containsString:@"default"] ||
        [lower containsString:@"supported"]) {
        return NO;
    }

    return [lower containsString:@"identifier"] ||
           [lower containsString:@"item"] ||
           [lower containsString:@"entry"] ||
           [lower containsString:@"content"] ||
           [lower containsString:@"visible"] ||
           [lower containsString:@"selected"] ||
           [lower containsString:@"configured"] ||
           [lower isEqualToString:@"tabs"] ||
           [lower isEqualToString:@"panelids"] ||
           [lower isEqualToString:@"tabidentifiers"] ||
           [lower isEqualToString:@"tabbaritems"] ||
           [lower isEqualToString:@"tabitems"];
}

static void XLGB65InstallOnClass(Class cls) {
    if (!cls) return;

    NSString *className=NSStringFromClass(cls) ?: @"?";
    XLGB6Log(@"SOURCE_PROBE_CLASS_BEGIN class=%@ ptr=%p",className,cls);

    unsigned int propertyCount=0;
    objc_property_t *properties=class_copyPropertyList(cls,&propertyCount);
    for (unsigned int i=0;i<propertyCount;i++) {
        XLGB6Log(@"SOURCE_PROBE_PROPERTY class=%@ name=%s attrs=%s",
                 className,
                 property_getName(properties[i]) ?: "-",
                 property_getAttributes(properties[i]) ?: "-");
    }
    if (properties) free(properties);

    unsigned int ivarCount=0;
    Ivar *ivars=class_copyIvarList(cls,&ivarCount);
    for (unsigned int i=0;i<ivarCount;i++) {
        XLGB6Log(@"SOURCE_PROBE_IVAR class=%@ name=%s type=%s offset=%td",
                 className,
                 ivar_getName(ivars[i]) ?: "-",
                 ivar_getTypeEncoding(ivars[i]) ?: "-",
                 ivar_getOffset(ivars[i]));
    }
    if (ivars) free(ivars);

    unsigned int methodCount=0;
    Method *methods=class_copyMethodList(cls,&methodCount);
    for (unsigned int i=0;i<methodCount;i++) {
        Method method=methods[i];
        NSString *name=NSStringFromSelector(method_getName(method));
        NSString *lower=name.lowercaseString ?: @"";
        if ([lower containsString:@"tab"] ||
            [lower containsString:@"panel"] ||
            [lower containsString:@"navigation"] ||
            [lower containsString:@"content"] ||
            [lower containsString:@"identifier"] ||
            [lower containsString:@"config"] ||
            [lower containsString:@"visible"]) {
            XLGB6Log(@"SOURCE_PROBE_METHOD class=%@ selector=%@ types=%s",
                     className,name,method_getTypeEncoding(method) ?: "-");
        }
    }
    if (methods) free(methods);

    Class meta=object_getClass(cls);
    if (meta) {
        unsigned int classMethodCount=0;
        Method *classMethods=class_copyMethodList(meta,&classMethodCount);
        for (unsigned int i=0;i<classMethodCount;i++) {
            Method method=classMethods[i];
            NSString *name=NSStringFromSelector(method_getName(method));
            NSString *lower=name.lowercaseString ?: @"";
            if ([lower containsString:@"tab"] ||
                [lower containsString:@"panel"] ||
                [lower containsString:@"navigation"] ||
                [lower containsString:@"content"] ||
                [lower containsString:@"identifier"] ||
                [lower containsString:@"config"] ||
                [lower containsString:@"visible"] ||
                [lower containsString:@"settings"]) {
                XLGB6Log(@"SOURCE_PROBE_CLASS_METHOD class=%@ selector=%@ types=%s",
                         className,name,method_getTypeEncoding(method) ?: "-");
            }
        }
        if (classMethods) free(classMethods);
    }

    XLGB6Log(@"SOURCE_PROBE_CLASS_END class=%@",className);
}

static void XLGB65InstallNativeConnectionBridge(void) {
    static BOOL dumped=NO;
    if (dumped) return;
    dumped=YES;

    NSMutableSet<NSString *> *seen=[NSMutableSet set];

    for (NSString *requested in @[
        @"T1TabCustomizationConfig",
        @"T1TwitterSwift.MainAppNavigationSettings",
        @"_TtC14T1TwitterSwift25MainAppNavigationSettings",
        @"T1TwitterSwift.MainAppTabDataSource",
        @"_TtC14T1TwitterSwift20MainAppTabDataSource",
        @"T1TwitterSwift.XTabbedAppNavigationTab",
        @"_TtC14T1TwitterSwift24XTabbedAppNavigationTab"
    ]) {
        Class cls=NSClassFromString(requested);
        NSString *resolved=cls ? NSStringFromClass(cls) : @"nil";
        XLGB6Log(@"SOURCE_PROBE_CLASS_LOOKUP requested=%@ resolved=%@ ptr=%p",
                 requested,resolved,cls);
        if (!cls || [seen containsObject:resolved]) continue;
        [seen addObject:resolved];
        XLGB65InstallOnClass(cls);
    }
}

static void XLGB65NativeRebuild(NSString *reason) {
    if (!XLGEnabled()) return;

    id appNavigation=XLGSidebarAppNavigation();
    id visible=nil;
    SEL visibleSEL=NSSelectorFromString(@"visiblePanelIDs");

    if (appNavigation &&
        [appNavigation respondsToSelector:visibleSEL]) {
        @try {
            visible=((id(*)(id,SEL))objc_msgSend)(
                appNavigation,visibleSEL);
        } @catch (__unused NSException *exception) {
            visible=nil;
        }
    }

    XLGB6Log(@"SOURCE_PROBE_SNAPSHOT reason=%@ appNavigation=%@ ptr=%p visible=%@",
             reason ?: @"-",
             appNavigation ? NSStringFromClass([appNavigation class]) : @"nil",
             appNavigation,
             XLGB61DescribePanelValue(visible));

    XLGB6ScheduleSnapshot(
        [NSString stringWithFormat:@"source-probe-%@",reason ?: @"-"],
        0.04);
}

static void XLGB65ScheduleNativeRebuild(void) {
    if (gXLGB65RebuildScheduled) return;
    gXLGB65RebuildScheduled=YES;

    for (NSNumber *delay in @[@0.60,@1.60,@3.20]) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue*NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                XLGB65InstallNativeConnectionBridge();
                XLGB65NativeRebuild(
                    [NSString stringWithFormat:@"startup-%.2f",
                        delay.doubleValue]);
            });
    }
}


#pragma mark - XLiquidGlass 1.9.3 Beta 6.6 pre-view native panel bridge

static IMP gOrigXLGB66XTabbedViewDidLoad=NULL;
static IMP gOrigXLGB66SwiftRecalcWithIDs=NULL;
static IMP gOrigXLGB66SwiftRecalc=NULL;
static BOOL gXLGB66BridgeInstalled=NO;

static id XLGB66VisiblePanelIDs(id appNavigation) {
    if (!appNavigation) return nil;
    SEL sel=NSSelectorFromString(@"visiblePanelIDs");
    if (![appNavigation respondsToSelector:sel]) return nil;

    @try {
        return ((id(*)(id,SEL))objc_msgSend)(appNavigation,sel);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void XLGB66LogState(NSString *phase,
                           id controller,
                           id appNavigation) {
    XLGB6Log(@"PREVIEW_BRIDGE_STATE phase=%@ controller=%@ ptr=%p appNavigation=%@ ptr=%p visible=%@",
             phase ?: @"-",
             controller ? NSStringFromClass([controller class]) : @"nil",
             controller,
             appNavigation ? NSStringFromClass([appNavigation class]) : @"nil",
             appNavigation,
             XLGB61DescribePanelValue(XLGB66VisiblePanelIDs(appNavigation)));
}

static void XLGB66ObserveSwiftRecalcWithIDs(
    id self,
    SEL cmd,
    id panelIDs) {

    NSString *missing=nil;
    NSArray *desired=XLGB61DesiredPanelIDs(&missing);
    id forwarded=(XLGEnabled() && desired.count) ? desired : panelIDs;

    gXLGB67NativeRecalcWithIDsCount++;
    gXLGB67LastInputDescription=
        [XLGB61DescribePanelValue(panelIDs) copy];
    gXLGB67LastForwardedDescription=
        [XLGB61DescribePanelValue(forwarded) copy];

    XLGB6Log(@"NATIVE_CONNECTION selector=recalculateVisiblePanelsWithUpdatedPanelIDs: call=%lu owner=%@ ptr=%p input=%@ forwarded=%@ missing=%@",
             (unsigned long)gXLGB67NativeRecalcWithIDsCount,
             NSStringFromClass([self class]) ?: @"?",
             self,
             gXLGB67LastInputDescription ?: @"-",
             gXLGB67LastForwardedDescription ?: @"-",
             missing ?: @"-");

    if (gOrigXLGB66SwiftRecalcWithIDs) {
        ((void(*)(id,SEL,id))gOrigXLGB66SwiftRecalcWithIDs)(
            self,cmd,forwarded);
    }

    gXLGB67LastAfterDescription=
        [XLGB61DescribePanelValue(XLGB66VisiblePanelIDs(self)) copy];

    XLGB6Log(@"NATIVE_CONNECTION selector=recalculateVisiblePanelsWithUpdatedPanelIDs: call=%lu after=%@",
             (unsigned long)gXLGB67NativeRecalcWithIDsCount,
             gXLGB67LastAfterDescription ?: @"-");
}

static void XLGB66ObserveSwiftRecalc(
    id self,
    SEL cmd) {

    gXLGB67NativeRecalcCount++;

    XLGB6Log(@"NATIVE_CONNECTION selector=recalculateVisiblePanels call=%lu owner=%@ ptr=%p before=%@",
             (unsigned long)gXLGB67NativeRecalcCount,
             NSStringFromClass([self class]) ?: @"?",
             self,
             XLGB61DescribePanelValue(XLGB66VisiblePanelIDs(self)));

    if (gOrigXLGB66SwiftRecalc) {
        ((void(*)(id,SEL))gOrigXLGB66SwiftRecalc)(self,cmd);
    }

    XLGB6Log(@"NATIVE_CONNECTION selector=recalculateVisiblePanels call=%lu after=%@",
             (unsigned long)gXLGB67NativeRecalcCount,
             XLGB61DescribePanelValue(XLGB66VisiblePanelIDs(self)));
}

static void XLGB66XTabbedViewDidLoad(id self, SEL cmd) {
    id beforeAppNavigation=XLGB6ObjectBySelector(self,@"appNavigation");
    XLGB66LogState(@"before-viewDidLoad",self,beforeAppNavigation);

    // Beta 6.7 does not call recalculate manually. The connection is applied
    // only if X itself invokes its native recalculate-with-IDs pipeline.
    XLGB6Log(@"NATIVE_CONNECTION phase=before-viewDidLoad mode=PASSIVE_UNTIL_NATIVE_RECALC");

    if (gOrigXLGB66XTabbedViewDidLoad) {
        ((void(*)(id,SEL))gOrigXLGB66XTabbedViewDidLoad)(self,cmd);
    }

    id afterAppNavigation=XLGB6ObjectBySelector(self,@"appNavigation");
    XLGB66LogState(@"after-viewDidLoad",self,afterAppNavigation);

    XLGB6ScheduleSnapshot(@"beta66-after-viewDidLoad-0.05",0.05);
    XLGB6ScheduleSnapshot(@"beta66-after-viewDidLoad-0.25",0.25);
}

static void XLGB66InstallPreViewBridge(void) {
    if (gXLGB66BridgeInstalled) return;

    Class appNav=NSClassFromString(
        @"_TtC14T1TwitterSwift20XTabbedAppNavigation");
    if (!appNav) {
        appNav=NSClassFromString(
            @"T1TwitterSwift.XTabbedAppNavigation");
    }

    if (appNav) {
        SEL withIDs=
            NSSelectorFromString(@"recalculateVisiblePanelsWithUpdatedPanelIDs:");
        Method withIDsMethod=class_getInstanceMethod(appNav,withIDs);
        if (withIDsMethod &&
            method_getNumberOfArguments(withIDsMethod)==3) {
            BOOL ok=XLGHookMethod(
                appNav,
                withIDs,
                NO,
                (IMP)XLGB66ObserveSwiftRecalcWithIDs,
                &gOrigXLGB66SwiftRecalcWithIDs);
            XLGB6Log(@"PREVIEW_BRIDGE_INSTALL target=XTabbedAppNavigation selector=recalculateVisiblePanelsWithUpdatedPanelIDs: ok=%@",
                     ok ? @"YES" : @"NO");
        }

        SEL recalc=NSSelectorFromString(@"recalculateVisiblePanels");
        Method recalcMethod=class_getInstanceMethod(appNav,recalc);
        if (recalcMethod &&
            method_getNumberOfArguments(recalcMethod)==2) {
            BOOL ok=XLGHookMethod(
                appNav,
                recalc,
                NO,
                (IMP)XLGB66ObserveSwiftRecalc,
                &gOrigXLGB66SwiftRecalc);
            XLGB6Log(@"PREVIEW_BRIDGE_INSTALL target=XTabbedAppNavigation selector=recalculateVisiblePanels ok=%@",
                     ok ? @"YES" : @"NO");
        }
    }

    Class vc=NSClassFromString(
        @"_TtC14T1TwitterSwift34XTabbedAppNavigationViewController");
    if (!vc) {
        vc=NSClassFromString(
            @"T1TwitterSwift.XTabbedAppNavigationViewController");
    }

    if (!vc) {
        XLGB6Log(@"PREVIEW_BRIDGE_INSTALL target=XTabbedAppNavigationViewController result=MISSING");
        return;
    }

    SEL selector=@selector(viewDidLoad);
    Method method=class_getInstanceMethod(vc,selector);
    if (!method) {
        XLGB6Log(@"PREVIEW_BRIDGE_INSTALL target=XTabbedAppNavigationViewController selector=viewDidLoad result=MISSING");
        return;
    }

    BOOL ok=XLGHookMethod(
        vc,
        selector,
        NO,
        (IMP)XLGB66XTabbedViewDidLoad,
        &gOrigXLGB66XTabbedViewDidLoad);

    XLGB6Log(@"PREVIEW_BRIDGE_INSTALL target=XTabbedAppNavigationViewController selector=viewDidLoad ok=%@",
             ok ? @"YES" : @"NO");

    gXLGB66BridgeInstalled=ok;
}

#pragma mark - XLiquidGlass 1.9.3 Beta 6.4 Swift appNavigation correction

static id XLGB64SwiftVisiblePanelIDs(id self, SEL cmd) {
    id original=nil;
    if (gOrigXLGB64SwiftVisiblePanelIDs) {
        original=((id(*)(id,SEL))gOrigXLGB64SwiftVisiblePanelIDs)(self,cmd);
    }

    NSString *missing=nil;
    NSArray *desired=XLGB61DesiredPanelIDs(&missing);
    if (!XLGEnabled() || !desired.count) {
        XLGB6Log(@"SWIFT_FIX visiblePanelIDs result=ORIGINAL original=%@ missing=%@",
                 XLGB61DescribePanelValue(original),
                 missing ?: @"-");
        return original;
    }

    XLGB6Log(@"SWIFT_FIX visiblePanelIDs result=OVERRIDE original=%@ corrected=%@",
             XLGB61DescribePanelValue(original),
             XLGB61DescribePanelValue(desired));
    return desired;
}

static void XLGB64SwiftRecalcWithPanelIDs(id self, SEL cmd, id panelIDs) {
    NSString *missing=nil;
    NSArray *desired=XLGB61DesiredPanelIDs(&missing);
    id forwarded=(XLGEnabled() && desired.count) ? desired : panelIDs;

    XLGB6Log(@"SWIFT_FIX recalculateVisiblePanelsWithUpdatedPanelIDs input=%@ forwarded=%@ missing=%@ owner=%@ ptr=%p",
             XLGB61DescribePanelValue(panelIDs),
             XLGB61DescribePanelValue(forwarded),
             missing ?: @"-",
             NSStringFromClass([self class]) ?: @"?",
             self);

    if (gOrigXLGB64SwiftRecalcWithPanelIDs) {
        ((void(*)(id,SEL,id))gOrigXLGB64SwiftRecalcWithPanelIDs)(
            self,cmd,forwarded);
    }

    id after=nil;
    SEL visibleSEL=NSSelectorFromString(@"visiblePanelIDs");
    if ([self respondsToSelector:visibleSEL]) {
        @try {
            // This intentionally goes through our getter hook so the log also
            // records the effective six-ID view exposed to callers.
            after=((id(*)(id,SEL))objc_msgSend)(self,visibleSEL);
        } @catch (__unused NSException *exception) {
            after=nil;
        }
    }

    XLGB6Log(@"SWIFT_FIX recalculateVisiblePanelsWithUpdatedPanelIDs afterVisible=%@",
             XLGB61DescribePanelValue(after));
    XLGB6ScheduleSnapshot(@"after-swift-appnav-recalc",0.08);
}

static void XLGB64InstallSwiftAppNavHooks(void) {
    if (gXLGB64SwiftAppNavHooksInstalled) return;

    Class cls=NSClassFromString(@"_TtC14T1TwitterSwift20XTabbedAppNavigation");
    if (!cls) cls=NSClassFromString(@"T1TwitterSwift.XTabbedAppNavigation");
    if (!cls) {
        XLGB6Log(@"SWIFT_FIX_INSTALL class=XTabbedAppNavigation missing");
        return;
    }

    BOOL any=NO;

    SEL visibleSEL=NSSelectorFromString(@"visiblePanelIDs");
    Method visibleMethod=class_getInstanceMethod(cls,visibleSEL);
    if (visibleMethod &&
        method_getNumberOfArguments(visibleMethod)==2 &&
        method_getTypeEncoding(visibleMethod) &&
        method_getTypeEncoding(visibleMethod)[0]=='@') {
        BOOL ok=XLGHookMethod(
            cls,visibleSEL,NO,
            (IMP)XLGB64SwiftVisiblePanelIDs,
            &gOrigXLGB64SwiftVisiblePanelIDs);
        XLGB6Log(@"SWIFT_FIX_INSTALL selector=visiblePanelIDs ok=%@",
                 ok ? @"YES" : @"NO");
        any = any || ok;
    } else {
        XLGB6Log(@"SWIFT_FIX_INSTALL selector=visiblePanelIDs skipped=signature");
    }

    SEL recalcSEL=NSSelectorFromString(@"recalculateVisiblePanelsWithUpdatedPanelIDs:");
    Method recalcMethod=class_getInstanceMethod(cls,recalcSEL);
    if (recalcMethod &&
        method_getNumberOfArguments(recalcMethod)==3) {
        BOOL ok=XLGHookMethod(
            cls,recalcSEL,NO,
            (IMP)XLGB64SwiftRecalcWithPanelIDs,
            &gOrigXLGB64SwiftRecalcWithPanelIDs);
        XLGB6Log(@"SWIFT_FIX_INSTALL selector=recalculateVisiblePanelsWithUpdatedPanelIDs: ok=%@",
                 ok ? @"YES" : @"NO");
        any = any || ok;
    } else {
        XLGB6Log(@"SWIFT_FIX_INSTALL selector=recalculateVisiblePanelsWithUpdatedPanelIDs: skipped=signature");
    }

    gXLGB64SwiftAppNavHooksInstalled=any;
}

static void XLGB64ActiveSwiftAppNavReconcile(NSString *reason) {
    if (!XLGEnabled()) return;

    id appNavigation=XLGSidebarAppNavigation();
    if (!appNavigation ||
        ![appNavigation respondsToSelector:
            NSSelectorFromString(@"recalculateVisiblePanelsWithUpdatedPanelIDs:")]) {
        XLGB6Log(@"SWIFT_ACTIVE_RECONCILE reason=%@ result=NO_APPNAV appNavigation=%@",
                 reason ?: @"-",
                 appNavigation ? NSStringFromClass([appNavigation class]) : @"nil");
        return;
    }

    NSNumber *attemptValue=objc_getAssociatedObject(
        appNavigation,&kXLGB64SwiftReconcileAttemptsKey);
    NSInteger attempts=[attemptValue integerValue];
    if (attempts>=3) {
        XLGB6Log(@"SWIFT_ACTIVE_RECONCILE reason=%@ result=SKIP_MAX_ATTEMPTS attempts=%ld ptr=%p",
                 reason ?: @"-",(long)attempts,appNavigation);
        return;
    }

    NSString *missing=nil;
    NSArray *desired=XLGB61DesiredPanelIDs(&missing);
    if (!desired.count) {
        XLGB6Log(@"SWIFT_ACTIVE_RECONCILE reason=%@ result=NO_DESIRED_IDS missing=%@",
                 reason ?: @"-",missing ?: @"-");
        return;
    }

    id before=nil;
    SEL visibleSEL=NSSelectorFromString(@"visiblePanelIDs");
    if ([appNavigation respondsToSelector:visibleSEL]) {
        @try {
            before=((id(*)(id,SEL))objc_msgSend)(appNavigation,visibleSEL);
        } @catch (__unused NSException *exception) {
            before=nil;
        }
    }

    XLGB6Log(@"SWIFT_ACTIVE_RECONCILE reason=%@ appNavigation=%@ ptr=%p attempt=%ld before=%@ desired=%@",
             reason ?: @"-",
             NSStringFromClass([appNavigation class]) ?: @"?",
             appNavigation,
             (long)(attempts+1),
             XLGB61DescribePanelValue(before),
             XLGB61DescribePanelValue(desired));

    @try {
        ((void(*)(id,SEL,id))objc_msgSend)(
            appNavigation,
            NSSelectorFromString(@"recalculateVisiblePanelsWithUpdatedPanelIDs:"),
            desired);

        objc_setAssociatedObject(
            appNavigation,
            &kXLGB64SwiftReconcileAttemptsKey,
            @(attempts+1),
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (NSException *exception) {
        XLGB6Log(@"SWIFT_ACTIVE_RECONCILE reason=%@ result=EXCEPTION name=%@ detail=%@",
                 reason ?: @"-",
                 exception.name ?: @"-",
                 exception.reason ?: @"-");
        return;
    }

    id after=nil;
    if ([appNavigation respondsToSelector:visibleSEL]) {
        @try {
            after=((id(*)(id,SEL))objc_msgSend)(appNavigation,visibleSEL);
        } @catch (__unused NSException *exception) {
            after=nil;
        }
    }

    XLGB6Log(@"SWIFT_ACTIVE_RECONCILE reason=%@ result=CALLED after=%@",
             reason ?: @"-",
             XLGB61DescribePanelValue(after));

    XLGB6ScheduleSnapshot(
        [NSString stringWithFormat:@"swift-active-%@",reason ?: @"-"],
        0.10);
}

static void XLGB64ScheduleSwiftReconcile(NSString *reason,
                                         NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(delay*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            XLGB64ActiveSwiftAppNavReconcile(reason);
        });
}

static void XLGB64InstallSwiftReconcileSchedule(void) {
    static BOOL scheduled=NO;
    if (scheduled) return;
    scheduled=YES;

    XLGB64ScheduleSwiftReconcile(@"startup-0.55",0.55);
    XLGB64ScheduleSwiftReconcile(@"startup-1.10",1.10);
    XLGB64ScheduleSwiftReconcile(@"startup-2.20",2.20);
    XLGB64ScheduleSwiftReconcile(@"startup-3.50",3.50);
}


static UIViewController *XLGB62FindActiveNavigationController(void) {
    NSMutableArray<UIViewController *> *queue=[NSMutableArray array];
    NSMutableSet<NSValue *> *visited=[NSMutableSet set];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) {
            if (window.rootViewController) {
                [queue addObject:window.rootViewController];
            }
        }
    }

    for (NSUInteger i=0;i<queue.count && i<260;i++) {
        UIViewController *vc=queue[i];
        NSValue *pointer=[NSValue valueWithPointer:(__bridge const void *)vc];
        if ([visited containsObject:pointer]) continue;
        [visited addObject:pointer];

        NSString *name=NSStringFromClass(vc.class) ?: @"";
        if ([name isEqualToString:@"T1TwitterSwift.XTabbedAppNavigationViewController"] ||
            [name containsString:@"XTabbedAppNavigationViewController"]) {
            if ([vc respondsToSelector:
                    NSSelectorFromString(@"recalculateVisiblePanelsWithUpdatedPanelIDs:")]) {
                return vc;
            }
        }

        for (UIViewController *child in vc.childViewControllers ?: @[]) {
            if (child) [queue addObject:child];
        }
        if (vc.presentedViewController) {
            [queue addObject:vc.presentedViewController];
        }
    }

    return nil;
}

static void XLGB62ActiveReconcile(NSString *reason) {
    if (!XLGEnabled()) return;

    UIViewController *controller=XLGB62FindActiveNavigationController();
    if (!controller) {
        XLGB6Log(@"ACTIVE_RECONCILE reason=%@ result=NO_CONTROLLER",
                 reason ?: @"-");
        return;
    }

    NSNumber *attemptValue=objc_getAssociatedObject(
        controller,&kXLGB62ActiveReconcileAttemptsKey);
    NSInteger attempts=[attemptValue integerValue];
    if (attempts>=3) {
        XLGB6Log(@"ACTIVE_RECONCILE reason=%@ result=SKIP_MAX_ATTEMPTS controller=%@ ptr=%p attempts=%ld",
                 reason ?: @"-",
                 NSStringFromClass(controller.class) ?: @"?",
                 controller,
                 (long)attempts);
        return;
    }

    NSString *missing=nil;
    NSArray *desired=XLGB61DesiredPanelIDs(&missing);
    if (!desired.count) {
        XLGB6Log(@"ACTIVE_RECONCILE reason=%@ result=NO_DESIRED_PANEL_IDS missing=%@",
                 reason ?: @"-",
                 missing ?: @"-");
        return;
    }

    id appNavigation=XLGB6ObjectBySelector(controller,@"appNavigation");
    id visibleBefore=nil;
    SEL visibleSEL=NSSelectorFromString(@"visiblePanelIDsForAppNavigation:");
    if (appNavigation && [controller respondsToSelector:visibleSEL]) {
        @try {
            visibleBefore=((id(*)(id,SEL,id))objc_msgSend)(
                controller,visibleSEL,appNavigation);
        } @catch (__unused NSException *exception) {
            visibleBefore=nil;
        }
    }

    XLGB6Log(@"ACTIVE_RECONCILE reason=%@ controller=%@ ptr=%p attempt=%ld appNavigation=%@ visibleBefore=%@ desired=%@",
             reason ?: @"-",
             NSStringFromClass(controller.class) ?: @"?",
             controller,
             (long)(attempts+1),
             appNavigation ? NSStringFromClass([appNavigation class]) : @"nil",
             XLGB61DescribePanelValue(visibleBefore),
             desired);

    SEL recalcSEL=NSSelectorFromString(
        @"recalculateVisiblePanelsWithUpdatedPanelIDs:");

    @try {
        ((void(*)(id,SEL,id))objc_msgSend)(
            controller,recalcSEL,desired);

        objc_setAssociatedObject(
            controller,
            &kXLGB62ActiveReconcileAttemptsKey,
            @(attempts+1),
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        XLGB6Log(@"ACTIVE_RECONCILE reason=%@ result=CALLED panelIDs=%@",
                 reason ?: @"-",desired);
    } @catch (NSException *exception) {
        XLGB6Log(@"ACTIVE_RECONCILE reason=%@ result=EXCEPTION name=%@ reason=%@",
                 reason ?: @"-",
                 exception.name ?: @"-",
                 exception.reason ?: @"-");
        return;
    }

    XLGB6ScheduleSnapshot(
        [NSString stringWithFormat:@"active-reconcile-%@",reason ?: @"-"],
        0.10);
}

static void XLGB62ScheduleActiveReconcile(NSString *reason,
                                          NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(delay*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            XLGB62ActiveReconcile(reason);
        });
}

static void XLGB62InstallActiveReconcileSchedule(void) {
    if (gXLGB62ActiveReconcileScheduled) return;
    gXLGB62ActiveReconcileScheduled=YES;

    // Early attempts may legitimately find no controller. Once the real Swift
    // navigation VC exists, allow up to three coordinated recalculations.
    XLGB62ScheduleActiveReconcile(@"startup-0.45",0.45);
    XLGB62ScheduleActiveReconcile(@"startup-0.90",0.90);
    XLGB62ScheduleActiveReconcile(@"startup-1.60",1.60);
    XLGB62ScheduleActiveReconcile(@"startup-3.00",3.00);
}


static void XLGB6InstallCorrectionHooks(void) {
    // Beta 6.5 deliberately disables the prior post-construction forcing
    // (visiblePanelIDs, PanelID reconcile and legacy tabContent setters).
    // Keep their symbols referenced only so -Werror does not treat the retained
    // diagnostic implementations as dead code.
    (void)gXLGB6VisibleHooksInstalled;
    (void)gXLGB6DataSourceHooksInstalled;
    (void)gXLGB6ProbeScheduled;
    (void)&XLGB6ProbeRuntimeMethods;
    (void)&XLGB6SetVisibleTabEntries;
    (void)&XLGB6SetTabContent;
    (void)&XLGB6HookSetterForClass;
    (void)&XLGB61InstallPanelPipelineHooks;
    (void)&XLGB64InstallSwiftAppNavHooks;
    (void)&XLGB64InstallSwiftReconcileSchedule;
    (void)&XLGB62InstallActiveReconcileSchedule;

    // Beta 6.5.1 is read-only at the native tab source. It does not
    // replace getters, force isTabCustomizationEnabled or call recalculate.
    (void)&XLGB65ShouldBridgeObjectGetter;
    (void)&XLGB65NativeArrayGetter;
    (void)&XLGB65NativeBoolGetter;
    (void)&XLGB65BuildConnectedArray;
    (void)gXLGB65ArrayGetterOriginals;
    (void)gXLGB65BoolGetterOriginals;
    (void)gXLGB65DefaultsObserver;
    (void)&kXLGB65RebuildAttemptKey;

    XLGB65InstallNativeConnectionBridge();
    XLGB65ScheduleNativeRebuild();

    // Beta 6.7: do not force a late/pre-view recalc. Intercept only X's own
    // native recalculate-with-IDs calls and reconnect them to NFB's six IDs.
    XLGB66InstallPreViewBridge();
}





#pragma mark - XLiquidGlass 1.9.3 Beta 6.9 Swift symbol source probe

typedef char *(*XLGB69SwiftDemangleFn)(
    const char *mangledName,
    size_t mangledNameLength,
    char *outputBuffer,
    size_t *outputBufferSize,
    uint32_t flags);

static NSString *XLGB69DemangleSymbol(const char *rawName) {
    if (!rawName || !rawName[0]) return nil;

    static XLGB69SwiftDemangleFn demangleFn=NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        demangleFn=(XLGB69SwiftDemangleFn)
            dlsym(RTLD_DEFAULT,"swift_demangle");
    });

    if (!demangleFn) return nil;

    const char *input=rawName;
    if (input[0]=='_' && input[1]=='$') input++;

    if (!(input[0]=='$' && (input[1]=='s' || input[1]=='S'))) {
        return nil;
    }

    char *result=demangleFn(input,strlen(input),NULL,NULL,0);
    if (!result) return nil;

    NSString *string=[NSString stringWithUTF8String:result];
    free(result);
    return string;
}

static BOOL XLGB69SymbolInteresting(NSString *raw,
                                    NSString *demangled) {
    NSString *joined=[NSString stringWithFormat:@"%@ %@",
        raw ?: @"",demangled ?: @""];
    NSString *lower=joined.lowercaseString ?: @"";

    for (NSString *needle in @[
        @"xnavigation",
        @"tabbarcontroller",
        @"descriptor",
        @"xtabbedappnavigation",
        @"mainappnavigationsettings",
        @"mainapptabdatasource",
        @"tabidentifier",
        @"visiblepanel",
        @"appnavigationtab",
        @"tabcustomization",
        @"newsappnavigation",
        @"newsappnavigationtab",
        @"tabcontent"
    ]) {
        if ([lower containsString:needle]) return YES;
    }
    return NO;
}

static BOOL XLGB69ImageInteresting(const char *imageName) {
    if (!imageName) return NO;
    NSString *path=[NSString stringWithUTF8String:imageName];
    NSString *base=path.lastPathComponent ?: path;
    return [base containsString:@"T1Twitter"] ||
           [base containsString:@"XServiceLibraries"];
}

static void XLGB69DumpSymbolsForImage(uint32_t imageIndex,
                                      NSUInteger *globalCount) {
    const char *imageName=_dyld_get_image_name(imageIndex);
    if (!XLGB69ImageInteresting(imageName)) return;

    const struct mach_header *genericHeader=
        _dyld_get_image_header(imageIndex);
    if (!genericHeader) return;

    if (genericHeader->magic!=MH_MAGIC_64 &&
        genericHeader->magic!=MH_CIGAM_64) {
        XLGB6Log(@"SYMBOL_IMAGE image=%s result=UNSUPPORTED_MAGIC magic=0x%x",
                 imageName ?: "-",genericHeader->magic);
        return;
    }

    const struct mach_header_64 *header=
        (const struct mach_header_64 *)genericHeader;
    intptr_t slide=_dyld_get_image_vmaddr_slide(imageIndex);

    const struct symtab_command *symtabCommand=NULL;
    const struct segment_command_64 *linkeditSegment=NULL;

    const uint8_t *cursor=
        (const uint8_t *)(header+1);

    for (uint32_t i=0;i<header->ncmds;i++) {
        const struct load_command *lc=
            (const struct load_command *)cursor;
        if (!lc || lc->cmdsize<sizeof(struct load_command)) break;

        if (lc->cmd==LC_SYMTAB &&
            lc->cmdsize>=sizeof(struct symtab_command)) {
            symtabCommand=(const struct symtab_command *)lc;
        } else if (lc->cmd==LC_SEGMENT_64 &&
                  lc->cmdsize>=sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment=
                (const struct segment_command_64 *)lc;
            if (strncmp(segment->segname,SEG_LINKEDIT,16)==0) {
                linkeditSegment=segment;
            }
        }

        cursor+=lc->cmdsize;
    }

    NSString *base=imageName
        ? [[[NSString stringWithUTF8String:imageName]
            lastPathComponent] copy]
        : @"-";

    if (!symtabCommand || !linkeditSegment) {
        XLGB6Log(@"SYMBOL_IMAGE image=%@ result=NO_SYMTAB_OR_LINKEDIT symtab=%@ linkedit=%@",
                 base,
                 symtabCommand ? @"YES" : @"NO",
                 linkeditSegment ? @"YES" : @"NO");
        return;
    }

    uintptr_t linkeditBase=
        (uintptr_t)slide +
        (uintptr_t)linkeditSegment->vmaddr -
        (uintptr_t)linkeditSegment->fileoff;

    const struct nlist_64 *symbols=
        (const struct nlist_64 *)(linkeditBase+symtabCommand->symoff);
    const char *strings=
        (const char *)(linkeditBase+symtabCommand->stroff);

    XLGB6Log(@"SYMBOL_IMAGE image=%@ slide=0x%llx nsyms=%u strsize=%u",
             base,
             (unsigned long long)slide,
             symtabCommand->nsyms,
             symtabCommand->strsize);

    NSUInteger matched=0;
    for (uint32_t i=0;i<symtabCommand->nsyms;i++) {
        if (matched>=260 || (globalCount && *globalCount>=520)) break;

        uint32_t stringIndex=symbols[i].n_un.n_strx;
        if (stringIndex==0 ||
            stringIndex>=symtabCommand->strsize) {
            continue;
        }

        const char *rawName=strings+stringIndex;
        if (!rawName || !rawName[0]) continue;

        size_t remaining=
            (size_t)(symtabCommand->strsize-stringIndex);
        if (!memchr(rawName,'\0',remaining)) continue;

        NSString *raw=[NSString stringWithUTF8String:rawName];
        if (!raw.length) continue;

        NSString *demangled=XLGB69DemangleSymbol(rawName);
        if (!XLGB69SymbolInteresting(raw,demangled)) continue;

        uintptr_t runtimeAddress=0;
        if (symbols[i].n_value) {
            runtimeAddress=
                (uintptr_t)symbols[i].n_value+(uintptr_t)slide;
        }

        XLGB6Log(@"SWIFT_SYMBOL image=%@ index=%u address=%p type=0x%x raw=%@ demangled=%@",
                 base,
                 i,
                 (void *)runtimeAddress,
                 symbols[i].n_type,
                 raw,
                 demangled ?: @"-");

        matched++;
        if (globalCount) (*globalCount)++;
    }

    XLGB6Log(@"SYMBOL_IMAGE_END image=%@ matched=%lu",
             base,(unsigned long)matched);
}

static void XLGB69DumpSwiftSymbolSources(NSString *reason) {
    XLGB6Log(@"========== SWIFT_SYMBOL_SOURCE_PROBE %@ ==========",
             reason ?: @"-");

    NSUInteger totalMatched=0;
    uint32_t imageCount=_dyld_image_count();
    for (uint32_t i=0;i<imageCount;i++) {
        XLGB69DumpSymbolsForImage(i,&totalMatched);
        if (totalMatched>=520) break;
    }

    XLGB6Log(@"SWIFT_SYMBOL_SOURCE_SUMMARY matched=%lu images=%u",
             (unsigned long)totalMatched,imageCount);
    XLGB6Log(@"========== SWIFT_SYMBOL_SOURCE_PROBE_END %@ ==========",
             reason ?: @"-");
}

#pragma mark - XLiquidGlass 1.9.3 Beta 6.8 constructor/factory source probe

static BOOL XLGB68InterestingMethodName(NSString *name) {
    if (!name.length) return NO;
    NSString *lower=name.lowercaseString ?: @"";
    return [lower hasPrefix:@"init"] ||
           [lower containsString:@"descriptor"] ||
           [lower containsString:@"factory"] ||
           [lower containsString:@"create"] ||
           [lower containsString:@"make"] ||
           [lower containsString:@"build"] ||
           [lower containsString:@"tab"] ||
           [lower containsString:@"navigation"] ||
           [lower containsString:@"setting"] ||
           [lower containsString:@"config"] ||
           [lower containsString:@"identifier"] ||
           [lower containsString:@"content"] ||
           [lower containsString:@"source"];
}

static NSString *XLGB68SymbolForIMP(IMP imp, NSString **imageOut) {
    if (!imp) return @"-";
    Dl_info info={0};
    if (!dladdr((const void *)imp,&info)) return @"-";

    if (imageOut) {
        *imageOut=info.dli_fname
            ? [[NSString stringWithUTF8String:info.dli_fname] lastPathComponent]
            : @"-";
    }

    return info.dli_sname
        ? [NSString stringWithUTF8String:info.dli_sname]
        : @"-";
}

static void XLGB68DumpMethodsForClass(Class cls, NSString *origin) {
    if (!cls) return;
    NSString *className=NSStringFromClass(cls) ?: @"?";

    unsigned int count=0;
    Method *methods=class_copyMethodList(cls,&count);
    for (unsigned int i=0;i<count;i++) {
        Method method=methods[i];
        NSString *selectorName=
            NSStringFromSelector(method_getName(method)) ?: @"";
        if (!XLGB68InterestingMethodName(selectorName)) continue;

        IMP imp=method_getImplementation(method);
        NSString *image=nil;
        NSString *symbol=XLGB68SymbolForIMP(imp,&image);

        XLGB6Log(@"CTOR_METHOD origin=%@ kind=instance class=%@ selector=%@ types=%s imp=%p symbol=%@ image=%@",
                 origin ?: @"-",
                 className,
                 selectorName,
                 method_getTypeEncoding(method) ?: "-",
                 imp,
                 symbol ?: @"-",
                 image ?: @"-");
    }
    if (methods) free(methods);

    Class meta=object_getClass(cls);
    if (!meta) return;

    count=0;
    methods=class_copyMethodList(meta,&count);
    for (unsigned int i=0;i<count;i++) {
        Method method=methods[i];
        NSString *selectorName=
            NSStringFromSelector(method_getName(method)) ?: @"";
        if (!XLGB68InterestingMethodName(selectorName)) continue;

        IMP imp=method_getImplementation(method);
        NSString *image=nil;
        NSString *symbol=XLGB68SymbolForIMP(imp,&image);

        XLGB6Log(@"CTOR_METHOD origin=%@ kind=class class=%@ selector=%@ types=%s imp=%p symbol=%@ image=%@",
                 origin ?: @"-",
                 className,
                 selectorName,
                 method_getTypeEncoding(method) ?: "-",
                 imp,
                 symbol ?: @"-",
                 image ?: @"-");
    }
    if (methods) free(methods);
}

static BOOL XLGB68InterestingRuntimeClassName(NSString *name) {
    if (!name.length) return NO;
    BOOL module=
        [name containsString:@"XNavigation"] ||
        [name containsString:@"T1TwitterSwift"] ||
        [name containsString:@"T1TabCustomization"] ||
        [name containsString:@"T1MainAppTabDataSource"];
    if (!module) return NO;

    NSString *lower=name.lowercaseString ?: @"";
    return [lower containsString:@"tab"] ||
           [lower containsString:@"navigation"] ||
           [lower containsString:@"descriptor"] ||
           [lower containsString:@"setting"] ||
           [lower containsString:@"customization"];
}

static void XLGB68DumpConstructorProbe(NSString *reason) {
    XLGB6Log(@"========== CTOR_FACTORY_PROBE %@ ==========",reason ?: @"-");

    NSArray<NSString *> *targets=@[
        @"T1TwitterSwift.XTabbedAppNavigation",
        @"_TtC14T1TwitterSwift20XTabbedAppNavigation",
        @"T1TwitterSwift.XTabbedAppNavigationViewController",
        @"_TtC14T1TwitterSwift34XTabbedAppNavigationViewController",
        @"T1TwitterSwift.MainAppNavigationSettings",
        @"_TtC14T1TwitterSwift25MainAppNavigationSettings",
        @"T1MainAppTabDataSource",
        @"T1TwitterSwift.MainAppTabDataSource",
        @"_TtC14T1TwitterSwift20MainAppTabDataSource",
        @"T1TabCustomizationConfig",
        @"XNavigation.TabBarController",
        @"_TtC11XNavigation16TabBarController",
        @"XNavigation.TabBarView",
        @"_TtC11XNavigation10TabBarView",
        @"XNavigation.TabBarItemView",
        @"_TtC11XNavigation14TabBarItemView"
    ];

    NSMutableSet<NSString *> *seen=[NSMutableSet set];
    for (NSString *requested in targets) {
        Class cls=NSClassFromString(requested);
        NSString *resolved=cls ? NSStringFromClass(cls) : @"nil";
        XLGB6Log(@"CTOR_CLASS_LOOKUP requested=%@ resolved=%@ ptr=%p",
                 requested,resolved,cls);
        if (!cls || [seen containsObject:resolved]) continue;
        [seen addObject:resolved];
        XLGB68DumpMethodsForClass(cls,@"target");
    }

    int total=objc_getClassList(NULL,0);
    if (total>0 && total<100000) {
        Class *classes=(Class *)calloc((size_t)total,sizeof(Class));
        if (classes) {
            int fetched=objc_getClassList(classes,total);
            NSUInteger matched=0;
            for (int i=0;i<fetched;i++) {
                Class cls=classes[i];
                NSString *name=cls ? NSStringFromClass(cls) : nil;
                if (!XLGB68InterestingRuntimeClassName(name)) continue;
                if ([seen containsObject:name]) continue;
                [seen addObject:name];
                matched++;
                XLGB6Log(@"CTOR_DISCOVERED_CLASS class=%@ ptr=%p superclass=%@",
                         name ?: @"?",
                         cls,
                         class_getSuperclass(cls)
                            ? NSStringFromClass(class_getSuperclass(cls))
                            : @"nil");
                XLGB68DumpMethodsForClass(cls,@"discovered");
                if (matched>=80) break;
            }
            free(classes);
        }
    }

    for (NSString *symbolName in @[
        @"$s11XNavigation16TabBarControllerC11descriptorsACSayAC0B0VG_tcfc",
        @"_$s11XNavigation16TabBarControllerC11descriptorsACSayAC0B0VG_tcfc"
    ]) {
        void *address=dlsym(RTLD_DEFAULT,symbolName.UTF8String);
        Dl_info info={0};
        BOOL ok=address && dladdr(address,&info);
        XLGB6Log(@"CTOR_DLSYM requested=%@ address=%p resolvedSymbol=%@ image=%@",
                 symbolName,
                 address,
                 (ok && info.dli_sname)
                    ? [NSString stringWithUTF8String:info.dli_sname] : @"-",
                 (ok && info.dli_fname)
                    ? [[NSString stringWithUTF8String:info.dli_fname] lastPathComponent]
                    : @"-");
    }

    XLGB6Log(@"========== CTOR_FACTORY_PROBE_END %@ ==========",reason ?: @"-");
}

#pragma mark - XLiquidGlass 1.9.3 Beta 6 NFB probe UI

@interface XLiquidGlassBeta6ProbeViewController : UITableViewController
@end

@implementation XLiquidGlassBeta6ProbeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"Beta 6.9 Swift Symbol Probe";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return @"O probe enumera somente leitura os símbolos Swift de T1Twitter e XServiceLibraries para localizar quem produz descriptors, tabIdentifiers e o XTabbedAppNavigation antes do Dock.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier=@"XLGB6ProbeCell";
    UITableViewCell *cell=
        [tableView dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {
        cell=[[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
          reuseIdentifier:identifier];
    }

    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;

    if (indexPath.row==0) {
        cell.textLabel.text=@"Captura completa";
        cell.detailTextLabel.text=@"Registra o estado atual do Dock.";
    } else if (indexPath.row==1) {
        cell.textLabel.text=@"Copiar relatório";
        cell.detailTextLabel.text=@"XLiquidGlass193Beta69SwiftSymbolSourceProbe.log";
    } else {
        cell.textLabel.text=@"Limpar relatório";
        cell.detailTextLabel.text=@"Remove o relatório anterior.";
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.row==0) {
        XLGB6ProbeSnapshot(@"manual-NFB");
        UIAlertController *alert=
            [UIAlertController
                alertControllerWithTitle:@"Beta 6.9 Swift Symbol Probe"
                                 message:@"Captura completa adicionada ao relatório."
                          preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    if (indexPath.row==1) {
        // Add a fresh snapshot immediately before copying so the pasted report
        // always contains the current visible state.
        XLGB6ProbeSnapshot(@"copy-NFB");

        NSString *report=
            [NSString stringWithContentsOfFile:XLGB6LogPath()
                                      encoding:NSUTF8StringEncoding
                                         error:nil] ?: @"";

        UIPasteboard.generalPasteboard.string=report;

        UIAlertController *alert=
            [UIAlertController
                alertControllerWithTitle:@"Beta 6.9 Swift Symbol Probe"
                                 message:
                    [NSString stringWithFormat:
                        @"Relatório copiado (%lu caracteres).",
                        (unsigned long)report.length]
                          preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [[NSFileManager defaultManager]
        removeItemAtPath:XLGB6LogPath()
                   error:nil];
    XLGB6Log(@"========== LOG RESET FROM NFB ==========");

    UIAlertController *alert=
        [UIAlertController
            alertControllerWithTitle:@"Beta 6.9 Swift Symbol Probe"
                             message:@"Relatório limpo."
                      preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:
        [UIAlertAction actionWithTitle:@"OK"
                                 style:UIAlertActionStyleDefault
                               handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

static void XLGB6InjectNFBProbeEntry(id controller) {
    NSArray *sections=XLGArrayForKey(controller,@"sections");
    if (!sections) return;

    if (XLGArrayContainsAction(
            sections,@"showXLiquidGlassBeta6Probe")) {
        return;
    }

    NSMutableArray *updated=[sections mutableCopy];
    [updated addObject:@{
        @"title": @"Beta 6.9 Swift Symbol Probe",
        @"subtitle": @"Diagnóstico read-only da fonte nativa do Dock.",
        @"icon": @"flask",
        @"action": @"showXLiquidGlassBeta6Probe"
    }];

    XLGSetArrayForKey(controller,@"sections",[updated copy]);
}

static void XLGB6ShowProbeSettings(id self, SEL cmd) {
    (void)cmd;
    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassBeta6ProbeViewController *vc=
        [XLiquidGlassBeta6ProbeViewController new];

    UINavigationController *navigation=
        ((UIViewController *)self).navigationController;

    if (navigation) {
        [navigation pushViewController:vc animated:YES];
    } else {
        UINavigationController *wrapper=
            [[UINavigationController alloc]
                initWithRootViewController:vc];
        [(UIViewController *)self
            presentViewController:wrapper
                         animated:YES
                       completion:nil];
    }
}


static NSString *XLGNormalizedUserID(id value) {
    if (!value || value == NSNull.null) return nil;
    if ([value isKindOfClass:NSString.class]) {
        return [(NSString *)value length] ? value : nil;
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *string = [value stringValue];
        return string.length ? string : nil;
    }
    NSString *string = [value description];
    return string.length ? string : nil;
}

static NSString *XLGTryResolveUserID(id object, NSUInteger depth) {
    if (!object || depth > 2) return nil;

    for (NSString *key in @[@"userID", @"userId", @"restID", @"restId",
                             @"accountID", @"accountId", @"activeUserID",
                             @"activeAccountID", @"currentUserID",
                             @"currentAccountID"]) {
        NSString *resolved = XLGNormalizedUserID(XLGSafeValueForKey(object, key));
        if (resolved.length) return resolved;
    }

    for (NSString *key in @[@"account", @"currentAccount", @"activeAccount"]) {
        id nested = XLGSafeValueForKey(object, key);
        if (!nested || nested == object) continue;
        NSString *resolved = XLGTryResolveUserID(nested, depth + 1);
        if (resolved.length) return resolved;
    }

    return nil;
}

static NSString *XLGUserIDFromNotification(id argument) {
    if (![argument isKindOfClass:NSNotification.class]) return nil;
    NSNotification *notification = (NSNotification *)argument;
    return XLGTryResolveUserID(notification.object, 0);
}

static NSString *XLGCurrentUserIDFromAppEventHandler(id handler) {
    if (!handler) return nil;

    SEL currentUserIDSEL = NSSelectorFromString(@"_t1_currentUserID");
    if ([handler respondsToSelector:currentUserIDSEL]) {
        id value = ((id(*)(id,SEL))objc_msgSend)(handler, currentUserIDSEL);
        NSString *userID = XLGNormalizedUserID(value);
        if (userID.length) return userID;
    }

    SEL currentAccountSEL = NSSelectorFromString(@"_t1_currentAccount");
    if ([handler respondsToSelector:currentAccountSEL]) {
        id account = ((id(*)(id,SEL))objc_msgSend)(handler, currentAccountSEL);
        NSString *userID = XLGTryResolveUserID(account, 0);
        if (userID.length) return userID;
    }

    return nil;
}

static NSDictionary *XLGBadgeStateForUserID(NSString *userID);

static NSString *XLGCurrentActiveUserID(void) {
    // Beta 7: the account represented by the visible XNavigation/appNavigation
    // is authoritative. T1AppBadging is global and can update background
    // accounts, so it must never steal badge ownership from the visible bar.
    id account = XLGSidebarCurrentAccount();
    NSString *navigationUserID = XLGTryResolveUserID(account, 0);
    if (navigationUserID.length &&
        XLGBadgeStateForUserID(navigationUserID)) {
        if (![gXLGBadgeActiveUserID isEqualToString:navigationUserID]) {
            XLGDiagLog(@"OWNER navigation=%@ previous=%@ action=promote-navigation",
                  navigationUserID,
                  gXLGBadgeActiveUserID ?: @"-");
            gXLGBadgeActiveUserID = [navigationUserID copy];
        }
        return navigationUserID;
    }

    // Lifecycle ownership remains the fallback for startup/transitional frames
    // where appNavigation has not exposed an account yet.
    if (gXLGBadgeActiveUserID.length &&
        XLGBadgeStateForUserID(gXLGBadgeActiveUserID)) {
        return gXLGBadgeActiveUserID;
    }

    return gXLGBadgeActiveUserID.length ? gXLGBadgeActiveUserID : nil;
}

static BOOL XLGReadIntegerGetter(id object, NSString *selectorName, NSInteger *valueOut) {
    if (!object || !selectorName.length || !valueOut) return NO;

    SEL selector = NSSelectorFromString(selectorName);
    if ([object respondsToSelector:selector]) {
        NSMethodSignature *signature = [object methodSignatureForSelector:selector];
        const char *ret = signature.methodReturnType;
        if (ret) {
            switch (ret[0]) {
                case '@': {
                    id value = ((id(*)(id,SEL))objc_msgSend)(object, selector);
                    if ([value respondsToSelector:@selector(integerValue)]) {
                        *valueOut = [value integerValue];
                        return YES;
                    }
                    break;
                }
                case 'q':
                    *valueOut = (NSInteger)((long long(*)(id,SEL))objc_msgSend)(object, selector);
                    return YES;
                case 'Q':
                    *valueOut = (NSInteger)((unsigned long long(*)(id,SEL))objc_msgSend)(object, selector);
                    return YES;
                case 'i':
                    *valueOut = (NSInteger)((int(*)(id,SEL))objc_msgSend)(object, selector);
                    return YES;
                case 'I':
                    *valueOut = (NSInteger)((unsigned int(*)(id,SEL))objc_msgSend)(object, selector);
                    return YES;
                default:
                    break;
            }
        }
    }

    id value = XLGSafeValueForKey(object, selectorName);
    if ([value respondsToSelector:@selector(integerValue)]) {
        *valueOut = [value integerValue];
        return YES;
    }
    return NO;
}

static BOOL XLGReadCountField(id object, NSString *baseName, NSInteger *valueOut) {
    if (XLGReadIntegerGetter(object,
                             [baseName stringByAppendingString:@"Number"],
                             valueOut)) {
        return YES;
    }
    return XLGReadIntegerGetter(object, baseName, valueOut);
}

static BOOL XLGReadFirstCountField(id object,
                                   NSArray<NSString *> *baseNames,
                                   NSInteger *valueOut) {
    for (NSString *baseName in baseNames) {
        if (XLGReadCountField(object, baseName, valueOut)) return YES;
    }
    return NO;
}

static BOOL XLGReadNTabCount(id object, NSInteger *valueOut) {
    return XLGReadFirstCountField(object,
                                  @[@"ntabUnreadCount",
                                    @"notificationTabUnreadCount",
                                    @"notificationsUnreadCount",
                                    @"notificationUnreadCount",
                                    @"activityUnreadCount",
                                    @"notificationBadgeCount"],
                                  valueOut);
}

static BOOL XLGReadDMCount(id object, NSInteger *valueOut) {
    return XLGReadFirstCountField(object,
                                  @[@"dmUnreadCount",
                                    @"directMessageUnreadCount",
                                    @"directMessagesUnreadCount",
                                    @"messagesUnreadCount"],
                                  valueOut);
}

static BOOL XLGReadXChatCount(id object, NSInteger *valueOut) {
    return XLGReadFirstCountField(object,
                                  @[@"xchatUnreadCount",
                                    @"xChatUnreadCount",
                                    @"xchatBadgeCount"],
                                  valueOut);
}

static BOOL XLGReadTotalCount(id object, NSInteger *valueOut) {
    return XLGReadFirstCountField(object,
                                  @[@"totalUnreadCount",
                                    @"totalBadgeCount"],
                                  valueOut);
}

static NSString *XLGBadgeDefaultsKey(NSString *name) {
    return [kXLGBadgePrefix stringByAppendingString:name];
}

static NSMutableDictionary *XLGNewEmptyBadgeState(void) {
    return [@{
        @"ntab": @(-1),
        @"dm": @(-1),
        @"xchat": @(-1),
        @"total": @(-1),
        @"timestamp": @(NSDate.date.timeIntervalSince1970)
    } mutableCopy];
}

static NSInteger XLGStateInteger(NSDictionary *state,
                                 NSString *key,
                                 NSInteger fallback) {
    id value = state[key];
    return [value respondsToSelector:@selector(integerValue)]
        ? [value integerValue]
        : fallback;
}

static NSMutableDictionary *XLGMutableBadgeStateForUserID(NSString *userID,
                                                           BOOL create) {
    if (!userID.length) return nil;
    if (!gXLGBadgeStateByUserID) {
        gXLGBadgeStateByUserID = [NSMutableDictionary dictionary];
    }

    NSMutableDictionary *state = gXLGBadgeStateByUserID[userID];
    if (!state && create) {
        state = XLGNewEmptyBadgeState();
        gXLGBadgeStateByUserID[userID] = state;
    }
    return state;
}

static NSDictionary *XLGBadgeStateForUserID(NSString *userID) {
    if (!userID.length) return nil;
    return XLGMutableBadgeStateForUserID(userID, NO);
}

static NSMutableDictionary *XLGSourceStateForUserID(NSString *userID,
                                                     BOOL create) {
    if (!userID.length) return nil;
    if (!gXLGBadgeSourceStateByUserID) {
        gXLGBadgeSourceStateByUserID = [NSMutableDictionary dictionary];
    }

    NSMutableDictionary *state = gXLGBadgeSourceStateByUserID[userID];
    if (!state && create) {
        state = [NSMutableDictionary dictionary];
        gXLGBadgeSourceStateByUserID[userID] = state;
    }
    return state;
}

static BOOL XLGNotificationsRecentlyViewedForUserID(
    NSString *userID,
    NSTimeInterval *ageOut) {
    if (ageOut) *ageOut=DBL_MAX;
    if (!userID.length) return NO;

    NSDictionary *source=XLGSourceStateForUserID(userID,NO);
    NSTimeInterval timestamp=
        [source[@"notificationsViewedTimestamp"]
            respondsToSelector:@selector(doubleValue)]
            ? [source[@"notificationsViewedTimestamp"] doubleValue]
            : 0;
    if (timestamp<=0) return NO;

    NSTimeInterval age=NSDate.date.timeIntervalSince1970-timestamp;
    if (ageOut) *ageOut=age;
    return age>=0 && age<=kXLGNotificationsViewedGraceWindow;
}

static void XLGMarkNotificationsViewedAndClearBadge(NSString *userID) {
    if (!userID.length) return;

    NSString *active=XLGCurrentActiveUserID();
    if (active.length && ![active isEqualToString:userID]) return;

    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    NSMutableDictionary *source=XLGSourceStateForUserID(userID,YES);
    source[@"notificationsViewedTimestamp"]=@(now);

    // The notifications screen is now visible for this exact account.
    // A following zero is a legitimate "seen" transition, not startup noise.
    source[@"trustedNotifications"]=@NO;
    source[@"trustedTimestamp"]=@0;
    source[@"startupHold"]=@NO;
    source[@"directSourceSeen"]=@YES;

    NSMutableDictionary *state=XLGMutableBadgeStateForUserID(userID,YES);
    NSInteger dm=XLGStateInteger(state,@"dm",0);
    NSInteger xchat=XLGStateInteger(state,@"xchat",0);
    NSInteger chat=xchat>0 ? xchat : MAX((NSInteger)0,dm);

    // Clear only notifications. Preserve the active account's chat badge.
    state[@"ntab"]=@0;
    state[@"total"]=@(MAX((NSInteger)0,chat));
    state[@"timestamp"]=@(now);

    // Also retire the stale notification-only authoritative snapshot so it
    // cannot immediately recreate the badge during the read transition.
    source[@"remoteNtab"]=@0;
    source[@"remoteTotal"]=@(MAX((NSInteger)0,chat));
    source[@"remoteTimestamp"]=@(now);

    XLGPersistBadgeStates();
    XLGRefreshGlobalTabBar();

    // Liquid Glass can rebuild the tab bar just after viewDidAppear:.
    for (NSNumber *delayNumber in @[@0.08,@0.30]) {
        NSTimeInterval delay=delayNumber.doubleValue;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay*NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                XLGRefreshGlobalTabBar();
            });
    }
}

static NSInteger XLGIntegerFromObjectPointer(uintptr_t raw,
                                             NSInteger fallback) {
    if (!raw) return fallback;
    id value = (__bridge id)((void *)raw);
    return [value respondsToSelector:@selector(integerValue)]
        ? [value integerValue]
        : fallback;
}

static BOOL XLGRemoteSourceLooksLikeNotificationsOnly(NSDictionary *state) {
    if (!state) return NO;
    NSInteger ntab = XLGStateInteger(state, @"remoteNtab", -1);
    NSInteger dm = XLGStateInteger(state, @"remoteDM", -1);
    NSInteger xchat = XLGStateInteger(state, @"remoteXChat", -1);
    NSInteger total = XLGStateInteger(state, @"remoteTotal", -1);
    return ntab > 0 && dm == 0 && xchat == 0 && total == ntab;
}

static void XLGSetTrustedNotificationSource(NSString *userID,
                                            BOOL trusted,
                                            NSString *reason) {
    NSMutableDictionary *state = XLGSourceStateForUserID(userID, YES);
    BOOL wasTrusted = [state[@"trustedNotifications"] boolValue];
    if (trusted) {
        state[@"trustedNotifications"] = @YES;
        state[@"trustedTimestamp"] = @(NSDate.date.timeIntervalSince1970);
        if (!wasTrusted) {
            XLGDiagLog(@"TRUST_SET user=%@ reason=%@ ntab=%ld dm=%ld xchat=%ld total=%ld localDM=%ld localXChat=%ld",
                           userID,
                           reason ?: @"-",
                           (long)XLGStateInteger(state, @"remoteNtab", -1),
                           (long)XLGStateInteger(state, @"remoteDM", -1),
                           (long)XLGStateInteger(state, @"remoteXChat", -1),
                           (long)XLGStateInteger(state, @"remoteTotal", -1),
                           (long)XLGStateInteger(state, @"localDM", -1),
                           (long)XLGStateInteger(state, @"localXChat", -1));
        }
    } else {
        state[@"trustedNotifications"] = @NO;
        if (wasTrusted) {
            XLGDiagLog(@"TRUST_INVALIDATED user=%@ reason=%@ remote(ntab=%ld dm=%ld xchat=%ld total=%ld) localDM=%ld localXChat=%ld",
                           userID,
                           reason ?: @"-",
                           (long)XLGStateInteger(state, @"remoteNtab", -1),
                           (long)XLGStateInteger(state, @"remoteDM", -1),
                           (long)XLGStateInteger(state, @"remoteXChat", -1),
                           (long)XLGStateInteger(state, @"remoteTotal", -1),
                           (long)XLGStateInteger(state, @"localDM", -1),
                           (long)XLGStateInteger(state, @"localXChat", -1));
        }
    }
}

static void XLGEvaluateTrustedNotificationSource(NSString *userID,
                                                  NSString *reason) {
    NSMutableDictionary *state = XLGSourceStateForUserID(userID, NO);
    if (!state) return;

    NSTimeInterval viewedAge=DBL_MAX;
    if (XLGNotificationsRecentlyViewedForUserID(userID,&viewedAge)) {
        XLGSetTrustedNotificationSource(
            userID,
            NO,
            @"notifications-recently-viewed");
        return;
    }

    BOOL remoteGood = XLGRemoteSourceLooksLikeNotificationsOnly(state);
    NSInteger localDM = XLGStateInteger(state, @"localDM", -1);
    NSInteger localXChat = XLGStateInteger(state, @"localXChat", -1);

    // X 12.28.1 may never call the XChat setter in sessions where XChat is
    // unused. Treat "unknown" as acceptable, but any positive local chat count
    // invalidates notification-only trust.
    BOOL localGood = localDM == 0 && localXChat <= 0;

    XLGSetTrustedNotificationSource(userID,
                                    remoteGood && localGood,
                                    reason);
}

static void XLGRememberRemoteBadgeSource(NSString *userID,
                                         uintptr_t ntabRaw,
                                         uintptr_t dmRaw,
                                         uintptr_t xchatRaw,
                                         uintptr_t totalRaw) {
    if (!userID.length) return;

    NSInteger ntab = XLGIntegerFromObjectPointer(ntabRaw, -1);
    NSInteger dm = XLGIntegerFromObjectPointer(dmRaw, -1);
    NSInteger xchat = XLGIntegerFromObjectPointer(xchatRaw, -1);
    NSInteger total = XLGIntegerFromObjectPointer(totalRaw, -1);
    if (ntab < 0 && dm < 0 && xchat < 0 && total < 0) return;

    NSMutableDictionary *state = XLGSourceStateForUserID(userID, YES);
    state[@"remoteNtab"] = @(MAX((NSInteger)0, ntab));
    state[@"remoteDM"] = @(MAX((NSInteger)0, dm));
    state[@"remoteXChat"] = @(MAX((NSInteger)0, xchat));
    state[@"remoteTotal"] = @(MAX((NSInteger)0, total));
    state[@"remoteTimestamp"] = @(NSDate.date.timeIntervalSince1970);

    XLGResolveStartupHoldWithRemote(
        userID,
        MAX((NSInteger)0, ntab),
        MAX((NSInteger)0, dm),
        MAX((NSInteger)0, xchat),
        MAX((NSInteger)0, total));

    XLGDiagLog(@"RECONCILE_SOURCE user=%@ remote ntab=%ld dm=%ld xchat=%ld total=%ld",
                   userID,
                   (long)MAX((NSInteger)0, ntab),
                   (long)MAX((NSInteger)0, dm),
                   (long)MAX((NSInteger)0, xchat),
                   (long)MAX((NSInteger)0, total));

    // A direct remote source supersedes any previous trust. Positive
    // notifications-only data can re-establish trust immediately if local DM
    // is already known to be zero; a direct zero or different category clears it.
    XLGEvaluateTrustedNotificationSource(userID, @"remote-source-update");
}

static void XLGRememberLocalDMSource(unsigned long long userID,
                                     NSInteger count) {
    NSString *key = [@(userID) stringValue];
    NSMutableDictionary *state = XLGSourceStateForUserID(key, YES);
    state[@"localDM"] = @(MAX((NSInteger)0, count));
    state[@"localDMTimestamp"] = @(NSDate.date.timeIntervalSince1970);
    XLGDiagLog(@"RECONCILE_SOURCE user=%@ localDM=%ld",
                   key,
                   (long)MAX((NSInteger)0, count));
    XLGEvaluateTrustedNotificationSource(
        key,
        count == 0 ? @"local-dm-zero" : @"local-dm-nonzero");
}

static void XLGRememberLocalXChatSource(unsigned long long userID,
                                        NSInteger count) {
    NSString *key = [@(userID) stringValue];
    NSMutableDictionary *state = XLGSourceStateForUserID(key, YES);
    state[@"localXChat"] = @(MAX((NSInteger)0, count));
    state[@"localXChatTimestamp"] = @(NSDate.date.timeIntervalSince1970);
    XLGDiagLog(@"RECONCILE_SOURCE user=%@ localXChat=%ld",
                   key,
                   (long)MAX((NSInteger)0, count));
    XLGEvaluateTrustedNotificationSource(
        key,
        count == 0 ? @"local-xchat-zero" : @"local-xchat-nonzero");
}

static BOOL XLGNormalizeBadgeMapForKnownNtabMisroute(
    NSString *userID,
    BOOL hasNtab, NSInteger *ntab,
    BOOL hasDM, NSInteger *dm,
    BOOL hasXChat, NSInteger *xchat,
    BOOL hasTotal, NSInteger *total) {

    if (!userID.length || !hasNtab || !hasDM || !hasXChat || !hasTotal ||
        !ntab || !dm || !xchat || !total) {
        return NO;
    }

    if (XLGApplyStartupHoldIfNeeded(
            userID,
            hasNtab, ntab,
            hasDM, dm,
            hasXChat, xchat,
            hasTotal, total)) {
        return YES;
    }

    NSDictionary *source = XLGSourceStateForUserID(userID, NO);
    if (!source) return NO;

    NSInteger remoteNtab = XLGStateInteger(source, @"remoteNtab", -1);
    NSInteger remoteDM = XLGStateInteger(source, @"remoteDM", -1);
    NSInteger remoteXChat = XLGStateInteger(source, @"remoteXChat", -1);
    NSInteger remoteTotal = XLGStateInteger(source, @"remoteTotal", -1);
    NSInteger localDM = XLGStateInteger(source, @"localDM", -1);
    BOOL trusted = [source[@"trustedNotifications"] boolValue];

    NSInteger rawNtab = MAX((NSInteger)0, *ntab);
    NSInteger rawDM = MAX((NSInteger)0, *dm);
    NSInteger rawXChat = MAX((NSInteger)0, *xchat);
    NSInteger rawTotal = MAX((NSInteger)0, *total);

    BOOL rawMisroute =
        rawNtab == 0 &&
        rawDM == remoteNtab &&
        rawXChat == 0 &&
        rawTotal == remoteTotal &&
        remoteNtab > 0;

    BOOL rawZero =
        rawNtab == 0 &&
        rawDM == 0 &&
        rawXChat == 0 &&
        rawTotal == 0;

    // 1.9.1 Beta 2: mirror the native T1TabView badge signal during the
    // short interval before AccountBadgesDidChange catches up. The native
    // classic tab receives the same visible count immediately, even while
    // Liquid Glass is rendering XNavigation.TabBarItemView.
    NSTimeInterval nativeNow=NSDate.date.timeIntervalSince1970;
    NSTimeInterval nativeNtabTimestamp=
        [source[@"nativeNtabTimestamp"] respondsToSelector:@selector(doubleValue)]
            ? [source[@"nativeNtabTimestamp"] doubleValue] : 0;
    NSTimeInterval nativeChatTimestamp=
        [source[@"nativeChatTimestamp"] respondsToSelector:@selector(doubleValue)]
            ? [source[@"nativeChatTimestamp"] doubleValue] : 0;
    NSTimeInterval nativeNtabAge=
        nativeNtabTimestamp>0 ? nativeNow-nativeNtabTimestamp : DBL_MAX;
    NSTimeInterval nativeChatAge=
        nativeChatTimestamp>0 ? nativeNow-nativeChatTimestamp : DBL_MAX;
    BOOL nativeNtabFresh=
        nativeNtabAge>=0 &&
        nativeNtabAge<=kXLGNativeBadgeSignalGraceWindow &&
        [source[@"nativeNtab"] respondsToSelector:@selector(integerValue)];
    BOOL nativeChatFresh=
        nativeChatAge>=0 &&
        nativeChatAge<=kXLGNativeBadgeSignalGraceWindow &&
        [source[@"nativeChat"] respondsToSelector:@selector(integerValue)];

    if (nativeNtabFresh || nativeChatFresh) {
        NSDictionary *cached=XLGBadgeStateForUserID(userID);
        NSInteger cachedDM=XLGStateInteger(cached,@"dm",0);
        NSInteger cachedXChat=XLGStateInteger(cached,@"xchat",0);
        NSInteger cachedChat=
            cachedXChat>0 ? cachedXChat : MAX((NSInteger)0,cachedDM);
        NSInteger cachedNotifications=
            XLGNotificationDisplayCountForState(cached);
        if (cachedNotifications<0) cachedNotifications=0;

        NSInteger effectiveNtab=
            nativeNtabFresh
                ? MAX((NSInteger)0,[source[@"nativeNtab"] integerValue])
                : MAX((NSInteger)0,rawNtab);
        NSInteger effectiveChat=
            nativeChatFresh
                ? MAX((NSInteger)0,[source[@"nativeChat"] integerValue])
                : MAX((NSInteger)0,cachedChat);

        *ntab=effectiveNtab;
        if (nativeChatFresh) {
            *dm=effectiveChat;
            *xchat=effectiveChat;
        } else {
            *dm=MAX((NSInteger)0,cachedDM);
            *xchat=MAX((NSInteger)0,cachedXChat);
        }
        *total=MAX((NSInteger)0,effectiveNtab+effectiveChat);

        XLGDiagLog(
            @"NATIVE_BADGE_GRACE user=%@ ntabFresh=%@ chatFresh=%@ nativeNtabAge=%.3f nativeChatAge=%.3f -> ntab=%ld dm=%ld xchat=%ld total=%ld cachedNotifications=%ld",
            userID,
            nativeNtabFresh ? @"YES" : @"NO",
            nativeChatFresh ? @"YES" : @"NO",
            nativeNtabAge,
            nativeChatAge,
            (long)*ntab,
            (long)*dm,
            (long)*xchat,
            (long)*total,
            (long)cachedNotifications);
        return YES;
    }

    NSTimeInterval viewedAge=DBL_MAX;
    BOOL recentlyViewed=
        XLGNotificationsRecentlyViewedForUserID(userID,&viewedAge);

    if (recentlyViewed && (rawZero || rawMisroute)) {
        NSDictionary *cached=XLGBadgeStateForUserID(userID);
        NSInteger cachedDM=XLGStateInteger(cached,@"dm",0);
        NSInteger cachedXChat=XLGStateInteger(cached,@"xchat",0);
        NSInteger cachedChat=
            cachedXChat>0 ? cachedXChat : MAX((NSInteger)0,cachedDM);

        *ntab=0;
        *dm=MAX((NSInteger)0,cachedDM);
        *xchat=MAX((NSInteger)0,cachedXChat);
        *total=MAX((NSInteger)0,cachedChat);

        NSMutableDictionary *mutableSource=
            XLGSourceStateForUserID(userID,YES);
        mutableSource[@"trustedNotifications"]=@NO;
        mutableSource[@"remoteNtab"]=@0;
        mutableSource[@"remoteTotal"]=@(MAX((NSInteger)0,cachedChat));

        XLGDiagLog(
            @"ACCEPT_READ_ZERO user=%@ age=%.3f raw(ntab=%ld dm=%ld xchat=%ld total=%ld) -> ntab=0 dm=%ld xchat=%ld total=%ld",
            userID,
            viewedAge,
            (long)rawNtab,
            (long)rawDM,
            (long)rawXChat,
            (long)rawTotal,
            (long)*dm,
            (long)*xchat,
            (long)*total);
        return YES;
    }

    // 1.9.1 Beta 4: the timing probe proved that the authoritative
    // TFNTwitterAccount callback can be followed 10-20 ms later by two broken
    // aggregate maps: first ntab->dm, then all zero. During that tiny window,
    // prefer the exact positive notification-only remote tuple even if the
    // local DM setter has not run recently. A real read is handled above by
    // XLGNotificationsRecentlyViewedForUserID.
    NSTimeInterval directNow=NSDate.date.timeIntervalSince1970;
    NSTimeInterval directRemoteTimestamp=
        [source[@"remoteTimestamp"] respondsToSelector:@selector(doubleValue)]
            ? [source[@"remoteTimestamp"] doubleValue] : 0;
    NSTimeInterval directRemoteAge=
        directRemoteTimestamp>0
            ? directNow-directRemoteTimestamp
            : DBL_MAX;
    BOOL directRemoteFresh=
        directRemoteAge>=0 &&
        directRemoteAge<=kXLGDirectRemoteAuthorityWindow;
    BOOL directRemoteNotificationOnly=
        remoteNtab>0 &&
        remoteDM==0 &&
        remoteXChat==0 &&
        remoteTotal==remoteNtab;

    if (directRemoteFresh &&
        directRemoteNotificationOnly &&
        (rawMisroute || rawZero)) {
        *ntab=remoteNtab;
        *dm=0;
        *xchat=0;
        *total=remoteTotal;

        XLGDiagLog(
            @"PRESERVE_FRESH_DIRECT_REMOTE user=%@ age=%.3f raw(ntab=%ld dm=%ld xchat=%ld total=%ld) -> ntab=%ld dm=0 xchat=0 total=%ld",
            userID,
            directRemoteAge,
            (long)rawNtab,
            (long)rawDM,
            (long)rawXChat,
            (long)rawTotal,
            (long)remoteNtab,
            (long)remoteTotal);
        return YES;
    }

    // Final: once direct TFNTwitterAccount + local DM establish a trusted
    // notifications-only state, aggregate AccountBadgesDidChange maps are not
    // allowed to erase or relabel it. Trust has no arbitrary time expiry; only
    // a new direct source/local category update can invalidate it.
    if (trusted &&
        XLGRemoteSourceLooksLikeNotificationsOnly(source) &&
        localDM == 0 &&
        (rawMisroute || rawZero)) {

        NSString *active = XLGCurrentActiveUserID();
        NSString *reason = rawMisroute
            ? @"trusted-ntab-misroute"
            : ([active isEqualToString:userID]
                ? @"trusted-zero-active-no-new-source"
                : @"trusted-zero-inactive-account");

        XLGDiagLog(@"PRESERVE_TRUSTED user=%@ reason=%@ active=%@ raw(ntab=%ld dm=%ld xchat=%ld total=%ld) trusted(ntab=%ld dm=%ld xchat=%ld total=%ld) -> keep(ntab=%ld dm=0 xchat=0 total=%ld)",
                       userID,
                       reason,
                       active ?: @"-",
                       (long)rawNtab,
                       (long)rawDM,
                       (long)rawXChat,
                       (long)rawTotal,
                       (long)remoteNtab,
                       (long)remoteDM,
                       (long)remoteXChat,
                       (long)remoteTotal,
                       (long)remoteNtab,
                       (long)remoteTotal);

        *ntab = remoteNtab;
        *dm = 0;
        *xchat = 0;
        *total = remoteTotal;
        return YES;
    }

    // Beta 10 short-window fallback remains for the brief interval before the
    // persistent trust lock is fully established.
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval remoteTimestamp =
        [source[@"remoteTimestamp"] respondsToSelector:@selector(doubleValue)]
            ? [source[@"remoteTimestamp"] doubleValue]
            : 0;
    NSTimeInterval remoteAge =
        remoteTimestamp > 0 ? now - remoteTimestamp : DBL_MAX;

    NSTimeInterval localDMTimestamp =
        [source[@"localDMTimestamp"] respondsToSelector:@selector(doubleValue)]
            ? [source[@"localDMTimestamp"] doubleValue]
            : 0;
    NSTimeInterval localDMAge =
        localDMTimestamp > 0 ? now - localDMTimestamp : DBL_MAX;

    if (remoteAge < 0 || remoteAge > kXLGBadgeReconcileWindow ||
        remoteNtab <= 0 ||
        remoteDM != 0 ||
        remoteXChat != 0 ||
        remoteTotal != remoteNtab ||
        localDM != 0 ||
        localDMAge < 0 ||
        localDMAge > kXLGBadgeReconcileWindow ||
        (!rawMisroute && !rawZero)) {
        return NO;
    }

    NSString *reason = rawMisroute
        ? @"ntab-misrouted-to-dm"
        : @"transient-zero-after-remote";

    XLGDiagLog(@"NORMALIZE user=%@ reason=%@ age=%.3f localDMAge=%.3f raw(ntab=%ld dm=%ld xchat=%ld total=%ld) remote(ntab=%ld dm=%ld xchat=%ld total=%ld) localDM=%ld -> normalized(ntab=%ld dm=0 xchat=0 total=%ld)",
                   userID,
                   reason,
                   remoteAge,
                   localDMAge,
                   (long)rawNtab,
                   (long)rawDM,
                   (long)rawXChat,
                   (long)rawTotal,
                   (long)remoteNtab,
                   (long)remoteDM,
                   (long)remoteXChat,
                   (long)remoteTotal,
                   (long)localDM,
                   (long)remoteNtab,
                   (long)remoteTotal);

    *ntab = remoteNtab;
    *dm = 0;
    *xchat = 0;
    *total = remoteTotal;
    return YES;
}

static void XLGPersistBadgeStates(void) {
    if (!gXLGBadgeStateByUserID) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:gXLGBadgeStateByUserID forKey:kXLGBadgeAccountsKey];
    if (gXLGBadgeActiveUserID.length) {
        [defaults setObject:gXLGBadgeActiveUserID
                    forKey:XLGBadgeDefaultsKey(@"lastActiveUserID")];
    }
}

static void XLGArmStartupHoldForPersistedState(
    NSString *userID,
    NSDictionary *persistedState) {
    if (!userID.length || !persistedState) return;

    NSInteger ntab = XLGStateInteger(persistedState, @"ntab", -1);
    NSInteger dm = XLGStateInteger(persistedState, @"dm", -1);
    NSInteger xchat = XLGStateInteger(persistedState, @"xchat", -1);
    NSInteger total = XLGStateInteger(persistedState, @"total", -1);

    BOOL hasPositive =
        ntab > 0 || dm > 0 || xchat > 0 || total > 0;
    if (!hasPositive) return;

    NSMutableDictionary *source = XLGSourceStateForUserID(userID, YES);
    source[@"startupHold"] = @YES;
    source[@"directSourceSeen"] = @NO;
    source[@"startupPersistedNtab"] = @(MAX((NSInteger)0, ntab));
    source[@"startupPersistedDM"] = @(MAX((NSInteger)0, dm));
    source[@"startupPersistedXChat"] = @(MAX((NSInteger)0, xchat));
    source[@"startupPersistedTotal"] = @(MAX((NSInteger)0, total));
    source[@"startupHoldTimestamp"] = @(NSDate.date.timeIntervalSince1970);

    XLGDiagLog(@"STARTUP_ARM user=%@ persisted(ntab=%ld dm=%ld xchat=%ld total=%ld)",
                   userID,
                   (long)MAX((NSInteger)0, ntab),
                   (long)MAX((NSInteger)0, dm),
                   (long)MAX((NSInteger)0, xchat),
                   (long)MAX((NSInteger)0, total));
}

static BOOL XLGApplyStartupHoldIfNeeded(
    NSString *userID,
    BOOL hasNtab, NSInteger *ntab,
    BOOL hasDM, NSInteger *dm,
    BOOL hasXChat, NSInteger *xchat,
    BOOL hasTotal, NSInteger *total) {

    if (!userID.length || !hasNtab || !hasDM || !hasXChat || !hasTotal ||
        !ntab || !dm || !xchat || !total) {
        return NO;
    }

    NSDictionary *source = XLGSourceStateForUserID(userID, NO);
    if (![source[@"startupHold"] boolValue] ||
        [source[@"directSourceSeen"] boolValue]) {
        return NO;
    }

    NSInteger rawNtab = MAX((NSInteger)0, *ntab);
    NSInteger rawDM = MAX((NSInteger)0, *dm);
    NSInteger rawXChat = MAX((NSInteger)0, *xchat);
    NSInteger rawTotal = MAX((NSInteger)0, *total);

    // Startup protection is intentionally narrower than the later trust logic:
    // only an all-zero aggregate map is held while no direct TFNTwitterAccount
    // source has answered in this process.
    if (rawNtab != 0 || rawDM != 0 || rawXChat != 0 || rawTotal != 0) {
        return NO;
    }

    NSInteger persistedNtab =
        XLGStateInteger(source, @"startupPersistedNtab", 0);
    NSInteger persistedDM =
        XLGStateInteger(source, @"startupPersistedDM", 0);
    NSInteger persistedXChat =
        XLGStateInteger(source, @"startupPersistedXChat", 0);
    NSInteger persistedTotal =
        XLGStateInteger(source, @"startupPersistedTotal", 0);

    if (persistedNtab <= 0 &&
        persistedDM <= 0 &&
        persistedXChat <= 0 &&
        persistedTotal <= 0) {
        return NO;
    }

    XLGDiagLog(@"STARTUP_HOLD user=%@ raw(0/0/0/0) persisted(ntab=%ld dm=%ld xchat=%ld total=%ld) reason=waiting-direct-source",
                   userID,
                   (long)persistedNtab,
                   (long)persistedDM,
                   (long)persistedXChat,
                   (long)persistedTotal);

    *ntab = persistedNtab;
    *dm = persistedDM;
    *xchat = persistedXChat;
    *total = persistedTotal;
    return YES;
}

static void XLGResolveStartupHoldWithRemote(
    NSString *userID,
    NSInteger remoteNtab,
    NSInteger remoteDM,
    NSInteger remoteXChat,
    NSInteger remoteTotal) {
    if (!userID.length) return;

    NSMutableDictionary *source = XLGSourceStateForUserID(userID, YES);
    BOOL wasHolding = [source[@"startupHold"] boolValue] &&
                      ![source[@"directSourceSeen"] boolValue];

    source[@"directSourceSeen"] = @YES;
    source[@"startupHold"] = @NO;

    if (!wasHolding) return;

    NSInteger persistedNtab =
        XLGStateInteger(source, @"startupPersistedNtab", 0);
    NSInteger persistedDM =
        XLGStateInteger(source, @"startupPersistedDM", 0);
    NSInteger persistedXChat =
        XLGStateInteger(source, @"startupPersistedXChat", 0);
    NSInteger persistedTotal =
        XLGStateInteger(source, @"startupPersistedTotal", 0);

    BOOL same =
        remoteNtab == persistedNtab &&
        remoteDM == persistedDM &&
        remoteXChat == persistedXChat &&
        remoteTotal == persistedTotal;

    BOOL remoteZero =
        remoteNtab == 0 &&
        remoteDM == 0 &&
        remoteXChat == 0 &&
        remoteTotal == 0;

    XLGDiagLog(@"%@ user=%@ persisted(ntab=%ld dm=%ld xchat=%ld total=%ld) remote(ntab=%ld dm=%ld xchat=%ld total=%ld)",
                   same ? @"STARTUP_VALIDATED" : @"STARTUP_RELEASED",
                   userID,
                   (long)persistedNtab,
                   (long)persistedDM,
                   (long)persistedXChat,
                   (long)persistedTotal,
                   (long)remoteNtab,
                   (long)remoteDM,
                   (long)remoteXChat,
                   (long)remoteTotal);

    if (remoteZero) {
        XLGDiagLog(@"STARTUP_INVALIDATED user=%@ reason=direct-source-zero",
                       userID);
    }
}

static void XLGLoadPersistedBadgeCounts(void) {
    if (gXLGBadgePersistenceLoaded) return;
    gXLGBadgePersistenceLoaded = YES;
    gXLGBadgeStateByUserID = [NSMutableDictionary dictionary];

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *stored = [defaults dictionaryForKey:kXLGBadgeAccountsKey];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;

    for (id key in stored) {
        NSString *userID = XLGNormalizedUserID(key);
        NSDictionary *state = [stored[key] isKindOfClass:NSDictionary.class]
            ? stored[key]
            : nil;
        if (!userID.length || !state) continue;

        NSTimeInterval timestamp =
            [state[@"timestamp"] respondsToSelector:@selector(doubleValue)]
                ? [state[@"timestamp"] doubleValue]
                : 0;
        if (timestamp > 0 && now - timestamp <= 24.0 * 60.0 * 60.0) {
            NSMutableDictionary *persisted = [state mutableCopy];
            gXLGBadgeStateByUserID[userID] = persisted;
            XLGArmStartupHoldForPersistedState(userID, persisted);
        }
    }

    gXLGBadgeActiveUserID =
        [[defaults stringForKey:XLGBadgeDefaultsKey(@"lastActiveUserID")] copy];

    // One-time migration from the Beta 1/2 single-account cache.
    NSString *legacyUserID =
        [defaults stringForKey:XLGBadgeDefaultsKey(@"userID")];
    NSTimeInterval legacyTimestamp =
        [defaults doubleForKey:XLGBadgeDefaultsKey(@"timestamp")];
    if (legacyUserID.length &&
        !gXLGBadgeStateByUserID[legacyUserID] &&
        legacyTimestamp > 0 &&
        now - legacyTimestamp <= 24.0 * 60.0 * 60.0) {
        NSMutableDictionary *legacy = XLGNewEmptyBadgeState();
        legacy[@"ntab"] = @([defaults integerForKey:XLGBadgeDefaultsKey(@"ntab")]);
        legacy[@"dm"] = @([defaults integerForKey:XLGBadgeDefaultsKey(@"dm")]);
        legacy[@"xchat"] = @([defaults integerForKey:XLGBadgeDefaultsKey(@"xchat")]);
        legacy[@"total"] = @([defaults integerForKey:XLGBadgeDefaultsKey(@"total")]);
        legacy[@"timestamp"] = @(legacyTimestamp);
        gXLGBadgeStateByUserID[legacyUserID] = legacy;
        XLGArmStartupHoldForPersistedState(legacyUserID, legacy);
    }
}

static NSDictionary *XLGActiveBadgeState(void) {
    NSString *userID = XLGCurrentActiveUserID();
    NSDictionary *state = XLGBadgeStateForUserID(userID);
    if (state) return state;

    // Never merge two accounts. A single cached account is only a startup
    // fallback while X has not exposed the active account yet.
    if (!userID.length && gXLGBadgeStateByUserID.count == 1) {
        return gXLGBadgeStateByUserID.allValues.firstObject;
    }
    return nil;
}

static NSInteger XLGChatDisplayCountForState(NSDictionary *state) {
    if (!state) return -1;
    NSInteger xchat = XLGStateInteger(state, @"xchat", -1);
    NSInteger dm = XLGStateInteger(state, @"dm", -1);

    if (xchat > 0) return xchat;
    if (dm >= 0) return dm;
    if (xchat >= 0) return xchat;
    return -1;
}

static NSInteger XLGNotificationDisplayCountForState(NSDictionary *state) {
    if (!state) return -1;

    NSInteger canonical = XLGStateInteger(state, @"ntab", -1);
    NSInteger total = XLGStateInteger(state, @"total", -1);
    NSInteger chat = XLGChatDisplayCountForState(state);
    NSInteger derived = -1;

    if (total >= 0 && chat >= 0 && total >= chat) {
        derived = total - chat;
    }

    if (canonical < 0) return derived;
    if (derived > canonical) return derived;
    return canonical;
}

static NSArray<UIWindow *> *XLGVisibleWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window && !window.hidden) [windows addObject:window];
        }
    }
    return windows;
}

static NSArray<UIView *> *XLGSubviewsMatchingClassName(UIView *root,
                                                       NSString *className) {
    if (!root || !className.length) return @[];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSMutableArray<UIView *> *result = [NSMutableArray array];

    for (NSUInteger i = 0; i < queue.count && i < 4096; i++) {
        UIView *view = queue[i];
        if ([NSStringFromClass(view.class) isEqualToString:className]) {
            [result addObject:view];
        }
        [queue addObjectsFromArray:view.subviews ?: @[]];
    }
    return result;
}

static UIImageView *XLGImageViewForXNavItem(UIView *item) {
    for (UIView *subview in item.subviews ?: @[]) {
        if ([subview isKindOfClass:UIImageView.class]) {
            return (UIImageView *)subview;
        }
    }
    return nil;
}

static BOOL XLGItemIsProfile(UIView *item) {
    NSString *text = item.accessibilityLabel.lowercaseString ?: @"";
    return [text containsString:@"perfil"] ||
           [text containsString:@"profile"] ||
           [text containsString:@"conta"] ||
           [text containsString:@"account"];
}

static UIView *XLGAncestorNamed(UIView *view, NSString *className) {
    UIView *cursor = view.superview;
    while (cursor) {
        if ([NSStringFromClass(cursor.class) isEqualToString:className]) {
            return cursor;
        }
        cursor = cursor.superview;
    }
    return nil;
}

static BOOL XLGXNavItemIsSelected(UIView *item) {
    if ((item.accessibilityTraits & UIAccessibilityTraitSelected) != 0) return YES;

    UIView *bar = XLGAncestorNamed(item, @"XNavigation.TabBarView");
    if (!bar) return NO;

    id itemViews = XLGSafeValueForKey(bar, @"itemViews");
    id selectedIndexValue = XLGSafeValueForKey(bar, @"selectedIndex");
    if (![itemViews isKindOfClass:NSArray.class] ||
        ![selectedIndexValue respondsToSelector:@selector(integerValue)]) {
        return NO;
    }

    NSUInteger index = [(NSArray *)itemViews indexOfObjectIdenticalTo:item];
    if (index == NSNotFound) return NO;
    return (NSInteger)index == [selectedIndexValue integerValue];
}

static UIColor *XLGNativeInactiveTabColor(void) {
    Class tabViewClass = NSClassFromString(@"T1TabView");
    SEL itemColorSEL = NSSelectorFromString(@"itemColor");
    if (tabViewClass && [tabViewClass respondsToSelector:itemColorSEL]) {
        id color = ((id(*)(id,SEL))objc_msgSend)(tabViewClass, itemColorSEL);
        if ([color isKindOfClass:UIColor.class]) return color;
    }
    return UIColor.secondaryLabelColor;
}

static UIColor *XLGResolvedAccentColor(void) {
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
        SEL infoSEL = NSSelectorFromString(@"currentColorPalette");
        id info = (settings && [settings respondsToSelector:infoSEL])
            ? ((id(*)(id,SEL))objc_msgSend)(settings, infoSEL)
            : nil;
        SEL paletteSEL = NSSelectorFromString(@"colorPalette");
        id palette = (info && [info respondsToSelector:paletteSEL])
            ? ((id(*)(id,SEL))objc_msgSend)(info, paletteSEL)
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

static UILabel *XLGBadgeLabelForXNavItem(UIView *item) {
    UILabel *badge = objc_getAssociatedObject(item, &kXLGBadgeLabelKey);
    if (badge) return badge;

    badge = [[UILabel alloc] initWithFrame:CGRectZero];
    badge.userInteractionEnabled = NO;
    badge.hidden = YES;
    badge.textAlignment = NSTextAlignmentCenter;
    badge.textColor = UIColor.whiteColor;
    badge.backgroundColor = UIColor.systemRedColor;
    badge.font = [UIFont boldSystemFontOfSize:10.0];
    badge.layer.cornerRadius = 8.0;
    badge.layer.masksToBounds = YES;
    badge.accessibilityIdentifier = @"XLiquidGlassUnreadBadge";
    [item addSubview:badge];

    objc_setAssociatedObject(item,
                             &kXLGBadgeLabelKey,
                             badge,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return badge;
}

static NSString *XLGIdentityTextForXNavItem(UIView *item) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    for (NSString *value in @[
        item.accessibilityLabel ?: @"",
        item.accessibilityIdentifier ?: @"",
        item.accessibilityHint ?: @"",
        item.accessibilityValue ?: @""
    ]) {
        if (value.length) [parts addObject:value];
    }

    UIImageView *imageView = XLGImageViewForXNavItem(item);
    if (imageView.accessibilityLabel.length)
        [parts addObject:imageView.accessibilityLabel];
    if (imageView.accessibilityIdentifier.length)
        [parts addObject:imageView.accessibilityIdentifier];

    UIView *bar = XLGAncestorNamed(item, @"XNavigation.TabBarView");
    id itemViews = XLGSafeValueForKey(bar, @"itemViews");
    id tabs = XLGSafeValueForKey(bar, @"tabs");
    if ([itemViews isKindOfClass:NSArray.class] &&
        [tabs isKindOfClass:NSArray.class]) {
        NSUInteger index = [(NSArray *)itemViews indexOfObjectIdenticalTo:item];
        if (index != NSNotFound && index < [(NSArray *)tabs count]) {
            id tab = ((NSArray *)tabs)[index];
            for (NSString *key in @[@"identifier",
                                     @"tabIdentifier",
                                     @"title",
                                     @"name",
                                     @"accessibilityLabel"]) {
                id value = XLGSafeValueForKey(tab, key);
                if ([value isKindOfClass:NSString.class] &&
                    [(NSString *)value length]) {
                    [parts addObject:value];
                }
            }
            NSString *description = [tab description];
            if (description.length) [parts addObject:description];
        }
    }

    return [[parts componentsJoinedByString:@" "] lowercaseString];
}

static NSString *XLGBadgeKindForIdentity(NSString *identity) {
    if (!identity.length) return @"unknown";

    if ([identity containsString:@"notifica"] ||
        [identity containsString:@"notification"] ||
        [identity containsString:@"activity"] ||
        [identity containsString:@"ntab"]) {
        return @"notifications";
    }

    if ([identity containsString:@"bate-papo"] ||
        [identity containsString:@"chat"] ||
        [identity containsString:@"mensag"] ||
        [identity containsString:@"message"] ||
        [identity containsString:@"dm_tab"] ||
        [identity containsString:@"dmtab"]) {
        return @"chat";
    }

    return @"unknown";
}

static NSInteger XLGBadgeCountForKind(NSString *kind, NSDictionary *state) {
    if (!state) return -1;
    if ([kind isEqualToString:@"notifications"]) {
        return XLGNotificationDisplayCountForState(state);
    }
    if ([kind isEqualToString:@"chat"]) {
        return XLGChatDisplayCountForState(state);
    }
    return -1;
}

static NSInteger XLGIndexForXNavItem(UIView *item) {
    UIView *bar = XLGAncestorNamed(item, @"XNavigation.TabBarView");
    id itemViews = XLGSafeValueForKey(bar, @"itemViews");
    if (![itemViews isKindOfClass:NSArray.class]) return -1;
    NSUInteger index = [(NSArray *)itemViews indexOfObjectIdenticalTo:item];
    return index == NSNotFound ? -1 : (NSInteger)index;
}

static NSString *XLGCompactIdentity(NSString *identity) {
    if (!identity.length) return @"-";
    NSString *text = [[identity stringByReplacingOccurrencesOfString:@"\n"
                                                          withString:@" "]
                      stringByReplacingOccurrencesOfString:@"\r"
                                                withString:@" "];
    while ([text containsString:@"  "]) {
        text = [text stringByReplacingOccurrencesOfString:@"  "
                                               withString:@" "];
    }
    if (text.length > 220) {
        text = [[text substringToIndex:220] stringByAppendingString:@"…"];
    }
    return text;
}

static void XLGDiagAppliedItem(UIView *item,
                                  NSString *identity,
                                  NSString *kind,
                                  NSInteger wanted,
                                  NSString *action,
                                  NSString *beforeText,
                                  BOOL beforeVisible) {
    UILabel *badge = objc_getAssociatedObject(item, &kXLGBadgeLabelKey);
    NSString *afterText = badge.text.length ? badge.text : @"-";
    BOOL afterVisible = badge ? !badge.hidden : NO;
    NSInteger index = XLGIndexForXNavItem(item);
    NSString *active = XLGCurrentActiveUserID() ?: @"-";
    NSString *compactIdentity = XLGCompactIdentity(identity);

    NSString *signature =
        [NSString stringWithFormat:@"%@|%ld|%@|%ld|%@|%@|%d|%@|%d|%@",
         active,
         (long)index,
         kind ?: @"unknown",
         (long)wanted,
         action ?: @"-",
         beforeText ?: @"-",
         beforeVisible,
         afterText,
         afterVisible,
         compactIdentity];

    NSString *previous =
        objc_getAssociatedObject(item, &kXLGBadgeSignatureKey);
    if ([previous isEqualToString:signature]) return;

    objc_setAssociatedObject(item,
                             &kXLGBadgeSignatureKey,
                             signature,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);

    BOOL stalePrevented =
        beforeVisible &&
        ((wanted < 0) || (wanted == 0));

    XLGDiagLog(@"ITEM ptr=%p index=%ld active=%@ kind=%@ wanted=%ld action=%@ beforeText=%@ beforeVisible=%d afterText=%@ afterVisible=%d stalePrevented=%d identity=%@",
                  item,
                  (long)index,
                  active,
                  kind ?: @"unknown",
                  (long)wanted,
                  action ?: @"-",
                  beforeText ?: @"-",
                  beforeVisible,
                  afterText,
                  afterVisible,
                  stalePrevented,
                  compactIdentity);
}

static void XLGApplyBadgeToXNavItem(UIView *item) {
    NSString *identity = XLGIdentityTextForXNavItem(item);
    NSString *kind = XLGBadgeKindForIdentity(identity);
    NSDictionary *state = XLGActiveBadgeState();
    NSInteger count = XLGBadgeCountForKind(kind, state);

    UILabel *existing = objc_getAssociatedObject(item, &kXLGBadgeLabelKey);
    NSString *beforeText = existing.text.length ? [existing.text copy] : @"-";
    BOOL beforeVisible = existing ? !existing.hidden : NO;

    // Final stale-badge fix: an item can temporarily lose its identity while
    // XNavigation rebuilds/reuses TabBarItemView during account switching.
    // Never leave a previously visible badge attached to an unknown item.
    if (count < 0) {
        if (existing) {
            existing.hidden = YES;
            existing.text = nil;
        }
        XLGDiagAppliedItem(item,
                              identity,
                              kind,
                              count,
                              @"hide-unknown",
                              beforeText,
                              beforeVisible);
        return;
    }

    UILabel *badge = existing ?: XLGBadgeLabelForXNavItem(item);
    if (count <= 0) {
        badge.hidden = YES;
        badge.text = nil;
        XLGDiagAppliedItem(item,
                              identity,
                              kind,
                              count,
                              @"hide-zero",
                              beforeText,
                              beforeVisible);
        return;
    }

    NSString *text = count > 99
        ? @"99+"
        : [NSString stringWithFormat:@"%ld", (long)count];

    badge.text = text;
    CGSize size = [text sizeWithAttributes:@{NSFontAttributeName: badge.font}];
    CGFloat height = 16.0;
    CGFloat width = MAX(16.0, ceil(size.width) + 7.0);

    UIImageView *imageView = XLGImageViewForXNavItem(item);
    if (imageView) {
        badge.frame = CGRectIntegral(CGRectMake(
            CGRectGetMaxX(imageView.frame) - 8.0,
            CGRectGetMinY(imageView.frame) - 4.0,
            width,
            height));
    } else {
        badge.frame = CGRectIntegral(CGRectMake(
            CGRectGetMidX(item.bounds) + 4.0,
            8.0,
            width,
            height));
    }

    badge.layer.cornerRadius = height / 2.0;
    badge.hidden = NO;
    [item bringSubviewToFront:badge];

    XLGDiagAppliedItem(item,
                          identity,
                          kind,
                          count,
                          @"show",
                          beforeText,
                          beforeVisible);
}

static void XLGApplyThemeToXNavItem(UIView *item) {
    if (!item || XLGItemIsProfile(item)) return;

    UIImageView *imageView = XLGImageViewForXNavItem(item);
    if (!imageView || !imageView.image) return;

    BOOL selected = XLGXNavItemIsSelected(item);
    UIColor *color = selected ? XLGResolvedAccentColor()
                              : XLGNativeInactiveTabColor();

    if (imageView.image.renderingMode != UIImageRenderingModeAlwaysTemplate) {
        imageView.image =
            [imageView.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    imageView.tintColor = color;
    item.tintColor = color;

    UIView *bar = XLGAncestorNamed(item, @"XNavigation.TabBarView");
    if (selected && bar) {
        for (NSString *key in @[@"pill", @"platter"]) {
            id chrome = XLGSafeValueForKey(bar, key);
            if ([chrome isKindOfClass:UIView.class]) {
                ((UIView *)chrome).tintColor = XLGResolvedAccentColor();
            }
        }
    }

    for (UIView *subview in item.subviews ?: @[]) {
        if (![subview isKindOfClass:UILabel.class]) continue;
        UILabel *label = (UILabel *)subview;
        if ([label.accessibilityIdentifier isEqualToString:@"XLiquidGlassUnreadBadge"]) {
            continue;
        }
        label.hidden = !XLGTabLabelsEnabled();
        if (!label.hidden) label.textColor = color;
    }
}

static NSString *gXLGLastRenderSignature = nil;

static void XLGRefreshGlobalTabBar(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *activeUserID = XLGCurrentActiveUserID();
        NSString *navigationUserID =
            XLGTryResolveUserID(XLGSidebarCurrentAccount(), 0);
        NSDictionary *state = XLGBadgeStateForUserID(activeUserID);

        NSInteger ntab = XLGStateInteger(state, @"ntab", -1);
        NSInteger dm = XLGStateInteger(state, @"dm", -1);
        NSInteger xchat = XLGStateInteger(state, @"xchat", -1);
        NSInteger total = XLGStateInteger(state, @"total", -1);
        NSInteger chat = XLGChatDisplayCountForState(state);
        NSInteger notifications = XLGNotificationDisplayCountForState(state);

        NSString *signature =
            [NSString stringWithFormat:@"%@|%@|%ld|%ld|%ld|%ld|%ld|%ld",
             activeUserID ?: @"-",
             navigationUserID ?: @"-",
             (long)ntab, (long)dm, (long)xchat, (long)total,
             (long)chat, (long)notifications];

        if (![gXLGLastRenderSignature isEqualToString:signature]) {
            gXLGLastRenderSignature = [signature copy];
            XLGDiagLog(@"RENDER active=%@ nav=%@ ntab=%ld dm=%ld xchat=%ld total=%ld chat=%ld notifications=%ld",
                  activeUserID ?: @"-",
                  navigationUserID ?: @"-",
                  (long)ntab,
                  (long)dm,
                  (long)xchat,
                  (long)total,
                  (long)chat,
                  (long)notifications);
        }

        for (UIWindow *window in XLGVisibleWindows()) {
            for (UIView *item in
                 XLGSubviewsMatchingClassName(window, @"XNavigation.TabBarItemView")) {
                XLGApplyThemeToXNavItem(item);
                XLGApplyBadgeToXNavItem(item);
            }
        }
    });
}

static BOOL XLGSetBadgeCountsFromObject(id object, NSString *userID) {
    if (!object || !userID.length) return NO;

    NSInteger ntab = 0, dm = 0, xchat = 0, total = 0;
    BOOL hasNtab = XLGReadNTabCount(object, &ntab);
    BOOL hasDM = XLGReadDMCount(object, &dm);
    BOOL hasXChat = XLGReadXChatCount(object, &xchat);
    BOOL hasTotal = XLGReadTotalCount(object, &total);
    if (!hasNtab && !hasDM && !hasXChat && !hasTotal) return NO;

    XLGNormalizeBadgeMapForKnownNtabMisroute(
        userID,
        hasNtab, &ntab,
        hasDM, &dm,
        hasXChat, &xchat,
        hasTotal, &total);

    NSMutableDictionary *state =
        XLGMutableBadgeStateForUserID(userID, YES);
    BOOL changed = NO;

    if (hasNtab) {
        NSInteger value = MAX((NSInteger)0, ntab);
        if (XLGStateInteger(state, @"ntab", -1) != value) {
            state[@"ntab"] = @(value);
            changed = YES;
        }
    }
    if (hasDM) {
        NSInteger value = MAX((NSInteger)0, dm);
        if (XLGStateInteger(state, @"dm", -1) != value) {
            state[@"dm"] = @(value);
            changed = YES;
        }
    }
    if (hasXChat) {
        NSInteger value = MAX((NSInteger)0, xchat);
        if (XLGStateInteger(state, @"xchat", -1) != value) {
            state[@"xchat"] = @(value);
            changed = YES;
        }
    }
    if (hasTotal) {
        NSInteger value = MAX((NSInteger)0, total);
        if (XLGStateInteger(state, @"total", -1) != value) {
            state[@"total"] = @(value);
            changed = YES;
        }
    }

    state[@"timestamp"] = @(NSDate.date.timeIntervalSince1970);

    if (changed) {
        NSLog(@"[XLiquidGlass] badge-cache user=%@ ntab=%ld dm=%ld xchat=%ld total=%ld",
              userID,
              (long)XLGStateInteger(state, @"ntab", -1),
              (long)XLGStateInteger(state, @"dm", -1),
              (long)XLGStateInteger(state, @"xchat", -1),
              (long)XLGStateInteger(state, @"total", -1));
        XLGDiagLog(@"CACHE user=%@ ntab=%ld dm=%ld xchat=%ld total=%ld",
              userID,
              (long)XLGStateInteger(state, @"ntab", -1),
              (long)XLGStateInteger(state, @"dm", -1),
              (long)XLGStateInteger(state, @"xchat", -1),
              (long)XLGStateInteger(state, @"total", -1));
    }
    return changed;
}

static BOOL XLGLooksLikeAccountBadgeMap(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:NSDictionary.class] || dictionary.count == 0)
        return NO;

    NSUInteger valid = 0;
    for (id key in dictionary) {
        id object = dictionary[key];
        NSInteger total = 0;
        if (XLGReadTotalCount(object, &total)) valid++;
    }
    return valid == dictionary.count;
}

static void XLGCacheAllBadgeAccountsFromMap(NSDictionary *dictionary) {
    if (!XLGLooksLikeAccountBadgeMap(dictionary)) return;
    gXLGLastBadgeCountsByUserID = [dictionary copy];

    BOOL changed = NO;
    for (id key in dictionary) {
        NSString *userID = XLGNormalizedUserID(key);
        if (!userID.length) continue;
        changed |= XLGSetBadgeCountsFromObject(dictionary[key], userID);
    }

    // Badge maps are data only. They must never decide which account is active.
    // Always redraw even if the values equal the persisted cache: account
    // switches create fresh XNavigation.TabBarItemView instances.
    if (changed) {
        XLGPersistBadgeStates();
    }
    XLGRefreshGlobalTabBar();
}

static void XLGSetActiveBadgeUserID(NSString *userID, NSString *source) {
    if (!userID.length) return;

    BOOL changed = ![gXLGBadgeActiveUserID isEqualToString:userID];
    if (changed) {
        gXLGBadgeActiveUserID = [userID copy];
        NSLog(@"[XLiquidGlass] active badge account=%@ source=%@",
              userID, source ?: @"-");
        XLGDiagLog(@"LIFECYCLE active=%@ source=%@",
                      userID, source ?: @"-");
        XLGPersistBadgeStates();
    }

    // A same-account callback can arrive after X rebuilt the Liquid Glass bar,
    // so redraw even when the numeric userID itself did not change.
    XLGRefreshGlobalTabBar();

    // Final: X can rebuild/reuse TabBarItemView shortly after the lifecycle
    // callback. Rebind after the transition so the final visual identity gets
    // a fresh badge decision, not just the pre-rebuild view tree.
    for (NSNumber *delayNumber in @[@0.06, @0.22]) {
        NSTimeInterval delay = delayNumber.doubleValue;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                XLGDiagLog(@"REBIND active=%@ delay=%.2f",
                              XLGCurrentActiveUserID() ?: @"-",
                              delay);
                XLGRefreshGlobalTabBar();
            });
    }
}

static void XLGNotificationsViewDidAppear(id self,
                                         SEL cmd,
                                         BOOL animated) {
    if (gOrigNotificationsViewDidAppear) {
        ((void(*)(id,SEL,BOOL))gOrigNotificationsViewDidAppear)(
            self,cmd,animated);
    }

    if (!XLGEnabled()) return;

    id account=nil;
    SEL accountSEL=NSSelectorFromString(@"account");
    if ([self respondsToSelector:accountSEL]) {
        account=((id(*)(id,SEL))objc_msgSend)(self,accountSEL);
    }

    NSString *userID=XLGTryResolveUserID(account,0);
    if (!userID.length) userID=XLGCurrentActiveUserID();
    if (!userID.length) return;

    XLGMarkNotificationsViewedAndClearBadge(userID);
}

static void XLGAppBadgingSetCurrentUserID(id self, SEL cmd, unsigned long long userID) {
    if (gOrigAppBadgingSetCurrentUserID) {
        ((void(*)(id,SEL,unsigned long long))gOrigAppBadgingSetCurrentUserID)(
            self, cmd, userID);
    }

    // Beta 7: advisory only. T1AppBadging owns global badge bookkeeping, not
    // the identity of the XNavigation bar currently visible to the user.
    NSString *reported = [@(userID) stringValue];
    XLGDiagLog(@"ADVISORY source=T1AppBadging.setCurrentUserID reported=%@ active=%@",
          reported,
          gXLGBadgeActiveUserID ?: @"-");
    XLGRefreshGlobalTabBar();
}

static void XLGAppBadgingSetUserIDsCurrentUserID(id self,
                                                 SEL cmd,
                                                 id userIDs,
                                                 id currentUserID) {
    if (gOrigAppBadgingSetUserIDsCurrentUserID) {
        ((void(*)(id,SEL,id,id))gOrigAppBadgingSetUserIDsCurrentUserID)(
            self, cmd, userIDs, currentUserID);
    }

    NSString *reported = XLGNormalizedUserID(currentUserID);
    XLGDiagLog(@"ADVISORY source=T1AppBadging.setUserIDs:currentUserID: reported=%@ active=%@",
          reported ?: @"-",
          gXLGBadgeActiveUserID ?: @"-");
    XLGRefreshGlobalTabBar();
}

static void XLGActiveAccountDidChange(id self, SEL cmd, id argument) {
    if (gOrigActiveAccountDidChange) {
        ((void(*)(id,SEL,id))gOrigActiveAccountDidChange)(self, cmd, argument);
    }

    // In X 12.28.1 this callback receives an NSNotification. The new
    // TFNTwitterAccount is notification.object; the notification itself has no
    // userID. Prefer that exact lifecycle object, then X's own current-user
    // accessors. appNavigation/sidebar is startup fallback only.
    NSString *userID = XLGUserIDFromNotification(argument);
    if (!userID.length) {
        userID = XLGCurrentUserIDFromAppEventHandler(self);
    }
    if (!userID.length) {
        userID = XLGTryResolveUserID(argument, 0);
    }
    if (!userID.length) {
        userID = XLGTryResolveUserID(XLGSidebarCurrentAccount(), 0);
    }

    XLGSetActiveBadgeUserID(userID, @"T1AppEventHandler._t1_activeAccountDidChange:");
}

static BOOL XLGMethodIsVoidWithExtraArgs(Class cls,
                                              SEL selector,
                                              unsigned int extraArgs) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) return NO;
    if (method_getNumberOfArguments(method) != extraArgs + 2) return NO;

    char returnType[32] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    const char *p = returnType;
    while (*p && strchr("rnNoORV", *p)) p++;
    return *p == 'v';
}

static void XLGAppBadgingSetLocalUnseenDMCountUserIDDate(id self,
                                                         SEL cmd,
                                                         uintptr_t arg1,
                                                         uintptr_t arg2,
                                                         uintptr_t arg3) {
    XLGRememberLocalDMSource((unsigned long long)arg2, (NSInteger)arg1);
    if (gOrigAppBadgingSetLocalUnseenDMCountUserIDDate) {
        ((void(*)(id,SEL,uintptr_t,uintptr_t,uintptr_t))
         gOrigAppBadgingSetLocalUnseenDMCountUserIDDate)(
            self, cmd, arg1, arg2, arg3);
    }

}

static void XLGAppBadgingSetLocalUnseenXChatCountUserIDDate(id self,
                                                            SEL cmd,
                                                            uintptr_t arg1,
                                                            uintptr_t arg2,
                                                            uintptr_t arg3) {
    XLGRememberLocalXChatSource((unsigned long long)arg2, (NSInteger)arg1);
    if (gOrigAppBadgingSetLocalUnseenXChatCountUserIDDate) {
        ((void(*)(id,SEL,uintptr_t,uintptr_t,uintptr_t))
         gOrigAppBadgingSetLocalUnseenXChatCountUserIDDate)(
            self, cmd, arg1, arg2, arg3);
    }

}

static void XLGPromoteDirectRemoteNotificationBadgeState(
    NSString *userID,
    uintptr_t ntabRaw,
    uintptr_t dmRaw,
    uintptr_t xchatRaw,
    uintptr_t totalRaw) {

    if (!userID.length) return;

    NSInteger ntab=XLGIntegerFromObjectPointer(ntabRaw,-1);
    NSInteger dm=XLGIntegerFromObjectPointer(dmRaw,-1);
    NSInteger xchat=XLGIntegerFromObjectPointer(xchatRaw,-1);
    NSInteger total=XLGIntegerFromObjectPointer(totalRaw,-1);

    // The Beta 3 timing probe showed this exact tuple is the first correct
    // notification state. Restrict the fast path to it so chat semantics stay
    // on the already-validated reconciler.
    if (ntab<=0 || dm!=0 || xchat!=0 || total!=ntab) return;

    NSMutableDictionary *state=
        XLGMutableBadgeStateForUserID(userID,YES);
    state[@"ntab"]=@(ntab);
    state[@"dm"]=@0;
    state[@"xchat"]=@0;
    state[@"total"]=@(total);
    state[@"timestamp"]=@(NSDate.date.timeIntervalSince1970);

    XLGPersistBadgeStates();

    // Do this before X's original implementation emits the broken aggregate
    // maps. XLGCurrentActiveUserID keeps inactive-account updates from being
    // rendered on the visible account.
    XLGRefreshGlobalTabBar();

    // Rebind across the same run-loop transition in case X rebuilds the
    // TabBarItemView while processing the original callback.
    for (NSNumber *delayNumber in @[@0.02,@0.08,@0.20]) {
        NSTimeInterval delay=delayNumber.doubleValue;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay*NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                XLGRefreshGlobalTabBar();
            });
    }

    XLGDiagLog(
        @"DIRECT_REMOTE_PROMOTE user=%@ ntab=%ld dm=0 xchat=0 total=%ld",
        userID,
        (long)ntab,
        (long)total);
}

static void XLGTFNApplyRemoteBadgeCounts(id self,
                                         SEL cmd,
                                         uintptr_t ntab,
                                         uintptr_t dm,
                                         uintptr_t xchat,
                                         uintptr_t total,
                                         uintptr_t dateRaw) {
    NSString *userID = XLGTryResolveUserID(self, 0) ?: @"-";

    if (![userID isEqualToString:@"-"]) {
        XLGRememberRemoteBadgeSource(userID, ntab, dm, xchat, total);

        // Beta 3 proved the correct ntab count exists here before X emits the
        // bad aggregate maps. Promote before calling the original method.
        XLGPromoteDirectRemoteNotificationBadgeState(
            userID,ntab,dm,xchat,total);
    }

    if (gOrigTFNApplyRemoteBadgeCounts) {
        ((void(*)(id,SEL,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t))
         gOrigTFNApplyRemoteBadgeCounts)(
            self, cmd, ntab, dm, xchat, total, dateRaw);
    }

}

static BOOL XLGInstallCheckedFunctionalHook(Class cls,
                                                NSString *selectorName,
                                                unsigned int extraArgs,
                                                IMP replacement,
                                                IMP *originalOut) {
    if (!cls || !selectorName.length || !replacement || !originalOut) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (!XLGMethodIsVoidWithExtraArgs(cls, selector, extraArgs)) return NO;
    return XLGHookMethod(cls, selector, NO, replacement, originalOut);
}

static void XLGInstallBadgeReconciliationHooks(void) {
    // These three hooks are functional, not diagnostic:
    // TFNTwitterAccount provides the authoritative remote counts, while the
    // local DM/XChat setters disambiguate notification-only state.
    Class appBadging = NSClassFromString(@"T1AppBadging");
    if (appBadging) {
        if (!gOrigAppBadgingSetLocalUnseenDMCountUserIDDate) {
            XLGInstallCheckedFunctionalHook(
                appBadging,
                @"setLocalUnseenDMCount:userID:date:",
                3,
                (IMP)XLGAppBadgingSetLocalUnseenDMCountUserIDDate,
                &gOrigAppBadgingSetLocalUnseenDMCountUserIDDate);
        }
        if (!gOrigAppBadgingSetLocalUnseenXChatCountUserIDDate) {
            XLGInstallCheckedFunctionalHook(
                appBadging,
                @"setLocalUnseenXChatCount:userID:date:",
                3,
                (IMP)XLGAppBadgingSetLocalUnseenXChatCountUserIDDate,
                &gOrigAppBadgingSetLocalUnseenXChatCountUserIDDate);
        }
    }

    Class account = NSClassFromString(@"TFNTwitterAccount");
    if (account && !gOrigTFNApplyRemoteBadgeCounts) {
        XLGInstallCheckedFunctionalHook(
            account,
            @"_applyRemoteBadgeCountsWithNtab:dm:xchat:total:date:",
            5,
            (IMP)XLGTFNApplyRemoteBadgeCounts,
            &gOrigTFNApplyRemoteBadgeCounts);
    }
}

static void XLGHandleBadgeNotification(NSNotification *notification) {
    NSString *name = notification.name ?: @"";

    if ([name isEqualToString:@"AppIconBadgeCountDidChange"]) {
        id value = notification.userInfo[@"AppIconBadgeCountDidChangeUpdatedValue"];
        if ([value respondsToSelector:@selector(integerValue)]) {
            // Keep the root count for diagnostics only. It must not select an
            // account because multiple accounts can legitimately share totals.
            gXLGLastRootBadgeCount = [value integerValue];
        }
        return;
    }

    if ([name isEqualToString:@"AccountBadgesDidChange"]) {
        id map = notification.userInfo[@"AccountBadgesDidChangeUpdatedValues"];
        XLGDiagLog(@"SOURCE_NOTIFICATION name=AccountBadgesDidChange objectClass=%@",
                      notification.object
                          ? NSStringFromClass([notification.object class])
                          : @"nil");
        if ([map isKindOfClass:NSDictionary.class]) {
            XLGCacheAllBadgeAccountsFromMap(map);
        }
        return;
    }

    if ([name isEqualToString:@"TFSAccountDidBecomeActive"]) {
        NSString *userID = XLGTryResolveUserID(notification.object, 0);
        XLGSetActiveBadgeUserID(userID, @"TFSAccountDidBecomeActive");
        return;
    }

    // Other account notifications may describe inactive/background accounts.
    // They can trigger a redraw, but they must never change badge ownership.
    NSString *lower = name.lowercaseString;
    if ([lower containsString:@"account"] &&
        ([lower containsString:@"change"] ||
         [lower containsString:@"active"] ||
         [lower containsString:@"switch"])) {
        XLGRefreshGlobalTabBar();
    }
}

static void XLGXNavItemLayout(id self, SEL cmd) {
    if (gOrigXNavItemLayout) {
        ((void(*)(id,SEL))gOrigXNavItemLayout)(self, cmd);
    }

    if ([self isKindOfClass:UIView.class]) {
        UIView *item = (UIView *)self;
        XLGApplyThemeToXNavItem(item);
        XLGApplyBadgeToXNavItem(item);
    }
}

static void XLGConsumeNativeT1TabBadgeSignal(id tabView,
                                             unsigned long long rawCount) {
    if (!XLGEnabled() || !tabView) return;

    NSString *identifier=nil;
    NSString *label=nil;
    if ([tabView respondsToSelector:@selector(accessibilityIdentifier)]) {
        identifier=((id(*)(id,SEL))objc_msgSend)(
            tabView,@selector(accessibilityIdentifier));
    }
    if ([tabView respondsToSelector:@selector(accessibilityLabel)]) {
        label=((id(*)(id,SEL))objc_msgSend)(
            tabView,@selector(accessibilityLabel));
    }

    NSString *identity=
        [NSString stringWithFormat:@"%@ %@",
         identifier ?: @"",
         label ?: @""].lowercaseString;

    BOOL notifications=
        [identifier.lowercaseString isEqualToString:@"notifications_tab"] ||
        [identity containsString:@"notification"] ||
        [identity containsString:@"notifica"];
    BOOL chat=
        [identifier.lowercaseString isEqualToString:@"dm_tab"] ||
        [identity containsString:@"bate-papo"] ||
        [identity containsString:@"chat"] ||
        [identity containsString:@"message"] ||
        [identity containsString:@"mensag"];

    if (!notifications && !chat) return;

    NSString *userID=
        XLGTryResolveUserID(XLGSidebarCurrentAccount(),0);
    if (!userID.length) userID=XLGCurrentActiveUserID();
    if (!userID.length) return;

    NSInteger count=(NSInteger)MIN(
        rawCount,(unsigned long long)NSIntegerMax);
    count=MAX((NSInteger)0,count);

    NSMutableDictionary *state=
        XLGMutableBadgeStateForUserID(userID,YES);
    NSMutableDictionary *source=
        XLGSourceStateForUserID(userID,YES);
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;

    if (notifications) {
        NSInteger chatCount=XLGChatDisplayCountForState(state);
        if (chatCount<0) chatCount=0;

        state[@"ntab"]=@(count);
        state[@"total"]=@(count+MAX((NSInteger)0,chatCount));
        source[@"nativeNtab"]=@(count);
        source[@"nativeNtabTimestamp"]=@(now);

        // A native zero is X's own visible badge transition. Do not let an
        // older trusted remote snapshot immediately resurrect it.
        if (count==0) {
            source[@"trustedNotifications"]=@NO;
            source[@"remoteNtab"]=@0;
            source[@"remoteTotal"]=@(MAX((NSInteger)0,chatCount));
            source[@"remoteTimestamp"]=@(now);
        }
    } else if (chat) {
        NSInteger notificationCount=
            XLGNotificationDisplayCountForState(state);
        if (notificationCount<0) notificationCount=0;

        // DM_tab is the visible chat badge source. Mirror it to both chat
        // fields; the later account map still disambiguates DM versus XChat.
        state[@"dm"]=@(count);
        state[@"xchat"]=@(count);
        state[@"total"]=@(MAX((NSInteger)0,notificationCount)+count);
        source[@"nativeChat"]=@(count);
        source[@"nativeChatTimestamp"]=@(now);
    }

    state[@"timestamp"]=@(now);
    XLGPersistBadgeStates();
    XLGRefreshGlobalTabBar();

    // The Liquid Glass bar can rebuild within the same run-loop transition.
    // Re-apply the already-cached native count after those short rebuilds.
    for (NSNumber *delayNumber in @[@0.04,@0.18]) {
        NSTimeInterval delay=delayNumber.doubleValue;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay*NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                XLGRefreshGlobalTabBar();
            });
    }
}

static void XLGT1TabViewSetBadgeCountAnimated(id self,
                                               SEL cmd,
                                               unsigned long long count,
                                               BOOL animated) {
    if (gOrigT1TabViewSetBadgeCountAnimated) {
        ((void(*)(id,SEL,unsigned long long,BOOL))
            gOrigT1TabViewSetBadgeCountAnimated)(
                self,cmd,count,animated);
    }
    XLGConsumeNativeT1TabBadgeSignal(self,count);
}

static void XLGT1TabViewSetBadgeCount(id self,
                                      SEL cmd,
                                      unsigned long long count) {
    if (gOrigT1TabViewSetBadgeCount) {
        ((void(*)(id,SEL,unsigned long long))
            gOrigT1TabViewSetBadgeCount)(
                self,cmd,count);
    }
    XLGConsumeNativeT1TabBadgeSignal(self,count);
}

static void XLGInstallNativeT1TabBadgeBridge(void) {
    Class tabViewClass=NSClassFromString(@"T1TabView");
    if (!tabViewClass) return;

    SEL animatedSEL=NSSelectorFromString(@"setBadgeCount:animated:");
    Method animatedMethod=
        class_getInstanceMethod(tabViewClass,animatedSEL);
    if (animatedMethod &&
        method_getNumberOfArguments(animatedMethod)==4 &&
        !gOrigT1TabViewSetBadgeCountAnimated) {
        char ret[16]={0};
        method_getReturnType(animatedMethod,ret,sizeof(ret));
        const char *r=ret;
        while (*r && strchr("rnNoORV",*r)) r++;
        if (*r=='v') {
            XLGHookMethod(
                tabViewClass,
                animatedSEL,
                NO,
                (IMP)XLGT1TabViewSetBadgeCountAnimated,
                &gOrigT1TabViewSetBadgeCountAnimated);
        }
    }

    SEL plainSEL=NSSelectorFromString(@"setBadgeCount:");
    Method plainMethod=
        class_getInstanceMethod(tabViewClass,plainSEL);
    if (plainMethod &&
        method_getNumberOfArguments(plainMethod)==3 &&
        !gOrigT1TabViewSetBadgeCount) {
        char ret[16]={0};
        method_getReturnType(plainMethod,ret,sizeof(ret));
        const char *r=ret;
        while (*r && strchr("rnNoORV",*r)) r++;
        if (*r=='v') {
            XLGHookMethod(
                tabViewClass,
                plainSEL,
                NO,
                (IMP)XLGT1TabViewSetBadgeCount,
                &gOrigT1TabViewSetBadgeCount);
        }
    }
}

static void XLGInstallGlobalTabBarFixes(void) {
    XLGLoadPersistedBadgeCounts();

    Class notificationsClass=
        NSClassFromString(@"T1NotificationsViewController");
    if (notificationsClass &&
        [notificationsClass instancesRespondToSelector:@selector(viewDidAppear:)] &&
        !gOrigNotificationsViewDidAppear) {
        XLGHookMethod(
            notificationsClass,
            @selector(viewDidAppear:),
            NO,
            (IMP)XLGNotificationsViewDidAppear,
            &gOrigNotificationsViewDidAppear);
    }

    Class appEventClass = NSClassFromString(@"T1AppEventHandler");
    SEL activeAccountSEL = NSSelectorFromString(@"_t1_activeAccountDidChange:");
    if (appEventClass &&
        [appEventClass instancesRespondToSelector:activeAccountSEL] &&
        !gOrigActiveAccountDidChange) {
        XLGHookMethod(appEventClass,
                      activeAccountSEL,
                      NO,
                      (IMP)XLGActiveAccountDidChange,
                      &gOrigActiveAccountDidChange);
    }

    Class appBadgingClass = NSClassFromString(@"T1AppBadging");
    if (appBadgingClass) {
        SEL setCurrentUserIDSEL = NSSelectorFromString(@"setCurrentUserID:");
        if ([appBadgingClass instancesRespondToSelector:setCurrentUserIDSEL] &&
            !gOrigAppBadgingSetCurrentUserID) {
            XLGHookMethod(appBadgingClass,
                          setCurrentUserIDSEL,
                          NO,
                          (IMP)XLGAppBadgingSetCurrentUserID,
                          &gOrigAppBadgingSetCurrentUserID);
        }

        SEL setUserIDsCurrentSEL =
            NSSelectorFromString(@"setUserIDs:currentUserID:");
        if ([appBadgingClass instancesRespondToSelector:setUserIDsCurrentSEL] &&
            !gOrigAppBadgingSetUserIDsCurrentUserID) {
            XLGHookMethod(appBadgingClass,
                          setUserIDsCurrentSEL,
                          NO,
                          (IMP)XLGAppBadgingSetUserIDsCurrentUserID,
                          &gOrigAppBadgingSetUserIDsCurrentUserID);
        }
    }

    Class itemClass = NSClassFromString(@"XNavigation.TabBarItemView");
    if (!itemClass) {
        itemClass = NSClassFromString(@"_TtC11XNavigation14TabBarItemView");
    }

    if (itemClass && !gOrigXNavItemLayout) {
        XLGHookMethod(itemClass,
                      @selector(layoutSubviews),
                      NO,
                      (IMP)XLGXNavItemLayout,
                      &gOrigXNavItemLayout);
    }

    if (!gXLGBadgeNotificationObserver) {
        gXLGBadgeNotificationObserver =
            [NSNotificationCenter.defaultCenter
                addObserverForName:nil
                           object:nil
                            queue:nil
                       usingBlock:^(NSNotification *notification) {
            NSString *name = notification.name ?: @"";
            NSString *lower = name.lowercaseString;
            if ([name isEqualToString:@"AccountBadgesDidChange"] ||
                [name isEqualToString:@"AppIconBadgeCountDidChange"] ||
                ([lower containsString:@"account"] &&
                 ([lower containsString:@"change"] ||
                  [lower containsString:@"active"] ||
                  [lower containsString:@"switch"]))) {
                XLGHandleBadgeNotification(notification);
            }
        }];
    }

    if (!gXLGDefaultsObserver) {
        gXLGDefaultsObserver =
            [NSNotificationCenter.defaultCenter
                addObserverForName:NSUserDefaultsDidChangeNotification
                           object:nil
                            queue:nil
                       usingBlock:^(__unused NSNotification *notification) {
            XLGRefreshGlobalTabBar();
        }];

        [NSNotificationCenter.defaultCenter
            addObserverForName:@"XLiquidGlassRefreshTabBar"
                       object:nil
                        queue:nil
                   usingBlock:^(__unused NSNotification *notification) {
            XLGRefreshGlobalTabBar();
        }];
    }

    XLGInstallBadgeReconciliationHooks();
    XLGInstallNativeT1TabBadgeBridge();
    XLGRefreshGlobalTabBar();
}


#pragma mark - XLiquidGlass Beta 5 XTabbedAppNavigation search router

static UIViewController *XLGXAppSearchRouteSourceViewController(void) {
    UIViewController *presenter=
        XLGSidebarContentPresentingViewController();
    UINavigationController *navigation=
        XLGNavigationControllerForPresenter(presenter);

    if (navigation.topViewController) {
        return navigation.topViewController;
    }
    return presenter ?: XLGSidebarPresenter();
}

static BOOL XLGXAppRouteSearchOptions(
    id self,
    id options,
    id completion,
    NSString *origin) {

    if (!XLGEnabled() || !self || !options) return NO;

    SEL targetSEL=NSSelectorFromString(
        @"showSearchControllerWithOptions:fromViewController:completion:");
    if (![self respondsToSelector:targetSEL]) {
        if (gXLGNavigationProbeActive) {
            XLGNavigationProbeLog(
                @"XAPP_SEARCH_ROUTER %@ failed=no-target-selector optionsClass=%@",
                origin ?: @"-",
                NSStringFromClass([options class]));
        }
        return NO;
    }

    UIViewController *fromViewController=
        XLGXAppSearchRouteSourceViewController();
    if (!fromViewController) {
        if (gXLGNavigationProbeActive) {
            XLGNavigationProbeLog(
                @"XAPP_SEARCH_ROUTER %@ failed=no-source-controller optionsClass=%@",
                origin ?: @"-",
                NSStringFromClass([options class]));
        }
        return NO;
    }

    if (gXLGNavigationProbeActive) {
        XLGNavigationProbeLog(
            @"XAPP_SEARCH_ROUTER %@ redirect optionsClass=%@ ptr=%p from=%@ ptr=%p target=%@",
            origin ?: @"-",
            NSStringFromClass([options class]),
            options,
            NSStringFromClass(fromViewController.class),
            fromViewController,
            NSStringFromSelector(targetSEL));
    }

    ((void(*)(id,SEL,id,id,id))objc_msgSend)(
        self,
        targetSEL,
        options,
        fromViewController,
        completion);

    return YES;
}

static void XLGXAppShowSearchResultsSource(
    id self,
    SEL cmd,
    id options,
    long long source,
    id completion) {

    if (XLGXAppRouteSearchOptions(
            self,
            options,
            completion,
            @"showSearchResultsWithOptions:source:completion:")) {
        return;
    }

    if (gOrigXAppShowSearchResultsSource) {
        ((void(*)(id,SEL,id,long long,id))
            gOrigXAppShowSearchResultsSource)(
                self,cmd,options,source,completion);
    }
}

static void XLGXAppShowSearchResultsFromPanel(
    id self,
    SEL cmd,
    id options,
    long long fromPanel,
    long long source,
    id completion) {

    if (XLGXAppRouteSearchOptions(
            self,
            options,
            completion,
            @"showSearchResultsWithOptions:fromPanel:source:completion:")) {
        return;
    }

    if (gOrigXAppShowSearchResultsFromPanel) {
        ((void(*)(id,SEL,id,long long,long long,id))
            gOrigXAppShowSearchResultsFromPanel)(
                self,cmd,options,fromPanel,source,completion);
    }
}

static void XLGInstallXAppSearchRouter(void) {
    if (gXLGXAppSearchRouterInstalled) return;

    Class cls=
        NSClassFromString(@"_TtC14T1TwitterSwift20XTabbedAppNavigation");
    if (!cls) return;

    SEL sourceSEL=NSSelectorFromString(
        @"showSearchResultsWithOptions:source:completion:");
    SEL fromPanelSEL=NSSelectorFromString(
        @"showSearchResultsWithOptions:fromPanel:source:completion:");

    BOOL sourceHooked=NO;
    BOOL fromPanelHooked=NO;

    Method sourceMethod=class_getInstanceMethod(cls,sourceSEL);
    if (sourceMethod &&
        method_getNumberOfArguments(sourceMethod)==5) {
        sourceHooked=XLGHookMethod(
            cls,
            sourceSEL,
            NO,
            (IMP)XLGXAppShowSearchResultsSource,
            &gOrigXAppShowSearchResultsSource);
    }

    Method fromPanelMethod=
        class_getInstanceMethod(cls,fromPanelSEL);
    if (fromPanelMethod &&
        method_getNumberOfArguments(fromPanelMethod)==6) {
        fromPanelHooked=XLGHookMethod(
            cls,
            fromPanelSEL,
            NO,
            (IMP)XLGXAppShowSearchResultsFromPanel,
            &gOrigXAppShowSearchResultsFromPanel);
    }

    gXLGXAppSearchRouterInstalled=
        sourceHooked || fromPanelHooked;
}


#pragma mark - XLiquidGlass 1.9.0 Beta 1 Premium routes

static id XLGDynamicGlobalObject(const char *symbolName) {
    if (!symbolName) return nil;
    void *address=dlsym(RTLD_DEFAULT,symbolName);
    if (!address) return nil;

    id __unsafe_unretained *slot=(id __unsafe_unretained *)address;
    return slot ? *slot : nil;
}

static id XLGPremiumScribeContext(void) {
    Class scribeClass=NSClassFromString(@"TFSTwitterScribeContext");
    SEL selector=NSSelectorFromString(
        @"scribeContextWithPage:section:component:element:");
    if (!scribeClass || ![scribeClass respondsToSelector:selector]) {
        return nil;
    }

    id page=XLGDynamicGlobalObject("TFSTwitterScribePagePremiumHub");
    id empty=XLGDynamicGlobalObject("TFSTwitterScribeSectionEmpty");

    if (!page) page=@"premium_hub";
    if (!empty) empty=@"";

    return ((id(*)(id,SEL,id,id,id,id))objc_msgSend)(
        scribeClass,selector,page,empty,empty,empty);
}

static BOOL XLGPremiumShouldAnimate(id appNavigation, long long source) {
    SEL selector=NSSelectorFromString(
        @"_shouldAnimatePresentationForSource:");
    if (appNavigation &&
        [appNavigation respondsToSelector:selector]) {
        return ((BOOL(*)(id,SEL,long long))objc_msgSend)(
            appNavigation,selector,source);
    }
    return YES;
}

static UIViewController *XLGPremiumCurrentPanelController(
    id appNavigation) {
    SEL selector=NSSelectorFromString(
        @"currentPanelNavigationController");
    if (appNavigation &&
        [appNavigation respondsToSelector:selector]) {
        id result=((id(*)(id,SEL))objc_msgSend)(
            appNavigation,selector);
        if ([result isKindOfClass:UIViewController.class]) {
            return result;
        }
    }

    return XLGSidebarContentPresentingViewController();
}

static BOOL XLGPremiumPresentController(
    id appNavigation,
    UIViewController *controller,
    long long source,
    id completion,
    NSString *routeName) {

    if (!controller) return NO;

    UIViewController *fromController=
        XLGPremiumCurrentPanelController(appNavigation);
    if (!fromController) return NO;

    BOOL animated=XLGPremiumShouldAnimate(appNavigation,source);
    SEL presentSEL=NSSelectorFromString(
        @"tfn_presentFromViewController:animated:completion:");

    if (gXLGNavigationProbeActive) {
        XLGNavigationProbeLog(
            @"PREMIUM_ROUTER route=%@ destination=%@ ptr=%p from=%@ ptr=%p animated=%@",
            routeName ?: @"-",
            NSStringFromClass(controller.class),
            controller,
            NSStringFromClass(fromController.class),
            fromController,
            animated ? @"YES" : @"NO");
    }

    if ([controller respondsToSelector:presentSEL]) {
        ((void(*)(id,SEL,id,BOOL,id))objc_msgSend)(
            controller,presentSEL,fromController,animated,completion);
        return YES;
    }

    UINavigationController *navigation=
        XLGNavigationControllerForPresenter(fromController);
    if (!navigation &&
        [fromController isKindOfClass:UINavigationController.class]) {
        navigation=(UINavigationController *)fromController;
    }

    if (!navigation) return NO;

    [navigation pushViewController:controller animated:animated];
    if (completion) {
        ((void(^)(void))completion)();
    }
    return YES;
}

static UIViewController *XLGPremiumControllerWithAccountAndScribe(
    NSString *className,
    id account,
    id scribeContext) {

    Class cls=NSClassFromString(className);
    if (!cls || !account) return nil;

    id allocated=((id(*)(id,SEL))objc_msgSend)(
        cls,@selector(alloc));
    SEL initSEL=NSSelectorFromString(
        @"initWithAccount:scribeContext:");
    if (![allocated respondsToSelector:initSEL]) {
        return nil;
    }

    id result=((id(*)(id,SEL,id,id))objc_msgSend)(
        allocated,initSEL,account,scribeContext);
    return [result isKindOfClass:UIViewController.class]
        ? result : nil;
}

static UIViewController *XLGPremiumAppIconController(
    id account,
    id scribeContext) {

    Class controllerClass=
        NSClassFromString(@"T1AppIconSettingsViewController");
    if (!controllerClass || !account) return nil;

    id customizer=nil;
    Class managerClass=
        NSClassFromString(@"T1AppCustomizationManager");
    SEL sharedSEL=NSSelectorFromString(@"sharedInstance");
    if (managerClass &&
        [managerClass respondsToSelector:sharedSEL]) {
        customizer=((id(*)(id,SEL))objc_msgSend)(
            managerClass,sharedSEL);
    }

    if (!customizer) {
        if (gXLGNavigationProbeActive) {
            XLGNavigationProbeLog(
                @"PREMIUM_ROUTER app-icon failed=no-appIconCustomizer");
        }
        return nil;
    }

    id allocated=((id(*)(id,SEL))objc_msgSend)(
        controllerClass,@selector(alloc));
    SEL initSEL=NSSelectorFromString(
        @"initWithAccount:scribeContext:appIconCustomizer:");
    if (![allocated respondsToSelector:initSEL]) {
        return nil;
    }

    id result=((id(*)(id,SEL,id,id,id))objc_msgSend)(
        allocated,initSEL,account,scribeContext,customizer);
    return [result isKindOfClass:UIViewController.class]
        ? result : nil;
}

static UIViewController *XLGPremiumDisplaySettingsController(
    id account) {

    Class controllerClass=
        NSClassFromString(@"T1DisplaySettingsViewController");
    if (!controllerClass || !account) return nil;

    id allocated=((id(*)(id,SEL))objc_msgSend)(
        controllerClass,@selector(alloc));
    SEL initSEL=NSSelectorFromString(@"initWithAccount:");
    if (![allocated respondsToSelector:initSEL]) {
        if (gXLGNavigationProbeActive) {
            XLGNavigationProbeLog(
                @"PREMIUM_ROUTER display-settings failed=missing-initWithAccount:");
        }
        return nil;
    }

    id result=((id(*)(id,SEL,id))objc_msgSend)(
        allocated,initSEL,account);

    if (gXLGNavigationProbeActive) {
        XLGNavigationProbeLog(
            @"PREMIUM_ROUTER display-settings controller-create class=%@ ptr=%p account=%@",
            result ? NSStringFromClass([result class]) : @"nil",
            result,
            NSStringFromClass([account class]));
    }

    return [result isKindOfClass:UIViewController.class]
        ? result : nil;
}

static BOOL XLGRoutePremiumDestination(
    id appNavigation,
    NSString *destinationClass,
    long long source,
    id completion,
    NSString *routeName) {

    if (!XLGEnabled()) return NO;

    id account=XLGSidebarCurrentAccount();
    id scribeContext=XLGPremiumScribeContext();
    UIViewController *controller=
        XLGPremiumControllerWithAccountAndScribe(
            destinationClass,account,scribeContext);

    if (!controller) {
        if (gXLGNavigationProbeActive) {
            XLGNavigationProbeLog(
                @"PREMIUM_ROUTER route=%@ failed=controller-create class=%@ account=%@",
                routeName ?: @"-",
                destinationClass ?: @"-",
                account ? NSStringFromClass([account class]) : @"nil");
        }
        return NO;
    }

    return XLGPremiumPresentController(
        appNavigation,controller,source,completion,routeName);
}

static void XLGXAppPremiumProfileCustomization(
    id self, SEL cmd, long long source, id completion) {

    if (XLGRoutePremiumDestination(
            self,
            @"T1ProfileCustomizationSettingsViewController",
            source,
            completion,
            @"profile-customization")) {
        return;
    }

    if (gOrigXAppPremiumProfileCustomization) {
        ((void(*)(id,SEL,long long,id))
            gOrigXAppPremiumProfileCustomization)(
                self,cmd,source,completion);
    }
}

static void XLGXAppPremiumCustomizeNavigation(
    id self, SEL cmd, long long source, id completion) {

    if (XLGRoutePremiumDestination(
            self,
            @"T1TabCustomizationViewController",
            source,
            completion,
            @"customize-navigation")) {
        return;
    }

    if (gOrigXAppPremiumCustomizeNavigation) {
        ((void(*)(id,SEL,long long,id))
            gOrigXAppPremiumCustomizeNavigation)(
                self,cmd,source,completion);
    }
}

static void XLGXAppPremiumAppIcon(
    id self, SEL cmd, long long source, id completion) {

    if (XLGEnabled()) {
        id account=XLGSidebarCurrentAccount();
        id scribeContext=XLGPremiumScribeContext();
        UIViewController *controller=
            XLGPremiumAppIconController(account,scribeContext);

        if (controller &&
            XLGPremiumPresentController(
                self,controller,source,completion,@"app-icon")) {
            return;
        }
    }

    if (gOrigXAppPremiumAppIcon) {
        ((void(*)(id,SEL,long long,id))
            gOrigXAppPremiumAppIcon)(
                self,cmd,source,completion);
    }
}

static BOOL XLGRouteDisplaySettings(
    id appNavigation,
    long long source,
    id completion,
    NSString *routeName) {

    if (!XLGEnabled()) return NO;

    id account=XLGSidebarCurrentAccount();
    UIViewController *controller=
        XLGPremiumDisplaySettingsController(account);

    if (!controller) {
        if (gXLGNavigationProbeActive) {
            XLGNavigationProbeLog(
                @"PREMIUM_ROUTER route=%@ failed=display-controller-create account=%@",
                routeName ?: @"-",
                account ? NSStringFromClass([account class]) : @"nil");
        }
        return NO;
    }

    return XLGPremiumPresentController(
        appNavigation,
        controller,
        source,
        completion,
        routeName);
}

static void XLGXAppShowDisplaySettings(
    id self, SEL cmd, long long source, id completion) {

    if (XLGRouteDisplaySettings(
            self,
            source,
            completion,
            @"display-settings")) {
        return;
    }

    if (gOrigXAppShowDisplaySettings) {
        ((void(*)(id,SEL,long long,id))
            gOrigXAppShowDisplaySettings)(
                self,cmd,source,completion);
    }
}

static void XLGXAppPremiumSettings(
    id self, SEL cmd, long long source, id completion) {

    if (XLGRouteDisplaySettings(
            self,
            source,
            completion,
            @"premium-display-settings")) {
        return;
    }

    if (gOrigXAppPremiumSettings) {
        ((void(*)(id,SEL,long long,id))
            gOrigXAppPremiumSettings)(
                self,cmd,source,completion);
    }
}

static void XLGInstallXAppPremiumRouter(void) {
    if (gXLGXAppPremiumRouterInstalled) return;

    Class cls=
        NSClassFromString(@"_TtC14T1TwitterSwift20XTabbedAppNavigation");
    if (!cls) return;

    struct {
        const char *selectorName;
        IMP replacement;
        IMP *original;
    } hooks[] = {
        {
            "showPremiumHubProfileCustomizationWithSource:withCompletion:",
            (IMP)XLGXAppPremiumProfileCustomization,
            &gOrigXAppPremiumProfileCustomization
        },
        {
            "showPremiumHubCustomizeNavigationWithSource:withCompletion:",
            (IMP)XLGXAppPremiumCustomizeNavigation,
            &gOrigXAppPremiumCustomizeNavigation
        },
        {
            "showPremiumHubAppIconWithSource:withCompletion:",
            (IMP)XLGXAppPremiumAppIcon,
            &gOrigXAppPremiumAppIcon
        },
        {
            "showPremiumHubPremiumSettingsWithSource:withCompletion:",
            (IMP)XLGXAppPremiumSettings,
            &gOrigXAppPremiumSettings
        },
        {
            "showDisplaySettingsWithSource:withCompletion:",
            (IMP)XLGXAppShowDisplaySettings,
            &gOrigXAppShowDisplaySettings
        }
    };

    BOOL any=NO;
    for (NSUInteger i=0;i<sizeof(hooks)/sizeof(hooks[0]);i++) {
        SEL selector=NSSelectorFromString(
            [NSString stringWithUTF8String:
                hooks[i].selectorName]);
        Method method=class_getInstanceMethod(cls,selector);
        if (!method || method_getNumberOfArguments(method)!=4) {
            continue;
        }

        BOOL hooked=XLGHookMethod(
            cls,
            selector,
            NO,
            hooks[i].replacement,
            hooks[i].original);
        any=any || hooked;
    }

    gXLGXAppPremiumRouterInstalled=any;
}

#pragma mark - XLiquidGlass 1.9.0 Beta 1 Search blur fix

static NSUInteger XLGRemoveSearchBlurViews(
    UIView *view,
    UIView *root,
    NSUInteger depth) {

    if (!view || depth>40) return 0;

    NSUInteger removed=0;
    if ([view isKindOfClass:UIVisualEffectView.class]) {
        UIVisualEffectView *effectView=
            (UIVisualEffectView *)view;
        CGRect frame=[effectView convertRect:effectView.bounds
                                      toView:root];

        BOOL nearTop=
            CGRectGetMaxY(frame)>0.0 &&
            CGRectGetMinY(frame)<240.0;

        if (nearTop && effectView.effect!=nil) {
            effectView.effect=nil;
            effectView.backgroundColor=UIColor.clearColor;
            removed++;
        }
    }

    for (UIView *subview in view.subviews ?: @[]) {
        removed+=XLGRemoveSearchBlurViews(
            subview,root,depth+1);
    }
    return removed;
}

static void XLGSearchContainerViewDidLayoutSubviews(
    id self,
    SEL cmd) {

    if (gOrigSearchContainerViewDidLayoutSubviews) {
        ((void(*)(id,SEL))
            gOrigSearchContainerViewDidLayoutSubviews)(
                self,cmd);
    }

    if (!XLGEnabled() ||
        ![self isKindOfClass:UIViewController.class]) {
        return;
    }

    UIViewController *controller=(UIViewController *)self;
    UIView *root=controller.view;
    if (!root) return;

    NSUInteger removed=
        XLGRemoveSearchBlurViews(root,root,0);

    if (removed>0 &&
        gXLGNavigationProbeActive &&
        ![objc_getAssociatedObject(
            controller,&kXLGSearchBlurLoggedKey) boolValue]) {

        objc_setAssociatedObject(
            controller,
            &kXLGSearchBlurLoggedKey,
            @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        XLGNavigationProbeLog(
            @"SEARCH_BLUR removed=%lu controller=%@ ptr=%p",
            (unsigned long)removed,
            NSStringFromClass(controller.class),
            controller);
    }
}

static void XLGInstallSearchBlurFix(void) {
    if (gXLGSearchBlurFixInstalled) return;

    Class cls=NSClassFromString(
        @"TTSSearchContainerViewControllerV2");
    if (!cls) return;

    SEL selector=@selector(viewDidLayoutSubviews);
    Method method=class_getInstanceMethod(cls,selector);
    if (!method) return;

    gXLGSearchBlurFixInstalled=
        XLGHookMethod(
            cls,
            selector,
            NO,
            (IMP)XLGSearchContainerViewDidLayoutSubviews,
            &gOrigSearchContainerViewDidLayoutSubviews);
}

static BOOL gXLGGuideRouterHookInstalled = NO;

static void XLGInstallGuideRouterHook(void) {
    if (gXLGGuideRouterHookInstalled) return;

    Class trendFactory=
        NSClassFromString(@"T1TrendingPageViewControllerFactory");
    SEL createSEL=
        NSSelectorFromString(@"createWithAccount:trendID:mode:");

    if (trendFactory &&
        XLGNavProbeMethodMatchesTrendingFactory(
            trendFactory,createSEL) &&
        !gOrigNavProbeTrendingFactoryCreate) {

        gXLGGuideRouterHookInstalled=
            XLGHookMethod(
                trendFactory,
                createSEL,
                YES,
                (IMP)XLGNavProbeTrendingFactoryCreate,
                &gOrigNavProbeTrendingFactoryCreate);
    }
}

static void XLGInstallHooks(void) {
    Class cls = Nil;

    if (!gDebugSettingsHooked) {
        cls = NSClassFromString(@"T1LiquidGlassDebugSettings");
        if (cls) {
            gDebugSettingsHooked =
                XLGHookMethod(cls,
                              NSSelectorFromString(@"useTabBarControllerEnabled"),
                              YES,
                              (IMP)XLGReturnState,
                              NULL);
        }
    }

    if (!gSwiftLiquidGlassHooked) {
        cls = NSClassFromString(@"_TtC17TFSUtilitiesSwift11LiquidGlass");
        if (cls) {
            gSwiftLiquidGlassHooked =
                XLGHookMethod(cls,
                              NSSelectorFromString(@"isEnabled"),
                              YES,
                              (IMP)XLGReturnState,
                              NULL);
        }
    }

    if (!gRedesignFeaturesHooked) {
        cls = NSClassFromString(@"_TtC14T1TwitterSwift27LiquidGlassRedesignFeatures");
        if (cls) {
            gRedesignFeaturesHooked =
                XLGHookMethod(cls,
                              NSSelectorFromString(@"isRedesignEnabled"),
                              NO,
                              (IMP)XLGReturnState,
                              NULL);
        }
    }

    cls = NSClassFromString(@"T1LiquidGlassGateInstaller");
    if (cls) {
        if (!gInstallGateHooked) {
            gInstallGateHooked =
                XLGHookMethod(cls,
                              NSSelectorFromString(@"installGateWithRedesignEnabled:"),
                              YES,
                              (IMP)XLGInstallGateWithRedesignEnabled,
                              &gOrigInstallGate);
        }

        if (!gInstallGateForAccountHooked) {
            gInstallGateForAccountHooked =
                XLGHookMethod(cls,
                              NSSelectorFromString(@"installGateForAccount:"),
                              YES,
                              (IMP)XLGInstallGateForAccount,
                              &gOrigInstallGateForAccount);
        }
    }

    if (!gDummyFeatureHooked) {
        cls = NSClassFromString(@"TFNTwitterAccount");
        if (cls) {
            gDummyFeatureHooked =
                XLGHookMethod(cls,
                              NSSelectorFromString(@"isDummyTest1FeatureEnabled"),
                              NO,
                              (IMP)XLGDummyTest1Feature,
                              &gOrigDummyFeature);
        }
    }

    XLGSyncCompatibilityGate();
    // Beta 21: do not install our extra UIScreenEdgePanGestureRecognizer.
    // X 12.28.1 already owns a UIPanGestureRecognizer on T1Window; Beta 20
    // proved both were recognizing the same left-edge swipe simultaneously.
    XLGB6InstallCorrectionHooks();
    XLGInstallGlobalTabBarFixes();
    XLGInstallNFBSettingsIntegration();
    XLGInstallOwnNotificationRouter();
    XLGInstallXAppSearchRouter();
    XLGInstallXAppPremiumRouter();
    XLGInstallSearchBlurFix();
    XLGInstallGuideRouterHook();
    XLGInstallCompositionSentToastBridge();
    XLGInstallToastBridge();
}

static void XLGScheduleRetry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            XLGInstallHooks();
        }
    );
}

__attribute__((constructor))
static void XLiquidGlassInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlass] 1.9.3 Beta 6.9 loaded: Swift symbol source probe + 1.9.2 stable feature set");

        NSString *beta6Log=XLGB6LogPath();
        if (beta6Log.length) {
            [NSFileManager.defaultManager removeItemAtPath:beta6Log error:nil];
        }
        XLGB6Log(@"========== XLiquidGlass 1.9.3 Beta 6.6 Pre-View Native Panel Bridge + Probe ==========");
        XLGB6Log(@"BOOT liquidGlass=%@ bh_tabs_visible=%@",
                 XLGEnabled() ? @"ON" : @"OFF",
                 [XLGB6DesiredPages() componentsJoinedByString:@","] ?: @"nil");

        XLGInstallHooks();
        XLGScheduleRetry(0.00);
        XLGScheduleRetry(0.05);
        XLGScheduleRetry(0.20);
        XLGScheduleRetry(0.50);
        XLGScheduleRetry(1.00);
        XLGScheduleRetry(2.00);
        XLGScheduleRetry(4.00);
    }
}
