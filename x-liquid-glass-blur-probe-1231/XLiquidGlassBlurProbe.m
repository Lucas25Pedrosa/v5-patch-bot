#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kXBPLogFileName = @"XLiquidGlassBlurProbe12.31.log";
static NSString *const kXBPVersion = @"0.1.1-safe";
static const NSUInteger kXBPMaxLogBytes = 4 * 1024 * 1024;

static IMP gOrigSearchLayout = NULL;
static IMP gOrigSearchDidAppear = NULL;
static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;

static BOOL gSearchHooksInstalled = NO;
static BOOL gNFBHookInstalled = NO;
static NSUInteger gCaptureCount = 0;

static char kXBPCaptureScheduledKey;
static char kXBPLastSignatureKey;

#pragma mark - Logging

static NSString *XBPLogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kXBPLogFileName];
}

static NSString *XBPStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:NSDate.date];
}

static NSString *XBPText(id value) {
    if (!value || value == NSNull.null) return @"-";
    NSString *s = [value description] ?: @"-";
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (s.length > 700) {
        s = [[s substringToIndex:700] stringByAppendingString:@"…"];
    }
    return s.length ? s : @"-";
}

static void XBPTrimLogIfNeeded(void) {
    NSString *path = XBPLogPath();
    NSDictionary *attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size <= kXBPMaxLogBytes) return;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length <= kXBPMaxLogBytes) return;

    NSUInteger keep = kXBPMaxLogBytes / 2;
    NSData *tail =
        [data subdataWithRange:NSMakeRange(data.length - keep, keep)];
    [tail writeToFile:path atomically:YES];
}

static void XBPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void XBPLog(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args, format);
    NSString *body =
        [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"[%@] %@\n", XBPStamp(), body ?: @""];
    NSLog(@"[XLiquidGlassBlurProbe] %@", body ?: @"");

    @synchronized([NSFileManager defaultManager]) {
        NSString *path = XBPLogPath();

        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [@"" writeToFile:path
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:nil];
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }

        XBPTrimLogIfNeeded();
    }
}

#pragma mark - Helpers

static BOOL XBPHookMethod(Class cls,
                          SEL sel,
                          IMP replacement,
                          IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP current = class_getMethodImplementation(cls, sel);
    if (current == replacement) return YES;

    if (originalOut && !*originalOut) *originalOut = current;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    class_replaceMethod(cls, sel, replacement, types);
    return class_getMethodImplementation(cls, sel) == replacement;
}

static BOOL XBPStringHasAny(NSString *text, NSArray<NSString *> *needles) {
    if (!text.length) return NO;

    NSString *lower = text.lowercaseString;
    for (NSString *needle in needles) {
        if ([lower containsString:needle.lowercaseString]) return YES;
    }
    return NO;
}

static NSArray<NSString *> *XBPFragments(void) {
    static NSArray<NSString *> *fragments;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fragments = @[
            @"blur", @"glass", @"effect", @"backdrop",
            @"material", @"scrolledge", @"scroll_edge", @"xds"
        ];
    });
    return fragments;
}

static id XBPSafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *XBPLayerSignals(CALayer *layer) {
    if (!layer) return @"-";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    id filters = XBPSafeValueForKey(layer, @"filters");
    if (filters) {
        [parts addObject:
            [NSString stringWithFormat:@"filters=%@", XBPText(filters)]];
    }

    id backgroundFilters = XBPSafeValueForKey(layer, @"backgroundFilters");
    if (backgroundFilters) {
        [parts addObject:
            [NSString stringWithFormat:@"backgroundFilters=%@",
             XBPText(backgroundFilters)]];
    }

    id compositingFilter = XBPSafeValueForKey(layer, @"compositingFilter");
    if (compositingFilter) {
        [parts addObject:
            [NSString stringWithFormat:@"compositingFilter=%@",
             XBPText(compositingFilter)]];
    }

    return parts.count ? [parts componentsJoinedByString:@" "] : @"-";
}

static NSString *XBPEffectDescription(UIView *view) {
    if (![view isKindOfClass:UIVisualEffectView.class]) return @"-";

    UIVisualEffect *effect = ((UIVisualEffectView *)view).effect;
    if (!effect) return @"nil";

    return [NSString stringWithFormat:@"%@:%@",
            NSStringFromClass(effect.class),
            XBPText(effect)];
}

static NSString *XBPSuperviewChain(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    UIView *current = view;
    for (NSUInteger depth = 0; current && depth < 12; depth++) {
        [parts addObject:NSStringFromClass(current.class) ?: @"?"];
        current = current.superview;
    }

    return [parts componentsJoinedByString:@" <- "];
}

static NSString *XBPNearestControllerName(UIView *view) {
    UIResponder *responder = view;

    for (NSUInteger depth = 0; responder && depth < 80; depth++) {
        if ([responder isKindOfClass:UIViewController.class]) {
            return NSStringFromClass([responder class]) ?: @"-";
        }
        responder = responder.nextResponder;
    }

    return @"-";
}

static BOOL XBPViewLooksInteresting(UIView *view) {
    if (!view) return NO;

    NSString *className = NSStringFromClass(view.class) ?: @"";
    if (XBPStringHasAny(className, XBPFragments())) return YES;

    if ([view isKindOfClass:UIVisualEffectView.class]) return YES;

    NSString *effect = XBPEffectDescription(view);
    if (XBPStringHasAny(effect, XBPFragments())) return YES;

    NSString *layer = XBPLayerSignals(view.layer);
    if (XBPStringHasAny(layer, XBPFragments()) ||
        [layer.lowercaseString containsString:@"gaussian"] ||
        [layer.lowercaseString containsString:@"variable"]) {
        return YES;
    }

    return NO;
}

static NSArray<UIView *> *XBPCandidateViews(UIView *root) {
    if (!root) return @[];

    NSMutableArray<UIView *> *queue =
        [NSMutableArray arrayWithObject:root];
    NSMutableArray<UIView *> *result = [NSMutableArray array];

    for (NSUInteger i = 0; i < queue.count && i < 5000; i++) {
        UIView *view = queue[i];

        if (XBPViewLooksInteresting(view)) {
            [result addObject:view];
            if (result.count >= 250) break;
        }

        [queue addObjectsFromArray:view.subviews ?: @[]];
    }

    return result;
}

static void XBPDumpEnvironment(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};

    XBPLog(@"ENV probe=%@ appVersion=%@ appBuild=%@ bundle=%@ system=%@ UIDesignRequiresCompatibility=%@",
           kXBPVersion,
           XBPText(info[@"CFBundleShortVersionString"]),
           XBPText(info[@"CFBundleVersion"]),
           XBPText(info[@"CFBundleIdentifier"]),
           UIDevice.currentDevice.systemVersion,
           XBPText(info[@"UIDesignRequiresCompatibility"]));
}

static void XBPDumpClassPresence(void) {
    NSArray<NSString *> *names = @[
        @"TTSSearchContainerViewControllerV2",
        @"XDesignSystem.ScrollEdgeTreatment",
        @"XDesignSystem.Blur",
        @"XDesignSystem.Glass",
        @"UIGlassEffect",
        @"UIVisualEffectView",
        @"_TtCC5UIKit20ScrollEdgeEffectView12BackdropView",
        @"TFNUISwift.LegacySegmentedTabBarView"
    ];

    XBPLog(@"CLASS_PRESENCE_BEGIN");

    for (NSString *name in names) {
        Class cls = NSClassFromString(name);

        XBPLog(@"CLASS requested=%@ resolved=%@ ptr=%p superclass=%@",
               name,
               cls ? NSStringFromClass(cls) : @"nil",
               cls,
               cls ? NSStringFromClass(class_getSuperclass(cls)) : @"-");
    }

    XBPLog(@"CLASS_PRESENCE_END");
}

#pragma mark - Search capture

static void XBPDumpCandidate(UIView *view,
                             UIViewController *controller,
                             NSUInteger index,
                             NSString *reason) {
    UIWindow *window = view.window ?: controller.view.window;

    CGRect frameWindow =
        window ? [view convertRect:view.bounds toView:window] : CGRectZero;

    CGRect frameSearch =
        [view convertRect:view.bounds toView:controller.view];

    XBPLog(@"SEARCH_CANDIDATE index=%lu reason=%@ ptr=%p class=%@ superclass=%@ frameWindow=%@ frameSearch=%@ bounds=%@ alpha=%.3f hidden=%d clips=%d bg=%@ effect=%@ layer=%@ owner=%@ chain=%@",
           (unsigned long)index,
           reason ?: @"-",
           view,
           NSStringFromClass(view.class),
           NSStringFromClass(class_getSuperclass(view.class)),
           NSStringFromCGRect(frameWindow),
           NSStringFromCGRect(frameSearch),
           NSStringFromCGRect(view.bounds),
           view.alpha,
           view.hidden,
           view.clipsToBounds,
           XBPText(view.backgroundColor),
           XBPEffectDescription(view),
           XBPLayerSignals(view.layer),
           XBPNearestControllerName(view),
           XBPSuperviewChain(view));
}

static NSString *XBPSearchSignature(UIViewController *controller) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    for (UIView *view in XBPCandidateViews(controller.view)) {
        UIWindow *window = view.window ?: controller.view.window;
        CGRect frame =
            window ? [view convertRect:view.bounds toView:window] : view.frame;

        [parts addObject:
            [NSString stringWithFormat:@"%@|%@|%.2f|%d|%@|%@",
             NSStringFromClass(view.class),
             NSStringFromCGRect(frame),
             view.alpha,
             view.hidden,
             XBPEffectDescription(view),
             XBPLayerSignals(view.layer)]];
    }

    return [parts componentsJoinedByString:@"\n"];
}

static void XBPCaptureSearch(UIViewController *controller,
                             NSString *reason,
                             BOOL force) {
    if (!controller || !controller.isViewLoaded || !controller.view.window) {
        XBPLog(@"SEARCH_CAPTURE_SKIPPED reason=%@ visible=0", reason ?: @"-");
        return;
    }

    NSString *signature = XBPSearchSignature(controller);
    NSString *previous =
        objc_getAssociatedObject(controller, &kXBPLastSignatureKey);

    if (!force && [previous isEqualToString:signature]) return;

    objc_setAssociatedObject(controller,
                             &kXBPLastSignatureKey,
                             signature,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);

    gCaptureCount++;

    XBPLog(@"================ SEARCH_CAPTURE #%lu reason=%@ ================",
           (unsigned long)gCaptureCount,
           reason ?: @"-");

    UIWindow *window = controller.view.window;

    XBPLog(@"SEARCH_ROOT controller=%@ ptr=%p view=%p frameWindow=%@ bounds=%@ children=%lu",
           NSStringFromClass(controller.class),
           controller,
           controller.view,
           window
             ? NSStringFromCGRect(
                 [controller.view convertRect:controller.view.bounds
                                        toView:window])
             : @"-",
           NSStringFromCGRect(controller.view.bounds),
           (unsigned long)controller.childViewControllers.count);

    NSArray<UIView *> *candidates = XBPCandidateViews(controller.view);

    XBPLog(@"SEARCH_CANDIDATE_COUNT=%lu",
           (unsigned long)candidates.count);

    NSUInteger index = 0;
    for (UIView *candidate in candidates) {
        XBPDumpCandidate(candidate, controller, index++, reason);
    }

    XBPLog(@"================ END_SEARCH_CAPTURE #%lu ================",
           (unsigned long)gCaptureCount);
}

static UIViewController *XBPVisibleSearchController(void) {
    Class searchClass =
        NSClassFromString(@"TTSSearchContainerViewControllerV2");
    if (!searchClass) return nil;

    NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;

        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.rootViewController) {
                [queue addObject:window.rootViewController];
            }
        }
    }

    for (NSUInteger i = 0; i < queue.count && i < 900; i++) {
        UIViewController *vc = queue[i];
        if (!vc) continue;

        NSValue *key = [NSValue valueWithNonretainedObject:vc];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];

        if ([vc isKindOfClass:searchClass] &&
            vc.isViewLoaded &&
            vc.view.window) {
            return vc;
        }

        if (vc.presentedViewController) {
            [queue addObject:vc.presentedViewController];
        }

        [queue addObjectsFromArray:vc.childViewControllers ?: @[]];

        if ([vc isKindOfClass:UINavigationController.class]) {
            [queue addObjectsFromArray:
                ((UINavigationController *)vc).viewControllers ?: @[]];
        }

        if ([vc isKindOfClass:UITabBarController.class]) {
            [queue addObjectsFromArray:
                ((UITabBarController *)vc).viewControllers ?: @[]];
        }
    }

    return nil;
}

static void XBPScheduleSearchCapture(UIViewController *controller,
                                     NSString *reason) {
    if (!controller) return;

    NSNumber *scheduled =
        objc_getAssociatedObject(controller, &kXBPCaptureScheduledKey);

    if (scheduled.boolValue) return;

    objc_setAssociatedObject(controller,
                             &kXBPCaptureScheduledKey,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIViewController *weakController = controller;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(0.08 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            UIViewController *strongController = weakController;
            if (!strongController) return;

            objc_setAssociatedObject(strongController,
                                     &kXBPCaptureScheduledKey,
                                     @NO,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            XBPCaptureSearch(strongController, reason, NO);
        });
}

#pragma mark - Minimal Search hooks only

static void XBPSearchLayout(id self, SEL cmd) {
    if (gOrigSearchLayout) {
        ((void(*)(id,SEL))gOrigSearchLayout)(self, cmd);
    }

    if (![self isKindOfClass:UIViewController.class]) return;

    XBPScheduleSearchCapture(
        (UIViewController *)self,
        @"layout-settled");
}

static void XBPSearchDidAppear(id self,
                               SEL cmd,
                               BOOL animated) {
    if (gOrigSearchDidAppear) {
        ((void(*)(id,SEL,BOOL))gOrigSearchDidAppear)(
            self, cmd, animated);
    }

    if (![self isKindOfClass:UIViewController.class]) return;

    UIViewController *controller = (UIViewController *)self;

    XBPCaptureSearch(controller, @"didAppear", YES);

    __weak UIViewController *weakController = controller;

    for (NSNumber *delayValue in @[@0.20, @0.60]) {
        NSTimeInterval delay = delayValue.doubleValue;

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                UIViewController *strongController = weakController;
                if (!strongController) return;

                XBPCaptureSearch(
                    strongController,
                    [NSString stringWithFormat:@"didAppear-delayed-%.2f",
                     delay],
                    NO);
            });
    }
}

static void XBPInstallSearchHooks(void) {
    if (gSearchHooksInstalled) return;

    Class cls =
        NSClassFromString(@"TTSSearchContainerViewControllerV2");
    if (!cls) return;

    BOOL layout =
        XBPHookMethod(cls,
                      @selector(viewDidLayoutSubviews),
                      (IMP)XBPSearchLayout,
                      &gOrigSearchLayout);

    BOOL appear =
        XBPHookMethod(cls,
                      @selector(viewDidAppear:),
                      (IMP)XBPSearchDidAppear,
                      &gOrigSearchDidAppear);

    gSearchHooksInstalled = layout || appear;

    if (gSearchHooksInstalled) {
        XBPLog(@"Installed SAFE Search-only hooks layout=%d appear=%d",
               layout,
               appear);
    }
}

#pragma mark - NFB menu

@interface XLiquidGlassBlurProbeViewController : UITableViewController
@end

@implementation XLiquidGlassBlurProbeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Blur Probe 12.31";
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
    return @"0.1.1 Safe: somente leitura. Não intercepta UIVisualEffectView, não hooka classes Blur/Glass/ScrollEdge e não altera efeitos. Observa apenas o container da Busca.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"XBPBlurSafeCell";

    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
          reuseIdentifier:identifier];
    }

    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (indexPath.row == 0) {
        cell.textLabel.text = @"Capturar Search agora";
        cell.detailTextLabel.text =
            [NSString stringWithFormat:@"Capturas: %lu",
             (unsigned long)gCaptureCount];
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"Copiar relatório";
        cell.detailTextLabel.text = kXBPLogFileName;
    } else {
        cell.textLabel.text = @"Limpar relatório";
        cell.detailTextLabel.text = @"Remove o relatório anterior.";
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.row == 0) {
        UIViewController *search = XBPVisibleSearchController();

        if (search) {
            XBPCaptureSearch(search, @"manual", YES);
        } else {
            XBPLog(@"MANUAL_CAPTURE visibleSearch=0");
        }

        [tableView reloadData];
        return;
    }

    if (indexPath.row == 1) {
        NSString *report =
            [NSString stringWithContentsOfFile:XBPLogPath()
                                      encoding:NSUTF8StringEncoding
                                         error:nil] ?: @"";

        UIPasteboard.generalPasteboard.string = report;

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"Blur Probe 12.31"
                                 message:
                    [NSString stringWithFormat:
                        @"Relatório copiado (%lu caracteres).",
                        (unsigned long)report.length]
                          preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:nil]];

        [self presentViewController:alert
                           animated:YES
                         completion:nil];
        return;
    }

    [[NSFileManager defaultManager]
        removeItemAtPath:XBPLogPath()
                   error:nil];

    gCaptureCount = 0;
    XBPLog(@"LOG RESET");
    XBPDumpEnvironment();
    XBPDumpClassPresence();
    [tableView reloadData];
}

@end

static BOOL XBPSectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;

        if ([entry[@"action"]
                isEqualToString:@"showXLiquidGlassBlurProbe1231Safe"]) {
            return YES;
        }
    }

    return NO;
}

static void XBPInjectNFBSection(id controller) {
    NSArray *sections = nil;

    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        return;
    }

    if (![sections isKindOfClass:NSArray.class] ||
        XBPSectionsContainEntry(sections)) {
        return;
    }

    NSMutableArray *updated = [sections mutableCopy];

    [updated addObject:@{
        @"title": @"Blur Probe 12.31",
        @"subtitle": @"Safe Search-only diagnostic.",
        @"icon": @"waveform.path.ecg",
        @"action": @"showXLiquidGlassBlurProbe1231Safe"
    }];

    @try {
        [controller setValue:[updated copy]
                      forKey:@"sections"];
    } @catch (__unused NSException *exception) {
    }
}

static void XBPNFBSetupSections(id self, SEL cmd) {
    if (gOrigNFBSetupSections) {
        ((void(*)(id,SEL))gOrigNFBSetupSections)(self, cmd);
    }

    XBPInjectNFBSection(self);
}

static void XBPNFBViewWillAppear(id self,
                                 SEL cmd,
                                 BOOL animated) {
    if (gOrigNFBViewWillAppear) {
        ((void(*)(id,SEL,BOOL))gOrigNFBViewWillAppear)(
            self, cmd, animated);
    }

    XBPInjectNFBSection(self);

    UITableView *tableView = nil;
    @try {
        tableView = [self valueForKey:@"tableView"];
    } @catch (__unused NSException *exception) {
    }

    [tableView reloadData];
}

static void XBPShowProbeSettings(id self, SEL cmd) {
    (void)cmd;

    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassBlurProbeViewController *vc =
        [XLiquidGlassBlurProbeViewController new];

    UINavigationController *navigation =
        ((UIViewController *)self).navigationController;

    if (navigation) {
        [navigation pushViewController:vc animated:YES];
    } else {
        UINavigationController *wrapper =
            [[UINavigationController alloc]
                initWithRootViewController:vc];

        [(UIViewController *)self
            presentViewController:wrapper
                         animated:YES
                       completion:nil];
    }
}

static void XBPInstallNFBIntegration(void) {
    if (gNFBHookInstalled) return;

    Class cls =
        NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;

    class_addMethod(
        cls,
        NSSelectorFromString(@"showXLiquidGlassBlurProbe1231Safe"),
        (IMP)XBPShowProbeSettings,
        "v@:");

    BOOL setup =
        XBPHookMethod(cls,
                      NSSelectorFromString(@"setupSections"),
                      (IMP)XBPNFBSetupSections,
                      &gOrigNFBSetupSections);

    BOOL appear =
        XBPHookMethod(cls,
                      @selector(viewWillAppear:),
                      (IMP)XBPNFBViewWillAppear,
                      &gOrigNFBViewWillAppear);

    gNFBHookInstalled = setup || appear;

    if (gNFBHookInstalled) {
        XBPLog(@"Installed optional NeoFreeBird SAFE Blur Probe menu.");
    }
}

#pragma mark - Install

static void XBPInstallAll(void) {
    XBPInstallSearchHooks();
    XBPInstallNFBIntegration();
}

static void XBPScheduleInstall(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            XBPInstallAll();
        });
}

__attribute__((constructor))
static void XLiquidGlassBlurProbeInit(void) {
    @autoreleasepool {
        XBPLog(@"========== XLiquidGlass Blur Probe 12.31 %@ loaded ==========",
               kXBPVersion);
        XBPLog(@"logPath=%@", XBPLogPath());
        XBPLog(@"SAFE mode: Search VC + NFB only; no global effect/layout hooks.");

        XBPDumpEnvironment();
        XBPDumpClassPresence();

        XBPInstallAll();

        for (NSNumber *delayValue in @[@0.10, @0.50, @1.50, @3.00]) {
            XBPScheduleInstall(delayValue.doubleValue);
        }
    }
}
