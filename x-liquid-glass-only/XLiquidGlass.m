#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kXLGEnabledKey = @"XLiquidGlassEnabled";
static NSString *const kXLGPersistedGateKey = @"T1LiquidGlassRedesignPersistedGate";
static NSString *const kXLGTabLabelsKey = @"XLiquidGlassTabLabelsEnabled";
static NSString *const kXLGTabBarColorModeKey = @"XLiquidGlassTabBarColorMode";

typedef NS_ENUM(NSInteger, XLGTabBarColorMode) {
    XLGTabBarColorModeNative = 0,
    XLGTabBarColorModeActiveOnly = 1,
    XLGTabBarColorModeAllTabs = 2,
};

static IMP gOrigInstallGate = NULL;
static IMP gOrigInstallGateForAccount = NULL;
static IMP gOrigDummyFeature = NULL;
static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;

static BOOL gDebugSettingsHooked = NO;
static BOOL gSwiftLiquidGlassHooked = NO;
static BOOL gRedesignFeaturesHooked = NO;
static BOOL gInstallGateHooked = NO;
static BOOL gInstallGateForAccountHooked = NO;
static BOOL gDummyFeatureHooked = NO;
static BOOL gNFBSettingsHooked = NO;
static BOOL gXLGAllowTabColorHook = NO;

static void XLGRefreshXNavigationColorModeNow(void);

static BOOL XLGEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:kXLGEnabledKey];
    return stored ? [stored boolValue] : YES;
}

static BOOL XLGTabLabelsEnabled(void) {
    NSUserDefaults *defaults=[NSUserDefaults standardUserDefaults];
    id stored=[defaults objectForKey:kXLGTabLabelsKey];
    return stored ? [stored boolValue] : NO;
}

static XLGTabBarColorMode XLGTabBarColorModeValue(void) {
    NSUserDefaults *defaults=[NSUserDefaults standardUserDefaults];
    id stored=[defaults objectForKey:kXLGTabBarColorModeKey];
    NSInteger value=stored ? [stored integerValue] : XLGTabBarColorModeNative;
    if (value < XLGTabBarColorModeNative || value > XLGTabBarColorModeAllTabs) {
        value=XLGTabBarColorModeNative;
    }
    return (XLGTabBarColorMode)value;
}

static NSString *XLGTabBarColorModeTitle(XLGTabBarColorMode mode) {
    switch (mode) {
        case XLGTabBarColorModeActiveOnly:
            return @"Aba ativa";
        case XLGTabBarColorModeAllTabs:
            return @"Todas as abas";
        case XLGTabBarColorModeNative:
        default:
            return @"Nativa";
    }
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
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return @"Quando uma alteração exigir reinício, o X exibirá um aviso.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row == 1) {
        static NSString *selectorIdentifier = @"XLiquidGlassSelectorCell";
        UITableViewCell *cell =
            [tableView dequeueReusableCellWithIdentifier:selectorIdentifier];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                          reuseIdentifier:selectorIdentifier];
        }

        cell.textLabel.text = @"Cor do tema na Tab Bar";
        cell.detailTextLabel.text =
            XLGTabBarColorModeTitle(XLGTabBarColorModeValue());
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    static NSString *toggleIdentifier = @"XLiquidGlassToggleCell";
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:toggleIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:toggleIdentifier];
    }

    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];

    if (indexPath.row == 0) {
        cell.textLabel.text = @"Ativar Liquid Glass";
        cell.detailTextLabel.text = @"Usa o redesign nativo presente no X.";
        toggle.on = XLGEnabled();
        [toggle addTarget:self
                   action:@selector(xlgLiquidGlassToggleChanged:)
         forControlEvents:UIControlEventValueChanged];
    } else {
        cell.textLabel.text = @"Mostrar rótulos da Tab Bar";
        cell.detailTextLabel.text = @"Exibe os nomes das abas no modo Liquid Glass.";
        toggle.on = XLGTabLabelsEnabled();
        [toggle addTarget:self
                   action:@selector(xlgTabLabelsToggleChanged:)
         forControlEvents:UIControlEventValueChanged];
    }

    cell.accessoryView = toggle;
    return cell;
}

- (void)xlgLiquidGlassToggleChanged:(UISwitch *)sender {
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

- (void)xlgSelectTabBarColorMode:(XLGTabBarColorMode)newMode {
    XLGTabBarColorMode oldMode=XLGTabBarColorModeValue();
    if (newMode == oldMode) return;

    [[NSUserDefaults standardUserDefaults]
        setInteger:newMode
            forKey:kXLGTabBarColorModeKey];

    [self.tableView reloadRowsAtIndexPaths:@[
        [NSIndexPath indexPathForRow:1 inSection:0]
    ] withRowAnimation:UITableViewRowAnimationNone];

    BOOL desiredHook=(newMode != XLGTabBarColorModeNative);
    BOOL requiresRestart=(desiredHook != gXLGAllowTabColorHook);

    if (requiresRestart) {
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Reinício necessário"
                                                message:@"Reinicie o X para aplicar completamente esta alteração."
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                 style:UIAlertActionStyleDefault
                                               handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else if (newMode != XLGTabBarColorModeNative) {
        XLGRefreshXNavigationColorModeNow();
    }
}

- (void)xlgShowTabBarColorModeSelector {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"Cor do tema na Tab Bar"
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSDictionary *> *options=@[
        @{@"title": @"Nativa", @"value": @(XLGTabBarColorModeNative)},
        @{@"title": @"Aba ativa", @"value": @(XLGTabBarColorModeActiveOnly)},
        @{@"title": @"Todas as abas", @"value": @(XLGTabBarColorModeAllTabs)}
    ];

    __weak typeof(self) weakSelf=self;
    for (NSDictionary *option in options) {
        NSString *title=option[@"title"];
        XLGTabBarColorMode mode=(XLGTabBarColorMode)[option[@"value"] integerValue];

        [sheet addAction:
            [UIAlertAction actionWithTitle:title
                                     style:UIAlertActionStyleDefault
                                   handler:^(__unused UIAlertAction *action) {
                [weakSelf xlgSelectTabBarColorMode:mode];
            }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    UIPopoverPresentationController *popover=sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView=self.view;
        popover.sourceRect=CGRectMake(
            CGRectGetMidX(self.view.bounds),
            CGRectGetMidY(self.view.bounds),
            1.0,
            1.0);
        popover.permittedArrowDirections=0;
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 && indexPath.row == 1) {
        [self xlgShowTabBarColorModeSelector];
    }
}

- (void)xlgTabLabelsToggleChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:kXLGTabLabelsKey];

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Liquid Glass"
                                            message:@"A alteração dos rótulos será aplicada ao voltar para a timeline."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

static BOOL XLGSectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"action"] isEqualToString:@"showXLiquidGlassSettings"]) {
            return YES;
        }
    }
    return NO;
}

static void XLGInjectNFBSection(id controller) {
    NSArray *sections = nil;

    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        return;
    }

    if (![sections isKindOfClass:NSArray.class] || XLGSectionsContainEntry(sections)) {
        return;
    }

    NSMutableArray *updated = [sections mutableCopy];
    NSDictionary *entry = @{
        @"title": @"Liquid Glass",
        @"subtitle": @"Ativar ou desativar o redesign Liquid Glass.",
        @"icon": @"paintbrush_stroke",
        @"action": @"showXLiquidGlassSettings"
    };

    NSUInteger insertIndex = MIN((NSUInteger)2, updated.count);
    [updated insertObject:entry atIndex:insertIndex];

    @try {
        [controller setValue:[updated copy] forKey:@"sections"];
    } @catch (__unused NSException *exception) {
    }
}

static void XLGNFBSetupSections(id self, SEL _cmd) {
    if (gOrigNFBSetupSections) {
        ((void (*)(id, SEL))gOrigNFBSetupSections)(self, _cmd);
    }
    XLGInjectNFBSection(self);
}

static void XLGNFBViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigNFBViewWillAppear) {
        ((void (*)(id, SEL, BOOL))gOrigNFBViewWillAppear)(self, _cmd, animated);
    }
    XLGInjectNFBSection(self);

    UITableView *tableView = nil;
    @try {
        tableView = [self valueForKey:@"tableView"];
    } @catch (__unused NSException *exception) {
    }
    [tableView reloadData];
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

static void XLGInstallNFBSettingsIntegration(void) {
    if (gNFBSettingsHooked) return;

    Class cls = NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;

    SEL showSEL = NSSelectorFromString(@"showXLiquidGlassSettings");
    class_addMethod(cls, showSEL, (IMP)XLGShowSettings, "v@:");

    BOOL setupHooked =
        XLGHookMethod(cls,
                      NSSelectorFromString(@"setupSections"),
                      NO,
                      (IMP)XLGNFBSetupSections,
                      &gOrigNFBSetupSections);

    BOOL appearHooked =
        XLGHookMethod(cls,
                      @selector(viewWillAppear:),
                      NO,
                      (IMP)XLGNFBViewWillAppear,
                      &gOrigNFBViewWillAppear);

    gNFBSettingsHooked = setupHooked || appearHooked;
}



#pragma mark - Liquid Glass sidebar swipe fix

static IMP gOrigTabLoad = NULL;
static IMP gOrigTabAppear = NULL;
static char kXLGSidebarEdgePanKey;

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
    // Exact Moe behavior: presentation starts as soon as the left-edge
    // recognizer enters Began.
    if (gesture.state==UIGestureRecognizerStateBegan) {
        [self xlg_presentAnimated:YES];
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    (void)gestureRecognizer;
    return XLGEnabled() && self.drawer==nil && !self.presenting;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
 shouldRecognizeSimultaneouslyWithGestureRecognizer:
    (UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
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
    dispatch_block_t route=^{
        XLGRouteContentViewController(viewController);
    };

    // Moe gives X's own dismissDashBlock priority. That block restores the host
    // navigation state before routing the selected sidebar destination.
    if (dismissDashBlock) {
        void (^dismiss)(BOOL,dispatch_block_t)=dismissDashBlock;
        dismiss(YES,route);
    } else {
        [self xlg_dismissAnimated:YES completion:route];
    }
}

- (void)dashContentPresenterPresentModalViewController:(UIViewController *)viewController
                                      dismissDashBlock:(id)dismissDashBlock {
    dispatch_block_t route=^{
        XLGRouteModalViewController(viewController);
    };

    if (dismissDashBlock) {
        void (^dismiss)(BOOL,dispatch_block_t)=dismissDashBlock;
        dismiss(YES,route);
    } else {
        [self xlg_dismissAnimated:YES completion:route];
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

static void XLGInstallSidebarFix(void) {
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


#pragma mark - Liquid Glass Tab Bar badge fixes

static IMP gOrigLGBadgeViewDidLoad = NULL;
static IMP gOrigLGBadgeViewDidAppear = NULL;
static IMP gOrigLGBadgeSetTabViews = NULL;
static IMP gOrigLGBadgeSyncTabBarItems = NULL;
static IMP gOrigLGBadgeSyncBadges = NULL;
static IMP gOrigLGBadgeTraitCollectionDidChange = NULL;
static IMP gOrigLGBadgeViewDidLayoutSubviews = NULL;

static char kXLGCompactBadgeAppearanceAppliedKey;

static void XLGApplyLiquidGlassTabBarVisualFixes(id controller);

static void XLGInvalidateLiquidGlassCompactBadge(id controller) {
    if (!controller) return;
    objc_setAssociatedObject(
        controller,
        &kXLGCompactBadgeAppearanceAppliedKey,
        nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
}

static void XLGNormalizeLiquidGlassUnreadBadgeValues(id controller) {
    if (!controller || !XLGEnabled()) return;

    SEL viewControllersSEL=NSSelectorFromString(@"viewControllers");
    if (![controller respondsToSelector:viewControllersSEL]) return;

    id value=((id(*)(id,SEL))objc_msgSend)(controller,viewControllersSEL);
    if (![value isKindOfClass:NSArray.class]) return;

    NSCharacterSet *whitespace=[NSCharacterSet whitespaceAndNewlineCharacterSet];

    for (id viewController in (NSArray *)value) {
        if (![viewController isKindOfClass:UIViewController.class]) continue;

        UITabBarItem *item=((UIViewController *)viewController).tabBarItem;
        if (!item) continue;

        NSString *badge=item.badgeValue;
        if (![badge isKindOfClass:NSString.class]) continue;

        NSString *trimmed=[badge stringByTrimmingCharactersInSet:whitespace];
        if (trimmed.length==0) {
            item.badgeValue=nil;
        }
    }
}

static void XLGApplyCompactBadgeToStateAppearance(UITabBarItemStateAppearance *state) {
    if (!state) return;

    NSMutableDictionary<NSAttributedStringKey,id> *attributes=
        [state.badgeTextAttributes mutableCopy] ?: [NSMutableDictionary dictionary];

    attributes[NSFontAttributeName]=
        [UIFont systemFontOfSize:9.0 weight:UIFontWeightBold];

    if (!attributes[NSForegroundColorAttributeName]) {
        attributes[NSForegroundColorAttributeName]=UIColor.whiteColor;
    }

    state.badgeTextAttributes=[attributes copy];
}

static void XLGApplyCompactBadgeToItemAppearance(UITabBarItemAppearance *itemAppearance) {
    if (!itemAppearance) return;

    XLGApplyCompactBadgeToStateAppearance(itemAppearance.normal);
    XLGApplyCompactBadgeToStateAppearance(itemAppearance.selected);
    XLGApplyCompactBadgeToStateAppearance(itemAppearance.disabled);
    XLGApplyCompactBadgeToStateAppearance(itemAppearance.focused);
}

static void XLGApplyCompactBadgeToAppearance(UITabBarAppearance *appearance) {
    if (!appearance) return;

    XLGApplyCompactBadgeToItemAppearance(appearance.stackedLayoutAppearance);
    XLGApplyCompactBadgeToItemAppearance(appearance.inlineLayoutAppearance);
    XLGApplyCompactBadgeToItemAppearance(appearance.compactInlineLayoutAppearance);
}

static void XLGNormalizeLiquidGlassBadges(id controller) {
    if (!controller || !XLGEnabled()) return;

    Class liquidClass=NSClassFromString(@"T1LiquidGlassTabBarController");
    if (liquidClass && ![controller isKindOfClass:liquidClass]) return;

    if (![controller isKindOfClass:UIViewController.class]) return;
    UIViewController *viewController=(UIViewController *)controller;
    if (!viewController.isViewLoaded) return;

    // Moe normalizes unread values before touching appearance.
    XLGNormalizeLiquidGlassUnreadBadgeValues(controller);

    SEL tabBarSEL=NSSelectorFromString(@"tabBar");
    if (![controller respondsToSelector:tabBarSEL]) return;

    id tabBarObject=((id(*)(id,SEL))objc_msgSend)(controller,tabBarSEL);
    if (![tabBarObject isKindOfClass:UITabBar.class]) return;
    UITabBar *tabBar=(UITabBar *)tabBarObject;

    NSNumber *alreadyApplied=
        objc_getAssociatedObject(controller,&kXLGCompactBadgeAppearanceAppliedKey);
    if (alreadyApplied.boolValue) return;

    UITabBarAppearance *appearance=[tabBar.standardAppearance copy];
    if (!appearance) appearance=[UITabBarAppearance new];

    XLGApplyCompactBadgeToAppearance(appearance);

    tabBar.standardAppearance=appearance;
    if (@available(iOS 15.0,*)) {
        tabBar.scrollEdgeAppearance=appearance;
    }

    objc_setAssociatedObject(
        controller,
        &kXLGCompactBadgeAppearanceAppliedKey,
        @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
}

static void XLGScheduleLiquidGlassBadgeRefresh(id controller) {
    if (!controller || !XLGEnabled()) return;

    __weak id weakController=controller;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.05*NSEC_PER_SEC)),
        dispatch_get_main_queue(),^{
            id strongController=weakController;
            if (!strongController) return;
            XLGInvalidateLiquidGlassCompactBadge(strongController);
            XLGNormalizeLiquidGlassBadges(strongController);
            XLGApplyLiquidGlassTabBarVisualFixes(strongController);
        }
    );

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.25*NSEC_PER_SEC)),
        dispatch_get_main_queue(),^{
            id strongController=weakController;
            if (!strongController) return;
            XLGInvalidateLiquidGlassCompactBadge(strongController);
            XLGNormalizeLiquidGlassBadges(strongController);
            XLGApplyLiquidGlassTabBarVisualFixes(strongController);
        }
    );
}


#pragma mark - Liquid Glass Tab Bar visual fixes

static char kXLGInjectedTabLabelKey;

static UIColor *XLGResolvedAccentColor(id controller, UITabBar *tabBar) {
    // 1.5.0 Theme Accent Fix:
    // Resolve the same primary color selected by X/NFB before falling back
    // to UIKit tint. This preserves the original 1.5.0 visual pipeline.
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    NSInteger option=0;

    id nfb=[defaults objectForKey:@"bh_color_theme_selectedColor"];
    if ([nfb respondsToSelector:@selector(integerValue)]) {
        option=[nfb integerValue];
    } else {
        id native=[defaults objectForKey:@"T1ColorSettingsPrimaryColorOptionKey"];
        if ([native respondsToSelector:@selector(integerValue)]) {
            option=[native integerValue];
        }
    }

    if (option<1) option=1;

    Class settingsClass=NSClassFromString(@"TAEColorSettings");
    SEL sharedSEL=NSSelectorFromString(@"sharedSettings");
    if (settingsClass && [settingsClass respondsToSelector:sharedSEL]) {
        id settings=((id(*)(id,SEL))objc_msgSend)(settingsClass,sharedSEL);
        SEL infoSEL=NSSelectorFromString(@"currentColorPalette");
        id info=(settings && [settings respondsToSelector:infoSEL])
            ? ((id(*)(id,SEL))objc_msgSend)(settings,infoSEL)
            : nil;
        SEL paletteSEL=NSSelectorFromString(@"colorPalette");
        id palette=(info && [info respondsToSelector:paletteSEL])
            ? ((id(*)(id,SEL))objc_msgSend)(info,paletteSEL)
            : nil;
        SEL primarySEL=NSSelectorFromString(@"primaryColorForOption:");
        if (palette && [palette respondsToSelector:primarySEL]) {
            id themeColor=((id(*)(id,SEL,NSUInteger))objc_msgSend)(
                palette,primarySEL,(NSUInteger)option);
            if ([themeColor isKindOfClass:UIColor.class]) {
                return themeColor;
            }
        }
    }

    // Preserve the exact 1.5.0 fallback behavior if the theme palette is
    // unavailable for any reason.
    UIColor *color=nil;

    if ([controller isKindOfClass:UIViewController.class]) {
        UIViewController *vc=(UIViewController *)controller;
        if (vc.isViewLoaded) color=vc.view.tintColor;
    }

    if (!color) color=tabBar.tintColor;

    UIWindow *window=tabBar.window;
    if (!color && window) color=window.tintColor;

    return color ?: UIColor.systemBlueColor;
}

static NSArray<UIView *> *XLGCollectViewsMatching(UIView *root, BOOL (^predicate)(UIView *view)) {
    if (!root || !predicate) return @[];

    NSMutableArray<UIView *> *result=[NSMutableArray array];
    NSMutableArray<UIView *> *queue=[NSMutableArray arrayWithObject:root];

    for (NSUInteger i=0;i<queue.count && i<512;i++) {
        UIView *view=queue[i];
        if (predicate(view)) [result addObject:view];
        for (UIView *subview in view.subviews ?: @[]) {
            [queue addObject:subview];
        }
    }

    return result;
}

static NSArray<UIView *> *XLGSystemTabButtons(UITabBar *tabBar) {
    NSArray<UIView *> *buttons=
        XLGCollectViewsMatching(tabBar,^BOOL(UIView *view) {
            NSString *name=NSStringFromClass(view.class);
            return [name containsString:@"UITabBarButton"] ||
                   [name containsString:@"TabBarButton"];
        });

    return [buttons sortedArrayUsingComparator:^NSComparisonResult(UIView *a,UIView *b) {
        CGFloat ax=CGRectGetMidX([a convertRect:a.bounds toView:tabBar]);
        CGFloat bx=CGRectGetMidX([b convertRect:b.bounds toView:tabBar]);
        if (ax<bx) return NSOrderedAscending;
        if (ax>bx) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static UIView *XLGFindLiquidSelectionChrome(UIView *root) {
    if (!root) return nil;

    NSArray<UIView *> *matches=
        XLGCollectViewsMatching(root,^BOOL(UIView *view) {
            NSString *name=NSStringFromClass(view.class);
            return [name containsString:@"_UITabSelectionView"] ||
                   [name containsString:@"TabSelectionView"] ||
                   [name containsString:@"TabSelection"] ||
                   [name containsString:@"_UITabBarPlatterView"];
        });

    return matches.firstObject;
}


static UIColor *XLGNativeInactiveTabColor(void) {
    Class tabViewClass=NSClassFromString(@"T1TabView");
    SEL itemColorSEL=NSSelectorFromString(@"itemColor");
    if (tabViewClass && [tabViewClass respondsToSelector:itemColorSEL]) {
        id color=((id(*)(id,SEL))objc_msgSend)(tabViewClass,itemColorSEL);
        if ([color isKindOfClass:UIColor.class]) return color;
    }
    return UIColor.secondaryLabelColor;
}

static NSArray<UIView *> *XLGXNavigationTabItems(UIView *bar) {
    NSArray<UIView *> *items=
        XLGCollectViewsMatching(bar,^BOOL(UIView *view) {
            NSString *name=NSStringFromClass(view.class);
            return [name isEqualToString:@"XNavigation.TabBarItemView"] ||
                   [name containsString:@"TabBarItemView"];
        });

    return [items sortedArrayUsingComparator:^NSComparisonResult(UIView *a,UIView *b) {
        CGFloat ax=CGRectGetMidX([a convertRect:a.bounds toView:bar]);
        CGFloat bx=CGRectGetMidX([b convertRect:b.bounds toView:bar]);
        if (ax<bx) return NSOrderedAscending;
        if (ax>bx) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static BOOL XLGXNavigationItemLooksSelected(UIView *item,
                                            UIView *bar,
                                            UIView *chrome) {
    if (!item || !bar) return NO;

    if ((item.accessibilityTraits & UIAccessibilityTraitSelected) != 0) {
        return YES;
    }

    if ([item isKindOfClass:UIControl.class]) {
        UIControl *control=(UIControl *)item;
        if (control.selected || control.highlighted) return YES;
    }

    if (chrome && !chrome.hidden && chrome.alpha>0.01) {
        CGRect itemFrame=[item convertRect:item.bounds toView:bar];
        CGRect chromeFrame=[chrome convertRect:chrome.bounds toView:bar];
        CGRect intersection=CGRectIntersection(itemFrame,chromeFrame);
        if (!CGRectIsNull(intersection) && !CGRectIsEmpty(intersection)) {
            CGFloat itemArea=MAX(1.0,itemFrame.size.width*itemFrame.size.height);
            CGFloat overlap=intersection.size.width*intersection.size.height;
            if ((overlap/itemArea)>0.20) return YES;
        }
    }

    return NO;
}

static void XLGApplyActiveOnlyToXNavigationTabBar(UIView *bar,
                                                   UIColor *accent) {
    if (!bar || !accent) return;

    UIView *chrome=XLGFindLiquidSelectionChrome(bar);
    UIColor *inactive=XLGNativeInactiveTabColor();
    NSArray<UIView *> *items=XLGXNavigationTabItems(bar);

    for (UIView *item in items) {
        BOOL selected=XLGXNavigationItemLooksSelected(item,bar,chrome);
        UIColor *color=selected ? accent : inactive;

        XLGTintImageViews(item,color,NO);
        item.tintColor=color;

        for (UIView *subview in item.subviews ?: @[]) {
            if ([subview isKindOfClass:UILabel.class]) {
                ((UILabel *)subview).textColor=color;
            }
        }
    }
}

static void XLGRefreshXNavigationColorModeNow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;

            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window || window.hidden) continue;

                NSArray<UIView *> *bars=
                    XLGCollectViewsMatching(window,^BOOL(UIView *view) {
                        NSString *name=NSStringFromClass(view.class);
                        return [name isEqualToString:@"XNavigation.TabBarView"] ||
                               [name isEqualToString:@"_TtC11XNavigation10TabBarView"];
                    });

                for (UIView *bar in bars) {
                    [bar setNeedsLayout];
                    [bar layoutIfNeeded];
                }
            }
        }
    });
}

static BOOL XLGViewLooksSelected(UIView *button, UITabBar *tabBar, NSUInteger index) {
    if ([button isKindOfClass:UIControl.class]) {
        UIControl *control=(UIControl *)button;
        if (control.selected || control.highlighted) return YES;
    }

    if ((button.accessibilityTraits & UIAccessibilityTraitSelected) != 0) return YES;

    if (index < tabBar.items.count && tabBar.selectedItem == tabBar.items[index]) return YES;

    UIView *chrome=XLGFindLiquidSelectionChrome(tabBar);
    if (chrome && !chrome.hidden && chrome.alpha>0.01) {
        CGRect buttonFrame=[button convertRect:button.bounds toView:tabBar];
        CGRect chromeFrame=[chrome convertRect:chrome.bounds toView:tabBar];
        if (CGRectIntersectsRect(buttonFrame,chromeFrame)) return YES;
    }

    return NO;
}

static BOOL XLGTitleLooksLikeProfile(NSString *title) {
    if (![title isKindOfClass:NSString.class] || title.length==0) return NO;
    NSString *s=title.lowercaseString;
    return [s containsString:@"profile"] ||
           [s containsString:@"perfil"] ||
           [s containsString:@"account"] ||
           [s containsString:@"conta"];
}

static void XLGStripAvatarCircleStyling(UIView *view) {
    if (!view) return;

    CALayer *layer=view.layer;
    layer.cornerRadius=0.0;
    layer.masksToBounds=NO;
    layer.borderWidth=0.0;
    layer.borderColor=UIColor.clearColor.CGColor;
    layer.shadowOpacity=0.0;
    layer.shadowRadius=0.0;
    layer.backgroundColor=UIColor.clearColor.CGColor;
    view.backgroundColor=UIColor.clearColor;

    // Moe also neutralizes decorative circular sublayers around the avatar.
    for (CALayer *sublayer in layer.sublayers ?: @[]) {
        if (sublayer.cornerRadius>0.0 ||
            sublayer.borderWidth>0.0 ||
            sublayer.shadowOpacity>0.0) {
            sublayer.hidden=YES;
            sublayer.opacity=0.0;
            sublayer.borderWidth=0.0;
            sublayer.cornerRadius=0.0;
            sublayer.masksToBounds=NO;
        }
    }
}

static void XLGTintImageViews(UIView *root, UIColor *color, BOOL stripAvatar) {
    if (!root || !color) return;

    if ([root isKindOfClass:UIImageView.class]) {
        UIImageView *imageView=(UIImageView *)root;
        UIImage *image=imageView.image;
        if (image && image.renderingMode != UIImageRenderingModeAlwaysTemplate) {
            imageView.image=[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        imageView.tintColor=color;
        if (stripAvatar) XLGStripAvatarCircleStyling(imageView);
    }

    for (UIView *subview in root.subviews ?: @[]) {
        XLGTintImageViews(subview,color,stripAvatar);
    }
}

static void XLGApplySelectedAccentToItemAppearance(UITabBarItemAppearance *appearance,
                                                   UIColor *accent) {
    if (!appearance || !accent) return;

    appearance.selected.iconColor=accent;

    NSMutableDictionary<NSAttributedStringKey,id> *selected=
        [appearance.selected.titleTextAttributes mutableCopy] ?:
        [NSMutableDictionary dictionary];
    selected[NSForegroundColorAttributeName]=accent;
    appearance.selected.titleTextAttributes=selected;

    UIColor *secondary=UIColor.secondaryLabelColor;
    if (!appearance.normal.iconColor) appearance.normal.iconColor=secondary;

    NSMutableDictionary<NSAttributedStringKey,id> *normal=
        [appearance.normal.titleTextAttributes mutableCopy] ?:
        [NSMutableDictionary dictionary];
    if (!normal[NSForegroundColorAttributeName]) {
        normal[NSForegroundColorAttributeName]=secondary;
    }
    appearance.normal.titleTextAttributes=normal;
}

static void XLGApplyAccentToTabBar(UITabBar *tabBar, UIColor *accent) {
    if (!tabBar || !accent) return;

    tabBar.tintColor=accent;
    if (!tabBar.unselectedItemTintColor) {
        tabBar.unselectedItemTintColor=UIColor.secondaryLabelColor;
    }

    UITabBarAppearance *appearance=[tabBar.standardAppearance copy];
    if (!appearance) appearance=[UITabBarAppearance new];

    XLGApplySelectedAccentToItemAppearance(appearance.stackedLayoutAppearance,accent);
    XLGApplySelectedAccentToItemAppearance(appearance.inlineLayoutAppearance,accent);
    XLGApplySelectedAccentToItemAppearance(appearance.compactInlineLayoutAppearance,accent);

    // Preserve the badge fixes already applied by 1.4.0.
    XLGApplyCompactBadgeToAppearance(appearance);

    tabBar.standardAppearance=appearance;
    if (@available(iOS 15.0,*)) {
        tabBar.scrollEdgeAppearance=appearance;
    }
}

static void XLGApplySelectionChrome(UIView *chrome, UIColor *accent) {
    if (!chrome || !accent) return;

    chrome.tintColor=accent;

    UIColor *background=chrome.backgroundColor;
    CGFloat r=0,g=0,b=0,a=0;
    BOOL resolved=[background getRed:&r green:&g blue:&b alpha:&a];
    if (!resolved) {
        CGFloat w=0;
        resolved=[background getWhite:&w alpha:&a];
    }

    // Preserve Apple's glass translucency; replace only the hue.
    if (resolved && a>0.01) {
        chrome.backgroundColor=[accent colorWithAlphaComponent:a];
    }

    for (UIView *subview in chrome.subviews ?: @[]) {
        subview.tintColor=accent;
    }
}

static UILabel *XLGInjectedLabelForButton(UIView *button, BOOL create) {
    UILabel *label=objc_getAssociatedObject(button,&kXLGInjectedTabLabelKey);
    if (label || !create) return label;

    label=[[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints=NO;
    label.font=[UIFont systemFontOfSize:10.0 weight:UIFontWeightMedium];
    label.textAlignment=NSTextAlignmentCenter;
    label.adjustsFontSizeToFitWidth=YES;
    label.minimumScaleFactor=0.75;
    label.lineBreakMode=NSLineBreakByTruncatingTail;
    label.isAccessibilityElement=NO;
    [button addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:2.0],
        [label.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-2.0],
        [label.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:-1.0],
        [label.heightAnchor constraintEqualToConstant:12.0]
    ]];

    objc_setAssociatedObject(
        button,
        &kXLGInjectedTabLabelKey,
        label,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    return label;
}

static void XLGSyncLiquidGlassLabels(UITabBar *tabBar,
                                    NSArray<UIView *> *buttons,
                                    UIColor *accent) {
    BOOL showLabels=XLGTabLabelsEnabled();
    UIColor *secondary=UIColor.secondaryLabelColor;

    NSUInteger count=MIN(buttons.count,tabBar.items.count);
    for (NSUInteger i=0;i<count;i++) {
        UIView *button=buttons[i];
        UITabBarItem *item=tabBar.items[i];
        BOOL selected=XLGViewLooksSelected(button,tabBar,i);

        // Theme any native labels the system already created.
        NSArray<UIView *> *nativeLabels=
            XLGCollectViewsMatching(button,^BOOL(UIView *view) {
                return [view isKindOfClass:UILabel.class] &&
                       objc_getAssociatedObject(button,&kXLGInjectedTabLabelKey) != view;
            });

        for (UILabel *label in (NSArray<UILabel *> *)nativeLabels) {
            label.textColor=selected ? accent : secondary;
        }

        UILabel *label=XLGInjectedLabelForButton(button,showLabels);
        if (label) {
            NSString *title=item.title;
            if (title.length==0) title=item.accessibilityLabel;
            if (title.length==0) title=button.accessibilityLabel;
            label.text=title ?: @"";
            label.hidden=!showLabels || label.text.length==0;
            label.textColor=selected ? accent : secondary;
            [button bringSubviewToFront:label];
        }
    }

    // Hide labels from stale buttons after a tab-count change.
    for (NSUInteger i=count;i<buttons.count;i++) {
        UILabel *label=XLGInjectedLabelForButton(buttons[i],NO);
        label.hidden=YES;
    }
}

static void XLGApplyLiquidGlassTabBarVisualFixes(id controller) {
    if (!controller || !XLGEnabled() || !gXLGAllowTabColorHook) return;

    XLGTabBarColorMode mode=XLGTabBarColorModeValue();
    if (mode == XLGTabBarColorModeNative) return;
    if (![controller isKindOfClass:UIViewController.class]) return;

    UIViewController *vc=(UIViewController *)controller;
    if (!vc.isViewLoaded) return;

    SEL tabBarSEL=NSSelectorFromString(@"tabBar");
    if (![controller respondsToSelector:tabBarSEL]) return;

    id object=((id(*)(id,SEL))objc_msgSend)(controller,tabBarSEL);
    if (![object isKindOfClass:UITabBar.class]) return;

    UITabBar *tabBar=(UITabBar *)object;
    UIColor *accent=XLGResolvedAccentColor(controller,tabBar);
    UIColor *secondary=tabBar.unselectedItemTintColor ?: UIColor.secondaryLabelColor;

    XLGApplyAccentToTabBar(tabBar,accent);

    NSArray<UIView *> *buttons=XLGSystemTabButtons(tabBar);
    NSUInteger count=buttons.count;

    for (NSUInteger i=0;i<count;i++) {
        UIView *button=buttons[i];
        BOOL selected=XLGViewLooksSelected(button,tabBar,i);
        UIColor *color=
            (mode == XLGTabBarColorModeAllTabs)
                ? accent
                : (selected ? accent : secondary);

        NSString *title=button.accessibilityLabel;
        if (i<tabBar.items.count) {
            UITabBarItem *item=tabBar.items[i];
            if (item.title.length) title=item.title;
            else if (item.accessibilityLabel.length) title=item.accessibilityLabel;
        }

        BOOL profile=XLGTitleLooksLikeProfile(title);
        XLGTintImageViews(button,color,profile);
        if (profile) XLGStripAvatarCircleStyling(button);
    }

    if (mode == XLGTabBarColorModeAllTabs) {
        UIView *chrome=XLGFindLiquidSelectionChrome(tabBar);
        XLGApplySelectionChrome(chrome,accent);
    }

    XLGSyncLiquidGlassLabels(tabBar,buttons,accent);

    [tabBar setNeedsLayout];
}

static IMP gOrigXLGNavigationTabBarViewLayoutSubviews=NULL;

static void XLGNavigationTabBarViewLayoutSubviews(id self,SEL cmd) {
    if (gOrigXLGNavigationTabBarViewLayoutSubviews) {
        ((void(*)(id,SEL))gOrigXLGNavigationTabBarViewLayoutSubviews)(self,cmd);
    }

    if (!XLGEnabled() || !gXLGAllowTabColorHook ||
        ![self isKindOfClass:UIView.class]) return;

    XLGTabBarColorMode mode=XLGTabBarColorModeValue();
    if (mode == XLGTabBarColorModeNative) return;

    UIView *view=(UIView *)self;
    UIViewController *controller=nil;
    UIResponder *responder=view.nextResponder;
    for (NSInteger i=0;responder && i<16;i++,responder=responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            controller=(UIViewController *)responder;
            break;
        }
    }

    // Use the X/NFB primary theme color instead of UIView.tintColor.
    UIColor *accent=XLGResolvedAccentColor(controller,nil);

    if (mode == XLGTabBarColorModeActiveOnly) {
        XLGApplyActiveOnlyToXNavigationTabBar(view,accent);
        return;
    }

    // All Tabs: preserve the exact 1.5.0 visual pipeline that was already
    // runtime-validated, including the Liquid Glass selection chrome.
    XLGTintImageViews(view,accent,NO);
    UIView *chrome=XLGFindLiquidSelectionChrome(view);
    XLGApplySelectionChrome(chrome,accent);
}

static void XLGInstallXNavigationVisualFix(void) {
    Class cls=NSClassFromString(@"_TtC11XNavigation10TabBarView");
    if (!cls) return;

    XLGHookMethod(
        cls,
        @selector(layoutSubviews),
        NO,
        (IMP)XLGNavigationTabBarViewLayoutSubviews,
        &gOrigXLGNavigationTabBarViewLayoutSubviews
    );
}

static void XLGLGBadgeViewDidLoad(id self,SEL cmd) {
    if (gOrigLGBadgeViewDidLoad)
        ((void(*)(id,SEL))gOrigLGBadgeViewDidLoad)(self,cmd);

    XLGInvalidateLiquidGlassCompactBadge(self);
    XLGNormalizeLiquidGlassBadges(self);
    XLGApplyLiquidGlassTabBarVisualFixes(self);
    XLGScheduleLiquidGlassBadgeRefresh(self);
}

static void XLGLGBadgeViewDidAppear(id self,SEL cmd,BOOL animated) {
    if (gOrigLGBadgeViewDidAppear)
        ((void(*)(id,SEL,BOOL))gOrigLGBadgeViewDidAppear)(self,cmd,animated);

    XLGInvalidateLiquidGlassCompactBadge(self);
    XLGNormalizeLiquidGlassBadges(self);
    XLGApplyLiquidGlassTabBarVisualFixes(self);
    XLGScheduleLiquidGlassBadgeRefresh(self);
}

static void XLGLGBadgeSetTabViews(id self,SEL cmd,id tabViews) {
    if (gOrigLGBadgeSetTabViews)
        ((void(*)(id,SEL,id))gOrigLGBadgeSetTabViews)(self,cmd,tabViews);

    XLGInvalidateLiquidGlassCompactBadge(self);
    XLGNormalizeLiquidGlassBadges(self);
    XLGApplyLiquidGlassTabBarVisualFixes(self);
    XLGScheduleLiquidGlassBadgeRefresh(self);
}

static void XLGLGBadgeSyncTabBarItems(id self,SEL cmd) {
    if (gOrigLGBadgeSyncTabBarItems)
        ((void(*)(id,SEL))gOrigLGBadgeSyncTabBarItems)(self,cmd);

    XLGInvalidateLiquidGlassCompactBadge(self);
    XLGNormalizeLiquidGlassBadges(self);
    XLGApplyLiquidGlassTabBarVisualFixes(self);
    XLGScheduleLiquidGlassBadgeRefresh(self);
}

static void XLGLGBadgeSyncBadges(id self,SEL cmd) {
    if (gOrigLGBadgeSyncBadges)
        ((void(*)(id,SEL))gOrigLGBadgeSyncBadges)(self,cmd);

    // Moe's syncBadges hook immediately normalizes after the original method.
    XLGNormalizeLiquidGlassUnreadBadgeValues(self);
    XLGInvalidateLiquidGlassCompactBadge(self);
    XLGNormalizeLiquidGlassBadges(self);
    XLGApplyLiquidGlassTabBarVisualFixes(self);
}

static void XLGLGBadgeTraitCollectionDidChange(id self,SEL cmd,id previousTraitCollection) {
    if (gOrigLGBadgeTraitCollectionDidChange)
        ((void(*)(id,SEL,id))gOrigLGBadgeTraitCollectionDidChange)(
            self,cmd,previousTraitCollection
        );

    XLGInvalidateLiquidGlassCompactBadge(self);
    XLGNormalizeLiquidGlassBadges(self);
    XLGApplyLiquidGlassTabBarVisualFixes(self);
}

static void XLGLGBadgeViewDidLayoutSubviews(id self,SEL cmd) {
    if (gOrigLGBadgeViewDidLayoutSubviews)
        ((void(*)(id,SEL))gOrigLGBadgeViewDidLayoutSubviews)(self,cmd);

    XLGNormalizeLiquidGlassUnreadBadgeValues(self);
    XLGNormalizeLiquidGlassBadges(self);
    XLGApplyLiquidGlassTabBarVisualFixes(self);
}

static void XLGInstallLiquidGlassBadgeFixes(void) {
    Class cls=NSClassFromString(@"T1LiquidGlassTabBarController");
    if (!cls) return;

    XLGHookMethod(cls,@selector(viewDidLoad),NO,
                  (IMP)XLGLGBadgeViewDidLoad,&gOrigLGBadgeViewDidLoad);

    XLGHookMethod(cls,@selector(viewDidAppear:),NO,
                  (IMP)XLGLGBadgeViewDidAppear,&gOrigLGBadgeViewDidAppear);

    XLGHookMethod(cls,NSSelectorFromString(@"setTabViews:"),NO,
                  (IMP)XLGLGBadgeSetTabViews,&gOrigLGBadgeSetTabViews);

    XLGHookMethod(cls,NSSelectorFromString(@"_t1_syncTabBarItems"),NO,
                  (IMP)XLGLGBadgeSyncTabBarItems,&gOrigLGBadgeSyncTabBarItems);

    XLGHookMethod(cls,NSSelectorFromString(@"syncBadges"),NO,
                  (IMP)XLGLGBadgeSyncBadges,&gOrigLGBadgeSyncBadges);

    XLGHookMethod(cls,@selector(traitCollectionDidChange:),NO,
                  (IMP)XLGLGBadgeTraitCollectionDidChange,
                  &gOrigLGBadgeTraitCollectionDidChange);

    XLGHookMethod(cls,@selector(viewDidLayoutSubviews),NO,
                  (IMP)XLGLGBadgeViewDidLayoutSubviews,
                  &gOrigLGBadgeViewDidLayoutSubviews);
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
    XLGInstallSidebarFix();
    XLGInstallLiquidGlassBadgeFixes();

    // Native mode is a true 1.4.0-style startup path: the XNavigation
    // color hook introduced in 1.5.0 is not installed at all.
    if (gXLGAllowTabColorHook) {
        XLGInstallXNavigationVisualFix();
    }

    XLGInstallNFBSettingsIntegration();
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
        gXLGAllowTabColorHook =
            (XLGTabBarColorModeValue() != XLGTabBarColorModeNative);

        NSLog(@"[XLiquidGlass] 1.5.0 Tab Color Mode Selector Test loaded: Native / Active Only / All Tabs");

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
