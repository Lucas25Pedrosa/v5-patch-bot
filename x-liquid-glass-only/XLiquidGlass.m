#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static IMP gOrigInstallGate = NULL;
static IMP gOrigInstallGateForAccount = NULL;
static IMP gOrigXNavLoad = NULL, gOrigXNavAppear = NULL, gOrigXNavLayout = NULL;
static IMP gOrigLGLoad = NULL, gOrigLGAppear = NULL, gOrigLGSetTabs = NULL;
static IMP gOrigLGSyncItems = NULL, gOrigLGSyncBadges = NULL, gOrigLGTrait = NULL, gOrigLGLayout = NULL;
static IMP gOrigXTabViewLayout = NULL;

static char kComposeKey, kSidebarKey, kEdgeKey, kOwnerKey;

static BOOL XLHook(Class cls, SEL sel, BOOL meta, IMP replacement, IMP *orig) {
    if (!cls || !sel) return NO;
    Method m = meta ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    Class target = meta ? object_getClass(cls) : cls;
    IMP current = class_getMethodImplementation(target, sel);
    if (current == replacement) return YES;
    if (orig && !*orig) *orig = current;
    class_replaceMethod(target, sel, replacement, method_getTypeEncoding(m));
    return class_getMethodImplementation(target, sel) == replacement;
}

static BOOL XLYes(id self, SEL cmd) { (void)self; (void)cmd; return YES; }

static void XLInstallGate(id self, SEL cmd, BOOL requested) {
    (void)requested;
    if (gOrigInstallGate) ((void(*)(id,SEL,BOOL))gOrigInstallGate)(self,cmd,YES);
}

static void XLInstallGateForAccount(id self, SEL cmd, id account) {
    if (gOrigInstallGateForAccount) ((void(*)(id,SEL,id))gOrigInstallGateForAccount)(self,cmd,account);
    SEL s = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    if ([self respondsToSelector:s]) ((void(*)(id,SEL,BOOL))objc_msgSend)(self,s,YES);
}

static void XLSyncGate(void) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"T1LiquidGlassRedesignPersistedGate"];
    Class c = NSClassFromString(@"_TtC17TFSUtilitiesSwift32LiquidGlassCompatibilityOverride");
    SEL s = NSSelectorFromString(@"applyOverrideIfNeeded");
    if (c && [c respondsToSelector:s]) ((void(*)(id,SEL))objc_msgSend)(c,s);
}

static UIWindow *XLKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) return w;
    }
    return nil;
}

static UIViewController *XLTopController(void) {
    UIViewController *vc = XLKeyWindow().rootViewController;
    for (NSInteger i=0; vc && i<16; i++) {
        if (vc.presentedViewController) { vc = vc.presentedViewController; continue; }
        if ([vc isKindOfClass:UINavigationController.class]) {
            UIViewController *n=((UINavigationController *)vc).visibleViewController;
            if (n) { vc=n; continue; }
        }
        if ([vc isKindOfClass:UITabBarController.class]) {
            UIViewController *n=((UITabBarController *)vc).selectedViewController;
            if (n) { vc=n; continue; }
        }
        break;
    }
    return vc;
}

static BOOL XLTryOpenDash(id obj, UIViewController *presenter) {
    if (!obj) return NO;
    for (NSString *n in @[@"_t1_action_didTapDashButton",
                           @"presentDashFromViewController",
                           @"presentDashFromAppSplitSideBarViewController"]) {
        SEL s=NSSelectorFromString(n);
        if ([obj respondsToSelector:s]) {
            ((void(*)(id,SEL))objc_msgSend)(obj,s);
            return YES;
        }
    }
    for (NSString *n in @[@"presentDashFromViewController:",
                           @"presentDashFromAppSplitSideBarViewController:"]) {
        SEL s=NSSelectorFromString(n);
        if ([obj respondsToSelector:s]) {
            ((void(*)(id,SEL,id))objc_msgSend)(obj,s,presenter);
            return YES;
        }
    }
    return NO;
}

static void XLOpenSidebar(UIViewController *owner) {
    UIViewController *top=XLTopController();
    NSMutableArray *q=[NSMutableArray array];
    if (owner) [q addObject:owner];
    if (top && top!=owner) [q addObject:top];
    for (NSUInteger i=0;i<q.count && i<64;i++) {
        UIViewController *vc=q[i];
        if (XLTryOpenDash(vc,top ?: owner)) return;
        if (vc.parentViewController && ![q containsObject:vc.parentViewController]) [q addObject:vc.parentViewController];
        for (UIViewController *child in vc.childViewControllers) if (![q containsObject:child]) [q addObject:child];
    }
    XLTryOpenDash(UIApplication.sharedApplication.delegate,top ?: owner);
}

@interface XLActionTarget : NSObject
+ (instancetype)shared;
- (void)compose:(id)sender;
- (void)composeLong:(UILongPressGestureRecognizer *)g;
- (void)sidebar:(id)sender;
- (void)edge:(UIScreenEdgePanGestureRecognizer *)g;
@end

@implementation XLActionTarget
+ (instancetype)shared { static id x; static dispatch_once_t once; dispatch_once(&once,^{x=[self new];}); return x; }
- (void)compose:(id)sender {
    (void)sender;
    NSURL *u=[NSURL URLWithString:@"twitter://post"];
    if (u) [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
}
- (void)composeLong:(UILongPressGestureRecognizer *)g {
    if (g.state==UIGestureRecognizerStateBegan) [self compose:g.view];
}
- (void)sidebar:(id)sender {
    XLOpenSidebar(objc_getAssociatedObject(sender,&kOwnerKey));
}
- (void)edge:(UIScreenEdgePanGestureRecognizer *)g {
    if (g.state==UIGestureRecognizerStateBegan) XLOpenSidebar(objc_getAssociatedObject(g,&kOwnerKey));
}
@end

static void XLInstallCompose(UIViewController *vc) {
    if (!vc.view) return;
    UIView *host=objc_getAssociatedObject(vc,&kComposeKey);
    if (!host) {
        host=[[UIView alloc] initWithFrame:CGRectZero];
        host.clipsToBounds=YES;
        UIVisualEffectView *blur=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
        blur.tag=801;
        [host addSubview:blur];

        UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
        button.tag=802;
        UIImageSymbolConfiguration *cfg=[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
        [button setImage:[UIImage systemImageNamed:@"plus" withConfiguration:cfg] forState:UIControlStateNormal];
        button.accessibilityLabel=@"New post";
        [button addTarget:XLActionTarget.shared action:@selector(compose:) forControlEvents:UIControlEventTouchUpInside];
        [button addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:XLActionTarget.shared action:@selector(composeLong:)]];
        [host addSubview:button];
        [vc.view addSubview:host];
        objc_setAssociatedObject(vc,&kComposeKey,host,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIEdgeInsets safe=vc.view.safeAreaInsets;
    CGFloat size=56.0;
    CGFloat bottom=MAX(safe.bottom,8.0)+72.0;
    host.frame=CGRectMake(vc.view.bounds.size.width-size-18.0,vc.view.bounds.size.height-size-bottom,size,size);
    host.layer.cornerRadius=size/2.0;
    host.layer.cornerCurve=kCACornerCurveContinuous;
    host.layer.shadowOpacity=0.16;
    host.layer.shadowRadius=12.0;
    host.layer.shadowOffset=CGSizeMake(0,5);
    ((UIView *)[host viewWithTag:801]).frame=host.bounds;
    ((UIView *)[host viewWithTag:802]).frame=host.bounds;
    [vc.view bringSubviewToFront:host];
}

static void XLInstallSidebar(UIViewController *vc) {
    if (!vc.view) return;
    UIButton *b=objc_getAssociatedObject(vc,&kSidebarKey);
    if (!b) {
        b=[UIButton buttonWithType:UIButtonTypeSystem];
        UIImageSymbolConfiguration *cfg=[UIImageSymbolConfiguration configurationWithPointSize:27 weight:UIImageSymbolWeightRegular];
        [b setImage:[UIImage systemImageNamed:@"person.crop.circle.fill" withConfiguration:cfg] forState:UIControlStateNormal];
        b.accessibilityLabel=@"Account sidebar";
        [b addTarget:XLActionTarget.shared action:@selector(sidebar:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(b,&kOwnerKey,vc,OBJC_ASSOCIATION_ASSIGN);
        [vc.view addSubview:b];
        objc_setAssociatedObject(vc,&kSidebarKey,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    b.frame=CGRectMake(10.0,MAX(vc.view.safeAreaInsets.top+4.0,12.0),44.0,44.0);
    [vc.view bringSubviewToFront:b];

    UIScreenEdgePanGestureRecognizer *g=objc_getAssociatedObject(vc,&kEdgeKey);
    if (!g) {
        g=[[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:XLActionTarget.shared action:@selector(edge:)];
        g.edges=UIRectEdgeLeft;
        g.cancelsTouchesInView=NO;
        objc_setAssociatedObject(g,&kOwnerKey,vc,OBJC_ASSOCIATION_ASSIGN);
        [vc.view addGestureRecognizer:g];
        objc_setAssociatedObject(vc,&kEdgeKey,g,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void XLThemeView(UIView *root) {
    if (!root) return;
    if ([root isKindOfClass:UITabBar.class]) {
        UITabBar *bar=(UITabBar *)root;
        UIColor *accent=bar.tintColor ?: UIColor.systemBlueColor;
        bar.tintColor=accent;
        if (@available(iOS 13.0,*)) bar.unselectedItemTintColor=UIColor.secondaryLabelColor;
        NSDictionary *normal=@{NSForegroundColorAttributeName:UIColor.secondaryLabelColor};
        NSDictionary *selected=@{NSForegroundColorAttributeName:accent};
        for (UITabBarItem *item in bar.items ?: @[]) {
            [item setTitleTextAttributes:normal forState:UIControlStateNormal];
            [item setTitleTextAttributes:selected forState:UIControlStateSelected];
        }
    }
    for (UIView *v in root.subviews) XLThemeView(v);
}

static void XLRefresh(UIViewController *vc) {
    XLInstallCompose(vc);
    XLInstallSidebar(vc);
    XLThemeView(vc.view);
}

static void XLXNavLoad(id self,SEL cmd){ if(gOrigXNavLoad)((void(*)(id,SEL))gOrigXNavLoad)(self,cmd); XLRefresh(self); }
static void XLXNavAppear(id self,SEL cmd,BOOL a){ if(gOrigXNavAppear)((void(*)(id,SEL,BOOL))gOrigXNavAppear)(self,cmd,a); XLRefresh(self); }
static void XLXNavLayout(id self,SEL cmd){ if(gOrigXNavLayout)((void(*)(id,SEL))gOrigXNavLayout)(self,cmd); XLRefresh(self); }

static void XLLGLoad(id self,SEL cmd){ if(gOrigLGLoad)((void(*)(id,SEL))gOrigLGLoad)(self,cmd); XLThemeView(((UIViewController*)self).view); }
static void XLLGAppear(id self,SEL cmd,BOOL a){ if(gOrigLGAppear)((void(*)(id,SEL,BOOL))gOrigLGAppear)(self,cmd,a); XLThemeView(((UIViewController*)self).view); }
static void XLLGSetTabs(id self,SEL cmd,id tabs){ if(gOrigLGSetTabs)((void(*)(id,SEL,id))gOrigLGSetTabs)(self,cmd,tabs); XLThemeView(((UIViewController*)self).view); }
static void XLLGSyncItems(id self,SEL cmd){ if(gOrigLGSyncItems)((void(*)(id,SEL))gOrigLGSyncItems)(self,cmd); XLThemeView(((UIViewController*)self).view); }
static void XLLGSyncBadges(id self,SEL cmd){ if(gOrigLGSyncBadges)((void(*)(id,SEL))gOrigLGSyncBadges)(self,cmd); XLThemeView(((UIViewController*)self).view); }
static void XLLGTrait(id self,SEL cmd,id old){ if(gOrigLGTrait)((void(*)(id,SEL,id))gOrigLGTrait)(self,cmd,old); XLThemeView(((UIViewController*)self).view); }
static void XLLGLayout(id self,SEL cmd){ if(gOrigLGLayout)((void(*)(id,SEL))gOrigLGLayout)(self,cmd); XLThemeView(((UIViewController*)self).view); }
static void XLXTabLayout(id self,SEL cmd){ if(gOrigXTabViewLayout)((void(*)(id,SEL))gOrigXTabViewLayout)(self,cmd); if([self isKindOfClass:UIView.class]) XLThemeView(self); }

static void XLInstallActivation(void) {
    Class c=NSClassFromString(@"T1LiquidGlassDebugSettings");
    if(c) XLHook(c,NSSelectorFromString(@"useTabBarControllerEnabled"),YES,(IMP)XLYes,NULL);

    c=NSClassFromString(@"_TtC17TFSUtilitiesSwift11LiquidGlass");
    if(c) XLHook(c,NSSelectorFromString(@"isEnabled"),YES,(IMP)XLYes,NULL);

    c=NSClassFromString(@"_TtC14T1TwitterSwift27LiquidGlassRedesignFeatures");
    if(c) XLHook(c,NSSelectorFromString(@"isRedesignEnabled"),NO,(IMP)XLYes,NULL);

    c=NSClassFromString(@"T1LiquidGlassGateInstaller");
    if(c) {
        XLHook(c,NSSelectorFromString(@"installGateWithRedesignEnabled:"),YES,(IMP)XLInstallGate,&gOrigInstallGate);
        XLHook(c,NSSelectorFromString(@"installGateForAccount:"),YES,(IMP)XLInstallGateForAccount,&gOrigInstallGateForAccount);
    }

    c=NSClassFromString(@"TFNTwitterAccount");
    if(c) XLHook(c,NSSelectorFromString(@"isDummyTest1FeatureEnabled"),NO,(IMP)XLYes,NULL);

    XLSyncGate();
    c=NSClassFromString(@"T1LiquidGlassGateInstaller");
    SEL s=NSSelectorFromString(@"installGateWithRedesignEnabled:");
    if(c && [c respondsToSelector:s]) ((void(*)(id,SEL,BOOL))objc_msgSend)(c,s,YES);
}

static void XLInstallUIFixes(void) {
    Class c=NSClassFromString(@"_TtC11XNavigation16TabBarController");
    if(c) {
        XLHook(c,@selector(viewDidLoad),NO,(IMP)XLXNavLoad,&gOrigXNavLoad);
        XLHook(c,@selector(viewDidAppear:),NO,(IMP)XLXNavAppear,&gOrigXNavAppear);
        XLHook(c,@selector(viewDidLayoutSubviews),NO,(IMP)XLXNavLayout,&gOrigXNavLayout);
    }

    c=NSClassFromString(@"T1LiquidGlassTabBarController");
    if(c) {
        XLHook(c,@selector(viewDidLoad),NO,(IMP)XLLGLoad,&gOrigLGLoad);
        XLHook(c,@selector(viewDidAppear:),NO,(IMP)XLLGAppear,&gOrigLGAppear);
        XLHook(c,NSSelectorFromString(@"setTabViews:"),NO,(IMP)XLLGSetTabs,&gOrigLGSetTabs);
        XLHook(c,NSSelectorFromString(@"_t1_syncTabBarItems"),NO,(IMP)XLLGSyncItems,&gOrigLGSyncItems);
        XLHook(c,NSSelectorFromString(@"syncBadges"),NO,(IMP)XLLGSyncBadges,&gOrigLGSyncBadges);
        XLHook(c,@selector(traitCollectionDidChange:),NO,(IMP)XLLGTrait,&gOrigLGTrait);
        XLHook(c,@selector(viewDidLayoutSubviews),NO,(IMP)XLLGLayout,&gOrigLGLayout);
    }

    c=NSClassFromString(@"_TtC11XNavigation10TabBarView");
    if(c) XLHook(c,@selector(layoutSubviews),NO,(IMP)XLXTabLayout,&gOrigXTabViewLayout);
}

static void XLInstallAll(void){ XLInstallActivation(); XLInstallUIFixes(); }

static void XLSchedule(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{XLInstallAll();});
}

__attribute__((constructor))
static void XLInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlass] 1.1.0 standalone loaded");
        XLInstallAll();
        XLSchedule(0.00); XLSchedule(0.05); XLSchedule(0.20); XLSchedule(0.50);
        XLSchedule(1.00); XLSchedule(2.00); XLSchedule(4.00);
    }
}
