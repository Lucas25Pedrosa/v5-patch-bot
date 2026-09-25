#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kXLGEnabledKey = @"XLiquidGlassEnabled";
static NSString *const kXLGPersistedGateKey = @"T1LiquidGlassRedesignPersistedGate";
static NSString *const kXLGTabLabelsKey = @"XLiquidGlassTabLabelsEnabled";

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
    (void)indexPath;

    static NSString *identifier = @"XLiquidGlassToggleCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }

    cell.selectionStyle = UITableViewCellSelectionStyleNone;

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


#pragma mark - XLiquidGlass 1.6 global Tab Bar / badge bridge

static NSString *const kXLGBadgePrefix = @"XLiquidGlass.Badges.";
static NSInteger gXLGNTabCount = -1;
static NSInteger gXLGDMCount = -1;
static NSInteger gXLGXChatCount = -1;
static NSInteger gXLGTotalCount = -1;
static NSInteger gXLGLastRootBadgeCount = -1;
static NSString *gXLGBadgeActiveUserID = nil;
static NSDictionary *gXLGLastBadgeCountsByUserID = nil;
static BOOL gXLGBadgePersistenceLoaded = NO;
static IMP gOrigXNavItemLayout = NULL;
static id gXLGBadgeNotificationObserver = nil;
static id gXLGDefaultsObserver = nil;
static char kXLGBadgeLabelKey;

static id XLGSafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
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

static NSString *XLGCurrentActiveUserID(void) {
    id account = XLGSidebarCurrentAccount();
    NSString *userID = XLGTryResolveUserID(account, 0);
    if (userID.length) return userID;
    return gXLGBadgeActiveUserID;
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

static void XLGPersistBadgeCounts(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:gXLGNTabCount forKey:XLGBadgeDefaultsKey(@"ntab")];
    [defaults setInteger:gXLGDMCount forKey:XLGBadgeDefaultsKey(@"dm")];
    [defaults setInteger:gXLGXChatCount forKey:XLGBadgeDefaultsKey(@"xchat")];
    [defaults setInteger:gXLGTotalCount forKey:XLGBadgeDefaultsKey(@"total")];
    if (gXLGBadgeActiveUserID.length) {
        [defaults setObject:gXLGBadgeActiveUserID
                    forKey:XLGBadgeDefaultsKey(@"userID")];
    }
    [defaults setDouble:NSDate.date.timeIntervalSince1970
                 forKey:XLGBadgeDefaultsKey(@"timestamp")];
}

static void XLGLoadPersistedBadgeCounts(void) {
    if (gXLGBadgePersistenceLoaded) return;
    gXLGBadgePersistenceLoaded = YES;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSTimeInterval timestamp = [defaults doubleForKey:XLGBadgeDefaultsKey(@"timestamp")];
    if (timestamp <= 0) return;

    NSTimeInterval age = NSDate.date.timeIntervalSince1970 - timestamp;
    if (age > 24.0 * 60.0 * 60.0) return;

    gXLGNTabCount = [defaults integerForKey:XLGBadgeDefaultsKey(@"ntab")];
    gXLGDMCount = [defaults integerForKey:XLGBadgeDefaultsKey(@"dm")];
    gXLGXChatCount = [defaults integerForKey:XLGBadgeDefaultsKey(@"xchat")];
    gXLGTotalCount = [defaults integerForKey:XLGBadgeDefaultsKey(@"total")];
    gXLGBadgeActiveUserID =
        [[defaults stringForKey:XLGBadgeDefaultsKey(@"userID")] copy];
}

static NSInteger XLGChatDisplayCount(void) {
    if (gXLGXChatCount > 0) return gXLGXChatCount;
    if (gXLGDMCount >= 0) return gXLGDMCount;
    if (gXLGXChatCount >= 0) return gXLGXChatCount;
    return -1;
}

static NSInteger XLGNotificationDisplayCount(void) {
    NSInteger canonical = gXLGNTabCount;
    NSInteger chat = XLGChatDisplayCount();
    NSInteger derived = -1;

    if (gXLGTotalCount >= 0 && chat >= 0 && gXLGTotalCount >= chat) {
        derived = gXLGTotalCount - chat;
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

static NSInteger XLGBadgeCountForXNavItem(UIView *item) {
    NSString *label = item.accessibilityLabel.lowercaseString ?: @"";
    if ([label containsString:@"notifica"]) return gXLGNTabCount;

    if ([label containsString:@"bate-papo"] ||
        [label containsString:@"chat"] ||
        [label containsString:@"mensag"] ||
        [label containsString:@"messages"]) {
        return XLGChatDisplayCount();
    }

    return -1;
}

static void XLGApplyBadgeToXNavItem(UIView *item) {
    NSInteger count = XLGBadgeCountForXNavItem(item);
    if (count < 0) return;

    UILabel *badge = XLGBadgeLabelForXNavItem(item);
    if (count <= 0) {
        badge.hidden = YES;
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

static void XLGRefreshGlobalTabBar(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in XLGVisibleWindows()) {
            for (UIView *item in
                 XLGSubviewsMatchingClassName(window, @"XNavigation.TabBarItemView")) {
                XLGApplyThemeToXNavItem(item);
                XLGApplyBadgeToXNavItem(item);
            }
        }
    });
}

static void XLGSetBadgeCountsFromObject(id object, NSString *userID) {
    if (!object) return;

    NSInteger ntab = 0, dm = 0, xchat = 0, total = 0;
    BOOL hasNtab = XLGReadCountField(object, @"ntabUnreadCount", &ntab);
    BOOL hasDM = XLGReadCountField(object, @"dmUnreadCount", &dm);
    BOOL hasXChat = XLGReadCountField(object, @"xchatUnreadCount", &xchat);
    BOOL hasTotal = XLGReadCountField(object, @"totalUnreadCount", &total);
    if (!hasNtab && !hasDM && !hasXChat && !hasTotal) return;

    BOOL changed = NO;
    if (hasNtab && gXLGNTabCount != MAX((NSInteger)0, ntab)) {
        gXLGNTabCount = MAX((NSInteger)0, ntab);
        changed = YES;
    }
    if (hasDM && gXLGDMCount != MAX((NSInteger)0, dm)) {
        gXLGDMCount = MAX((NSInteger)0, dm);
        changed = YES;
    }
    if (hasXChat && gXLGXChatCount != MAX((NSInteger)0, xchat)) {
        gXLGXChatCount = MAX((NSInteger)0, xchat);
        changed = YES;
    }
    if (hasTotal && gXLGTotalCount != MAX((NSInteger)0, total)) {
        gXLGTotalCount = MAX((NSInteger)0, total);
        changed = YES;
    }

    if (userID.length &&
        ![gXLGBadgeActiveUserID isEqualToString:userID]) {
        gXLGBadgeActiveUserID = [userID copy];
        changed = YES;
    }

    if (changed) {
        XLGPersistBadgeCounts();
        NSLog(@"[XLiquidGlass] badges user=%@ ntab=%ld dm=%ld xchat=%ld total=%ld",
              gXLGBadgeActiveUserID ?: @"-",
              (long)gXLGNTabCount,
              (long)gXLGDMCount,
              (long)gXLGXChatCount,
              (long)gXLGTotalCount);
        XLGRefreshGlobalTabBar();
    }
}

static BOOL XLGLooksLikeAccountBadgeMap(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:NSDictionary.class] || dictionary.count == 0)
        return NO;

    NSUInteger valid = 0;
    for (id key in dictionary) {
        id object = dictionary[key];
        NSInteger total = 0;
        if (XLGReadCountField(object, @"totalUnreadCount", &total)) valid++;
    }
    return valid == dictionary.count;
}

static void XLGSelectBadgeAccountFromMap(NSDictionary *dictionary) {
    if (!XLGLooksLikeAccountBadgeMap(dictionary)) return;
    gXLGLastBadgeCountsByUserID = [dictionary copy];

    NSString *activeUserID = XLGCurrentActiveUserID();
    if (activeUserID.length) {
        id object = dictionary[activeUserID];
        if (!object) object = dictionary[@(activeUserID.longLongValue)];
        if (object) {
            XLGSetBadgeCountsFromObject(object, activeUserID);
            return;
        }
    }

    if (gXLGLastRootBadgeCount >= 0) {
        id selected = nil;
        NSString *selectedUserID = nil;
        NSUInteger matches = 0;

        for (id key in dictionary) {
            id object = dictionary[key];
            NSInteger total = -1;
            if (XLGReadCountField(object, @"totalUnreadCount", &total) &&
                total == gXLGLastRootBadgeCount) {
                selected = object;
                selectedUserID = XLGNormalizedUserID(key);
                matches++;
            }
        }

        if (matches == 1 && selected) {
            XLGSetBadgeCountsFromObject(selected, selectedUserID);
            return;
        }
    }

    if (dictionary.count == 1) {
        id key = dictionary.allKeys.firstObject;
        XLGSetBadgeCountsFromObject(dictionary[key],
                                    XLGNormalizedUserID(key));
    }
}

static void XLGHandleBadgeNotification(NSNotification *notification) {
    NSString *name = notification.name ?: @"";

    if ([name isEqualToString:@"AppIconBadgeCountDidChange"]) {
        id value = notification.userInfo[@"AppIconBadgeCountDidChangeUpdatedValue"];
        if ([value respondsToSelector:@selector(integerValue)]) {
            gXLGLastRootBadgeCount = [value integerValue];
            if (gXLGLastBadgeCountsByUserID) {
                XLGSelectBadgeAccountFromMap(gXLGLastBadgeCountsByUserID);
            }
        }
        return;
    }

    if ([name isEqualToString:@"AccountBadgesDidChange"]) {
        id map = notification.userInfo[@"AccountBadgesDidChangeUpdatedValues"];
        if ([map isKindOfClass:NSDictionary.class]) {
            XLGSelectBadgeAccountFromMap(map);
        }
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

static void XLGInstallGlobalTabBarFixes(void) {
    XLGLoadPersistedBadgeCounts();

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
            if ([name isEqualToString:@"AccountBadgesDidChange"] ||
                [name isEqualToString:@"AppIconBadgeCountDidChange"]) {
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

    XLGRefreshGlobalTabBar();
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
    XLGInstallGlobalTabBarFixes();
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
        NSLog(@"[XLiquidGlass] 1.6.0 Beta 2 global loaded: notification badge bridge + activation + NFB + sidebar + theme sync");

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
