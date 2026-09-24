#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kXLGEnabledKey = @"XLiquidGlassEnabled";
static NSString *const kXLGPersistedGateKey = @"T1LiquidGlassRedesignPersistedGate";

static IMP gOrigInstallGate = NULL;
static IMP gOrigInstallGateForAccount = NULL;
static IMP gOrigDummyFeature = NULL;
static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;
static IMP gOrigCanPresentDash = NULL;
static IMP gOrigDidTapDashButton = NULL;

static BOOL gDebugSettingsHooked = NO;
static BOOL gSwiftLiquidGlassHooked = NO;
static BOOL gRedesignFeaturesHooked = NO;
static BOOL gInstallGateHooked = NO;
static BOOL gInstallGateForAccountHooked = NO;
static BOOL gDummyFeatureHooked = NO;
static BOOL gNFBSettingsHooked = NO;
static BOOL gSidebarHooked = NO;

static BOOL XLGEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:kXLGEnabledKey];
    return stored ? [stored boolValue] : YES;
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

    static NSString *identifier = @"XLiquidGlassToggleCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }

    cell.textLabel.text = @"Ativar Liquid Glass";
    cell.detailTextLabel.text = @"Usa o redesign nativo presente no X.";
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    toggle.on = XLGEnabled();
    [toggle addTarget:self
               action:@selector(xlgToggleChanged:)
     forControlEvents:UIControlEventValueChanged];
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



#pragma mark - Liquid Glass sidebar fix (Moe-compatible reconstruction)

static IMP gOrigNavDidShow = NULL;
static IMP gOrigNavLayout = NULL;
static IMP gOrigTabLoad = NULL;
static IMP gOrigTabAppear = NULL;

static char kXLGSidebarButtonInstalledKey;
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
- (void)xlg_presentAnimated:(BOOL)animated;
- (void)xlg_dismissAnimated:(BOOL)animated completion:(dispatch_block_t)completion;
- (void)xlg_didTapSidebarButton:(id)sender;
- (void)xlg_didRecognizeEdgePan:(UIScreenEdgePanGestureRecognizer *)gesture;
@end

@interface XLiquidGlassSidebarDrawerViewController : UIViewController
@property (nonatomic, strong) UIViewController *dashViewController;
@property (nonatomic, copy) dispatch_block_t dismissRequestHandler;
@property (nonatomic, strong) UIView *dimmingView;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIPanGestureRecognizer *panRecognizer;
@property (nonatomic, assign) CGFloat panStartX;
@end

static UIWindow *XLGActiveWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene=(UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) return window;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindow *window=((UIWindowScene *)scene).windows.firstObject;
        if (window) return window;
    }
    return nil;
}

static UIViewController *XLGTopViewController(void) {
    UIViewController *vc=XLGActiveWindow().rootViewController;
    for (NSInteger i=0; vc && i<32; i++) {
        if (vc.presentedViewController) {
            vc=vc.presentedViewController;
            continue;
        }
        if ([vc isKindOfClass:UINavigationController.class]) {
            UIViewController *next=((UINavigationController *)vc).visibleViewController;
            if (next) { vc=next; continue; }
        }
        if ([vc isKindOfClass:UITabBarController.class]) {
            UIViewController *next=((UITabBarController *)vc).selectedViewController;
            if (next) { vc=next; continue; }
        }
        break;
    }
    return vc;
}

static id XLGCurrentAccount(void) {
    // Same host-account fallback used by the Moe sidebar reconstruction:
    // TFNTwitter.sharedTwitter.activeAccount.
    Class twitterClass=NSClassFromString(@"TFNTwitter");
    SEL sharedSEL=NSSelectorFromString(@"sharedTwitter");
    if (twitterClass && [twitterClass respondsToSelector:sharedSEL]) {
        id twitter=((id(*)(id,SEL))objc_msgSend)(twitterClass,sharedSEL);
        SEL activeSEL=NSSelectorFromString(@"activeAccount");
        if (twitter && [twitter respondsToSelector:activeSEL]) {
            id account=((id(*)(id,SEL))objc_msgSend)(twitter,activeSEL);
            if (account) return account;
        }
    }

    // Fallback: inspect the active navigation tree for an account accessor.
    NSMutableArray<UIViewController *> *queue=[NSMutableArray array];
    UIViewController *root=XLGActiveWindow().rootViewController;
    if (root) [queue addObject:root];

    for (NSUInteger i=0;i<queue.count && i<128;i++) {
        UIViewController *vc=queue[i];
        SEL accountSEL=NSSelectorFromString(@"account");
        if ([vc respondsToSelector:accountSEL]) {
            id account=((id(*)(id,SEL))objc_msgSend)(vc,accountSEL);
            if (account) return account;
        }
        if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
        [queue addObjectsFromArray:vc.childViewControllers ?: @[]];
    }
    return nil;
}

@implementation XLiquidGlassSidebarDrawerViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor=UIColor.clearColor;

    self.dimmingView=[[UIView alloc] initWithFrame:CGRectZero];
    self.dimmingView.backgroundColor=[UIColor colorWithWhite:0 alpha:0.40];
    self.dimmingView.alpha=0.0;
    [self.view addSubview:self.dimmingView];

    UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                       action:@selector(xlg_didTapDimming:)];
    [self.dimmingView addGestureRecognizer:tap];

    self.panelView=[[UIView alloc] initWithFrame:CGRectZero];
    self.panelView.backgroundColor=UIColor.systemBackgroundColor;
    [self.view addSubview:self.panelView];

    self.panRecognizer=[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                               action:@selector(xlg_didPanPanel:)];
    [self.panelView addGestureRecognizer:self.panRecognizer];

    if (self.dashViewController) {
        [self addChildViewController:self.dashViewController];
        self.dashViewController.view.frame=self.panelView.bounds;
        self.dashViewController.view.autoresizingMask=
            UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        [self.panelView addSubview:self.dashViewController.view];
        [self.dashViewController didMoveToParentViewController:self];
    }
}

- (CGFloat)xlg_panelWidth {
    return MIN(320.0, self.view.bounds.size.width * 0.82);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.dimmingView.frame=self.view.bounds;

    CGFloat width=[self xlg_panelWidth];
    if (self.panelView.frame.size.width == 0) {
        self.panelView.frame=CGRectMake(-width,0,width,self.view.bounds.size.height);
    } else {
        self.panelView.frame=CGRectMake(self.panelView.frame.origin.x,0,width,self.view.bounds.size.height);
    }
    self.dashViewController.view.frame=self.panelView.bounds;
}

- (void)xlg_showAnimated:(BOOL)animated {
    [self.view layoutIfNeeded];
    CGFloat width=[self xlg_panelWidth];
    self.panelView.frame=CGRectMake(-width,0,width,self.view.bounds.size.height);

    void (^changes)(void)=^{
        self.dimmingView.alpha=1.0;
        self.panelView.frame=CGRectMake(0,0,width,self.view.bounds.size.height);
    };

    if (animated) {
        [UIView animateWithDuration:0.28
                              delay:0
             usingSpringWithDamping:0.92
              initialSpringVelocity:0.0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
}

- (void)xlg_hideAnimated:(BOOL)animated completion:(dispatch_block_t)completion {
    CGFloat width=[self xlg_panelWidth];
    void (^changes)(void)=^{
        self.dimmingView.alpha=0.0;
        self.panelView.frame=CGRectMake(-width,0,width,self.view.bounds.size.height);
    };
    void (^done)(BOOL)=^(BOOL finished){
        (void)finished;
        if (completion) completion();
    };

    if (animated) {
        [UIView animateWithDuration:0.22
                         animations:changes
                         completion:done];
    } else {
        changes();
        done(YES);
    }
}

- (void)xlg_didTapDimming:(id)sender {
    (void)sender;
    if (self.dismissRequestHandler) self.dismissRequestHandler();
}

- (void)xlg_didPanPanel:(UIPanGestureRecognizer *)gesture {
    CGFloat width=[self xlg_panelWidth];

    if (gesture.state==UIGestureRecognizerStateBegan) {
        self.panStartX=self.panelView.frame.origin.x;
        return;
    }

    if (gesture.state==UIGestureRecognizerStateChanged) {
        CGFloat dx=[gesture translationInView:self.view].x;
        CGFloat x=MIN(0.0,MAX(-width,self.panStartX+dx));
        self.panelView.frame=CGRectMake(x,0,width,self.view.bounds.size.height);
        self.dimmingView.alpha=MAX(0.0,MIN(1.0,1.0+x/width));
        return;
    }

    if (gesture.state==UIGestureRecognizerStateEnded ||
        gesture.state==UIGestureRecognizerStateCancelled) {
        CGFloat velocity=[gesture velocityInView:self.view].x;
        BOOL dismiss=(self.panelView.frame.origin.x < -width*0.35) || velocity < -500.0;
        if (dismiss) {
            if (self.dismissRequestHandler) self.dismissRequestHandler();
        } else {
            [UIView animateWithDuration:0.20 animations:^{
                self.panelView.frame=CGRectMake(0,0,width,self.view.bounds.size.height);
                self.dimmingView.alpha=1.0;
            }];
        }
    }
}
@end

@implementation XLiquidGlassSidebarCoordinator

+ (instancetype)sharedCoordinator {
    static XLiquidGlassSidebarCoordinator *coordinator=nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator=[XLiquidGlassSidebarCoordinator new];
    });
    return coordinator;
}

- (UIViewController *)xlg_buildDashViewControllerForAccount:(id)account {
    if (!account) return nil;

    Class bridgeClass=NSClassFromString(@"T1URTNotificationsInteractionsTimelineBridge");
    Class contentClass=NSClassFromString(@"T1DashContentController");
    Class factoryClass=NSClassFromString(@"T1DashNavigationViewFactory");

    if (!bridgeClass || !contentClass || !factoryClass) {
        NSLog(@"[XLiquidGlass] Dash reconstruction classes are absent");
        return nil;
    }

    id bridge=nil;
    SEL bridgeInit=NSSelectorFromString(@"initWithAccount:");
    id bridgeAlloc=((id(*)(id,SEL))objc_msgSend)(bridgeClass,@selector(alloc));
    if ([bridgeAlloc respondsToSelector:bridgeInit]) {
        bridge=((id(*)(id,SEL,id))objc_msgSend)(bridgeAlloc,bridgeInit,account);
    } else {
        bridge=((id(*)(id,SEL))objc_msgSend)(bridgeAlloc,@selector(init));
    }

    id content=nil;
    SEL contentInit=NSSelectorFromString(@"initWithAccount:interactionsTimelineBridge:");
    id contentAlloc=((id(*)(id,SEL))objc_msgSend)(contentClass,@selector(alloc));
    if ([contentAlloc respondsToSelector:contentInit]) {
        content=((id(*)(id,SEL,id,id))objc_msgSend)(contentAlloc,contentInit,account,bridge);
    }

    if (!content) {
        NSLog(@"[XLiquidGlass] Could not construct T1DashContentController");
        return nil;
    }

    SEL presenterSEL=NSSelectorFromString(@"presenter");
    if ([content respondsToSelector:presenterSEL]) {
        id presenter=((id(*)(id,SEL))objc_msgSend)(content,presenterSEL);
        SEL delegateSEL=NSSelectorFromString(@"setDelegate:");
        if (presenter && [presenter respondsToSelector:delegateSEL]) {
            ((void(*)(id,SEL,id))objc_msgSend)(presenter,delegateSEL,self);
        }
    }

    SEL buildSEL=NSSelectorFromString(@"buildDashViewControllerForAccount:dashContentController:");
    UIViewController *dash=nil;
    if ([factoryClass respondsToSelector:buildSEL]) {
        id result=((id(*)(id,SEL,id,id))objc_msgSend)(factoryClass,buildSEL,account,content);
        if ([result isKindOfClass:UIViewController.class]) dash=result;
    }

    if (!dash) {
        NSLog(@"[XLiquidGlass] T1DashNavigationViewFactory returned no controller");
        return nil;
    }

    self.account=account;
    self.interactionsTimelineBridge=bridge;
    self.dashContentController=content;
    return dash;
}

- (void)xlg_presentAnimated:(BOOL)animated {
    if (!XLGEnabled() || self.presenting) return;

    id account=XLGCurrentAccount();
    if (!account) {
        NSLog(@"[XLiquidGlass] No signed-in account for sidebar");
        return;
    }

    UIViewController *dash=[self xlg_buildDashViewControllerForAccount:account];
    if (!dash) return;

    XLiquidGlassSidebarDrawerViewController *drawer=[XLiquidGlassSidebarDrawerViewController new];
    drawer.modalPresentationStyle=UIModalPresentationOverFullScreen;
    drawer.modalTransitionStyle=UIModalTransitionStyleCrossDissolve;
    drawer.dashViewController=dash;

    __weak typeof(self) weakSelf=self;
    drawer.dismissRequestHandler=^{
        [weakSelf xlg_dismissAnimated:YES completion:nil];
    };

    UIViewController *presenter=XLGTopViewController();
    if (!presenter) return;

    self.presenting=YES;
    self.drawer=drawer;

    [presenter presentViewController:drawer animated:NO completion:^{
        [drawer xlg_showAnimated:animated];
        self.presenting=NO;
        NSLog(@"[XLiquidGlass] Presented reconstructed Liquid Glass account sidebar");
    }];
}

- (void)xlg_dismissAnimated:(BOOL)animated completion:(dispatch_block_t)completion {
    XLiquidGlassSidebarDrawerViewController *drawer=self.drawer;
    if (!drawer) {
        if (completion) completion();
        return;
    }

    [drawer xlg_hideAnimated:animated completion:^{
        [drawer dismissViewControllerAnimated:NO completion:^{
            self.drawer=nil;
            self.dashContentController=nil;
            self.interactionsTimelineBridge=nil;
            self.account=nil;
            if (completion) completion();
        }];
    }];
}

- (void)xlg_didTapSidebarButton:(id)sender {
    (void)sender;
    [self xlg_presentAnimated:YES];
}

- (void)xlg_didRecognizeEdgePan:(UIScreenEdgePanGestureRecognizer *)gesture {
    if (gesture.state==UIGestureRecognizerStateBegan) {
        [self xlg_presentAnimated:YES];
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    (void)gestureRecognizer;
    return XLGEnabled() && self.drawer==nil && !self.presenting;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
 shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return YES;
}

// T1DashContentPresenter delegate routing used by the reconstructed host Dash.
- (void)dashContentPresenterDismissDashAnimated:(BOOL)animated completion:(id)completion {
    dispatch_block_t block=[completion isKindOfClass:NSClassFromString(@"NSBlock")] ? completion : nil;
    [self xlg_dismissAnimated:animated completion:block];
}

- (void)dashContentPresenterDismissViewControllerAnimated:(BOOL)animated {
    [self xlg_dismissAnimated:animated completion:nil];
}

- (void)dashContentPresenterPresentContentViewController:(UIViewController *)viewController
                                        dismissDashBlock:(id)dismissDashBlock {
    (void)dismissDashBlock;
    [self xlg_dismissAnimated:YES completion:^{
        UIViewController *presenter=XLGTopViewController();
        if ([presenter isKindOfClass:UINavigationController.class]) {
            [(UINavigationController *)presenter pushViewController:viewController animated:YES];
        } else if (presenter.navigationController) {
            [presenter.navigationController pushViewController:viewController animated:YES];
        } else {
            [presenter presentViewController:viewController animated:YES completion:nil];
        }
    }];
}

- (void)dashContentPresenterPresentModalViewController:(UIViewController *)viewController
                                      dismissDashBlock:(id)dismissDashBlock {
    (void)dismissDashBlock;
    [self xlg_dismissAnimated:YES completion:^{
        [XLGTopViewController() presentViewController:viewController animated:YES completion:nil];
    }];
}

- (void)dashContentPresenterSwitchAccountWithBlock:(id)block
                                  dismissDashBlock:(id)dismissDashBlock {
    (void)dismissDashBlock;
    [self xlg_dismissAnimated:YES completion:^{
        if (block) ((void(^)(void))block)();
    }];
}
@end

static void XLGWireDashBarButtonItem(UIBarButtonItem *item,id account) {
    if (!item) return;

    XLiquidGlassSidebarCoordinator *coordinator=[XLiquidGlassSidebarCoordinator sharedCoordinator];
    SEL targetSEL=NSSelectorFromString(@"setTarget:action:for:");

    if ([item respondsToSelector:targetSEL]) {
        ((void(*)(id,SEL,id,SEL,NSUInteger))objc_msgSend)(
            item,targetSEL,coordinator,@selector(xlg_didTapSidebarButton:),64
        );
    } else {
        item.target=coordinator;
        item.action=@selector(xlg_didTapSidebarButton:);
    }

    SEL setAccountSEL=NSSelectorFromString(@"setAccount:");
    if (account && [item respondsToSelector:setAccountSEL]) {
        ((void(*)(id,SEL,id))objc_msgSend)(item,setAccountSEL,account);
    }
    item.accessibilityLabel=@"Account";
}

static void XLGInstallLeadingAccountButton(UIViewController *viewController) {
    if (!XLGEnabled() || !viewController) return;

    id account=XLGCurrentAccount();
    if (!account) return;

    UIBarButtonItem *existing=viewController.navigationItem.leftBarButtonItem;
    Class dashItemClass=NSClassFromString(@"T1DashBarButtonItem");

    // If X already rendered its avatar item but the Liquid Glass path left the
    // action inert, preserve its image/account and repair only the target/action.
    if (existing && dashItemClass && [existing isKindOfClass:dashItemClass]) {
        XLGWireDashBarButtonItem(existing,account);
        objc_setAssociatedObject(viewController,&kXLGSidebarButtonInstalledKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if ([objc_getAssociatedObject(viewController,&kXLGSidebarButtonInstalledKey) boolValue]) return;

    UIBarButtonItem *item=nil;
    if (dashItemClass) {
        id allocated=((id(*)(id,SEL))objc_msgSend)(dashItemClass,@selector(alloc));
        id initialized=((id(*)(id,SEL))objc_msgSend)(allocated,@selector(init));
        if ([initialized isKindOfClass:UIBarButtonItem.class]) item=initialized;
    }

    if (!item) {
        UIImage *image=[UIImage systemImageNamed:@"line.3.horizontal"];
        item=[[UIBarButtonItem alloc] initWithImage:image
                                              style:UIBarButtonItemStylePlain
                                             target:nil
                                             action:nil];
    }

    XLGWireDashBarButtonItem(item,account);
    viewController.navigationItem.leftBarButtonItem=item;
    objc_setAssociatedObject(viewController,&kXLGSidebarButtonInstalledKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[XLiquidGlass] Installed leading account button for Liquid Glass sidebar");
}

static void XLGInstallEdgeGesture(UIViewController *controller) {
    if (!XLGEnabled() || !controller.view) return;
    if (objc_getAssociatedObject(controller,&kXLGSidebarEdgePanKey)) return;

    UIScreenEdgePanGestureRecognizer *gesture=
        [[UIScreenEdgePanGestureRecognizer alloc]
            initWithTarget:[XLiquidGlassSidebarCoordinator sharedCoordinator]
                    action:@selector(xlg_didRecognizeEdgePan:)];
    gesture.edges=UIRectEdgeLeft;
    gesture.delegate=[XLiquidGlassSidebarCoordinator sharedCoordinator];
    gesture.cancelsTouchesInView=NO;
    [controller.view addGestureRecognizer:gesture];

    objc_setAssociatedObject(controller,&kXLGSidebarEdgePanKey,gesture,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[XLiquidGlass] Installed left-edge account sidebar gesture");
}

static void XLGNavDidShow(id self,SEL cmd,id navigationController,id viewController,BOOL animated) {
    if (gOrigNavDidShow) {
        ((void(*)(id,SEL,id,id,BOOL))gOrigNavDidShow)(self,cmd,navigationController,viewController,animated);
    }

    if (![viewController isKindOfClass:UIViewController.class]) return;
    UINavigationController *nav=[viewController navigationController];
    UIViewController *first=nav.viewControllers.firstObject;
    if (first==viewController) XLGInstallLeadingAccountButton(viewController);
}

static void XLGNavLayout(id self,SEL cmd) {
    if (gOrigNavLayout) ((void(*)(id,SEL))gOrigNavLayout)(self,cmd);

    if ([self isKindOfClass:UINavigationController.class]) {
        UIViewController *first=((UINavigationController *)self).viewControllers.firstObject;
        if (first) XLGInstallLeadingAccountButton(first);
    }
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
    Class navClass=NSClassFromString(@"_TtC11XNavigation20NavigationController");
    if (navClass) {
        XLGHookMethod(navClass,
                      NSSelectorFromString(@"navigationController:didShowViewController:animated:"),
                      NO,(IMP)XLGNavDidShow,&gOrigNavDidShow);
        XLGHookMethod(navClass,@selector(viewDidLayoutSubviews),NO,(IMP)XLGNavLayout,&gOrigNavLayout);
    }

    Class tabClass=NSClassFromString(@"_TtC11XNavigation16TabBarController");
    if (tabClass) {
        XLGHookMethod(tabClass,@selector(viewDidLoad),NO,(IMP)XLGTabLoad,&gOrigTabLoad);
        XLGHookMethod(tabClass,@selector(viewDidAppear:),NO,(IMP)XLGTabAppear,&gOrigTabAppear);
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
    XLGInstallSidebarFix();
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
        NSLog(@"[XLiquidGlass] 1.2.0 standalone + NFB toggle + sidebar fix loaded");

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
