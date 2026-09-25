#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kXBPLogFileName = @"XLiquidGlassBadgeProbe.log";
static const NSUInteger kXBPMaxLogBytes = 2 * 1024 * 1024;

static IMP gOrigViewDidLoad = NULL;
static IMP gOrigViewDidAppear = NULL;
static IMP gOrigSetTabViews = NULL;
static IMP gOrigSyncTabBarItems = NULL;
static IMP gOrigSyncBadges = NULL;
static IMP gOrigTraitCollectionDidChange = NULL;
static IMP gOrigViewDidLayoutSubviews = NULL;
static IMP gOrigSetBadgeValue = NULL;
static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;

static BOOL gControllerHooksInstalled = NO;
static BOOL gTabBarItemHookInstalled = NO;
static BOOL gNFBHookInstalled = NO;
static NSUInteger gCaptureCount = 0;
static NSTimeInterval gLastLayoutCapture = 0;

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

static void XBPTrimLogIfNeeded(void) {
    NSString *path = XBPLogPath();
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size <= kXBPMaxLogBytes) return;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length <= kXBPMaxLogBytes) return;

    NSUInteger keep = kXBPMaxLogBytes / 2;
    NSData *tail = [data subdataWithRange:NSMakeRange(data.length - keep, keep)];
    [tail writeToFile:path atomically:YES];
}

static void XBPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void XBPLog(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", XBPStamp(), body ?: @""];
    NSLog(@"[XLiquidGlassBadgeProbe] %@", body ?: @"");

    @synchronized([NSFileManager defaultManager]) {
        NSString *path = XBPLogPath();
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            [handle writeData:data];
            [handle closeFile];
        }
        XBPTrimLogIfNeeded();
    }
}

static NSString *XBPStringOrDash(id value) {
    if (!value || value == NSNull.null) return @"-";
    NSString *s = [value description];
    return s.length ? s : @"-";
}

static NSString *XBPMethodEncoding(Class cls, SEL sel) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return @"-";
    const char *types = method_getTypeEncoding(method);
    return types ? [NSString stringWithUTF8String:types] : @"-";
}

static BOOL XBPHookMethod(Class cls, SEL sel, IMP replacement, IMP *originalOut) {
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

static UIWindow *XBPActiveWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (!fallback && !window.hidden) fallback = window;
            if (window.isKeyWindow) return window;
        }
    }
    return fallback;
}

static id XBPFindLiquidGlassController(void) {
    Class target = NSClassFromString(@"T1LiquidGlassTabBarController");
    if (!target) return nil;

    UIViewController *root = XBPActiveWindow().rootViewController;
    if (!root) return nil;

    NSMutableArray<UIViewController *> *queue = [NSMutableArray arrayWithObject:root];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];

    for (NSUInteger i = 0; i < queue.count && i < 256; i++) {
        UIViewController *vc = queue[i];
        NSValue *key = [NSValue valueWithNonretainedObject:vc];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];

        if ([vc isKindOfClass:target]) return vc;

        if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
        [queue addObjectsFromArray:vc.childViewControllers ?: @[]];

        if ([vc isKindOfClass:UINavigationController.class]) {
            [queue addObjectsFromArray:((UINavigationController *)vc).viewControllers ?: @[]];
        }
        if ([vc isKindOfClass:UITabBarController.class]) {
            [queue addObjectsFromArray:((UITabBarController *)vc).viewControllers ?: @[]];
        }
    }
    return nil;
}

static BOOL XBPInterestingViewClass(NSString *name) {
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"badge"] ||
           [lower containsString:@"tab"] ||
           [lower containsString:@"selection"] ||
           [lower containsString:@"platter"] ||
           [lower containsString:@"button"] ||
           [lower containsString:@"label"] ||
           [lower containsString:@"image"];
}

static BOOL XBPInterestingMethodName(NSString *name) {
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"badge"] ||
           [lower containsString:@"maximized"] ||
           [lower containsString:@"minimized"] ||
           [lower containsString:@"compact"] ||
           [lower containsString:@"selection"];
}

static void XBPDumpInterestingMethodsForClass(Class cls, NSMutableSet<NSString *> *seenClasses) {
    if (!cls || !seenClasses) return;

    NSString *className = NSStringFromClass(cls);
    if (!className.length || [seenClasses containsObject:className]) return;
    [seenClasses addObject:className];

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray<NSString *> *entries = [NSMutableArray array];

    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        if (!XBPInterestingMethodName(name)) continue;

        const char *types = method_getTypeEncoding(methods[i]);
        NSString *encoding = types ? [NSString stringWithUTF8String:types] : @"-";
        [entries addObject:[NSString stringWithFormat:@"%@ {%@}", name, encoding]];
    }
    free(methods);

    if (entries.count) {
        XBPLog(@"METHODS class=%@ -> %@", className, [entries componentsJoinedByString:@", "]);
    }
}

static void XBPDumpViewTree(UIView *view,
                            UIView *root,
                            NSUInteger depth,
                            NSString *path,
                            NSMutableSet<NSString *> *seenClasses) {
    if (!view || depth > 10) return;

    NSString *className = NSStringFromClass(view.class);
    CGRect frameInRoot = [view convertRect:view.bounds toView:root];

    NSMutableArray<NSString *> *extra = [NSMutableArray array];

    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        [extra addObject:[NSString stringWithFormat:@"text=%@", XBPStringOrDash(label.text)]];
        [extra addObject:[NSString stringWithFormat:@"font=%.2f", label.font.pointSize]];
    }

    if ([view isKindOfClass:UIImageView.class]) {
        UIImageView *imageView = (UIImageView *)view;
        [extra addObject:[NSString stringWithFormat:@"image=%@ mode=%ld tint=%@",
                          XBPStringOrDash(imageView.image),
                          (long)imageView.image.renderingMode,
                          XBPStringOrDash(imageView.tintColor)]];
    }

    if ([view isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)view;
        [extra addObject:[NSString stringWithFormat:@"selected=%d highlighted=%d enabled=%d",
                          control.selected, control.highlighted, control.enabled]];
    }

    NSString *accessibility = [NSString stringWithFormat:@"a11yLabel=%@ a11yId=%@ traits=%llu",
                               XBPStringOrDash(view.accessibilityLabel),
                               XBPStringOrDash(view.accessibilityIdentifier),
                               (unsigned long long)view.accessibilityTraits];

    NSString *layer = [NSString stringWithFormat:
        @"layer(corner=%.2f border=%.2f masks=%d shadow=%.2f)",
        view.layer.cornerRadius,
        view.layer.borderWidth,
        view.layer.masksToBounds,
        view.layer.shadowOpacity];

    XBPLog(@"VIEW %@ class=%@ frame=%@ hidden=%d alpha=%.3f %@ %@ %@",
           path,
           className,
           NSStringFromCGRect(frameInRoot),
           view.hidden,
           view.alpha,
           accessibility,
           layer,
           extra.count ? [extra componentsJoinedByString:@" "] : @"");

    if (XBPInterestingViewClass(className)) {
        XBPDumpInterestingMethodsForClass(view.class, seenClasses);
    }

    NSUInteger index = 0;
    for (UIView *subview in view.subviews ?: @[]) {
        NSString *childPath = [path stringByAppendingFormat:@"/%lu", (unsigned long)index++];
        XBPDumpViewTree(subview, root, depth + 1, childPath, seenClasses);
    }
}

static void XBPDumpExactRuntimeSelectors(void) {
    NSArray<NSString *> *selectorNames = @[
        @"_t1_layoutBadgeViewMaximized",
        @"_t1_layoutBadgeViewMinimized",
        @"syncBadges",
        @"_t1_syncTabBarItems",
        @"badgeValue",
        @"setBadgeValue:",
        @"badgeView",
        @"badgeLabel",
        @"setBadgeView:",
        @"setBadgeLabel:"
    ];

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);

    XBPLog(@"RUNTIME_SCAN_BEGIN classCount=%d", count);

    NSUInteger matches = 0;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *className = NSStringFromClass(cls);
        if (!className.length) continue;

        NSMutableArray<NSString *> *found = [NSMutableArray array];
        for (NSString *selectorName in selectorNames) {
            SEL sel = NSSelectorFromString(selectorName);
            Method method = class_getInstanceMethod(cls, sel);
            if (!method) continue;

            const char *types = method_getTypeEncoding(method);
            NSString *encoding = types ? [NSString stringWithUTF8String:types] : @"-";
            [found addObject:[NSString stringWithFormat:@"%@ {%@}", selectorName, encoding]];
        }

        if (found.count) {
            XBPLog(@"RUNTIME_CLASS %@ -> %@", className, [found componentsJoinedByString:@", "]);
            matches++;
            if (matches >= 160) {
                XBPLog(@"RUNTIME_SCAN_TRUNCATED matches=%lu", (unsigned long)matches);
                break;
            }
        }
    }

    free(classes);
    XBPLog(@"RUNTIME_SCAN_END matches=%lu", (unsigned long)matches);
}

static void XBPCaptureController(id controller, NSString *event) {
    if (!controller) {
        XBPLog(@"CAPTURE event=%@ controller=nil", event);
        return;
    }

    gCaptureCount++;

    XBPLog(@"================ CAPTURE #%lu event=%@ ================",
           (unsigned long)gCaptureCount, event);

    XBPLog(@"CONTROLLER class=%@ syncBadgesEncoding=%@ layoutMaxEncoding=%@ layoutMinEncoding=%@",
           NSStringFromClass([controller class]),
           XBPMethodEncoding([controller class], NSSelectorFromString(@"syncBadges")),
           XBPMethodEncoding([controller class], NSSelectorFromString(@"_t1_layoutBadgeViewMaximized")),
           XBPMethodEncoding([controller class], NSSelectorFromString(@"_t1_layoutBadgeViewMinimized")));

    SEL selectedIndexSEL = NSSelectorFromString(@"selectedIndex");
    if ([controller respondsToSelector:selectedIndexSEL]) {
        NSUInteger selectedIndex = ((NSUInteger(*)(id,SEL))objc_msgSend)(controller, selectedIndexSEL);
        XBPLog(@"selectedIndex=%lu", (unsigned long)selectedIndex);
    }

    SEL tabBarSEL = NSSelectorFromString(@"tabBar");
    if (![controller respondsToSelector:tabBarSEL]) {
        XBPLog(@"controller has no tabBar selector");
        return;
    }

    id object = ((id(*)(id,SEL))objc_msgSend)(controller, tabBarSEL);
    if (![object isKindOfClass:UITabBar.class]) {
        XBPLog(@"tabBar object class=%@", NSStringFromClass([object class]));
        return;
    }

    UITabBar *tabBar = (UITabBar *)object;
    XBPLog(@"TABBAR class=%@ frame=%@ hidden=%d alpha=%.3f items=%lu selected=%@",
           NSStringFromClass(tabBar.class),
           NSStringFromCGRect(tabBar.frame),
           tabBar.hidden,
           tabBar.alpha,
           (unsigned long)tabBar.items.count,
           XBPStringOrDash(tabBar.selectedItem.title));

    NSUInteger itemIndex = 0;
    for (UITabBarItem *item in tabBar.items ?: @[]) {
        XBPLog(@"ITEM[%lu] class=%@ title=%@ a11y=%@ badge=%@ selected=%d image=%@ selectedImage=%@",
               (unsigned long)itemIndex++,
               NSStringFromClass(item.class),
               XBPStringOrDash(item.title),
               XBPStringOrDash(item.accessibilityLabel),
               XBPStringOrDash(item.badgeValue),
               item == tabBar.selectedItem,
               XBPStringOrDash(item.image),
               XBPStringOrDash(item.selectedImage));
    }

    NSMutableSet<NSString *> *seenClasses = [NSMutableSet set];
    XBPDumpViewTree(tabBar, tabBar, 0, @"tabbar", seenClasses);
    XBPLog(@"================ END CAPTURE #%lu ================", (unsigned long)gCaptureCount);
}

static void XBPScheduleCapture(id controller, NSString *event) {
    if (!controller) return;

    __weak id weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        id strongController = weakController;
        if (strongController) XBPCaptureController(strongController, [event stringByAppendingString:@":now"]);
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strongController = weakController;
        if (strongController) XBPCaptureController(strongController, [event stringByAppendingString:@":+100ms"]);
    });
}

static void XBPViewDidLoad(id self, SEL cmd) {
    if (gOrigViewDidLoad) ((void(*)(id,SEL))gOrigViewDidLoad)(self,cmd);
    XBPScheduleCapture(self, @"viewDidLoad");
}

static void XBPViewDidAppear(id self, SEL cmd, BOOL animated) {
    if (gOrigViewDidAppear) ((void(*)(id,SEL,BOOL))gOrigViewDidAppear)(self,cmd,animated);
    XBPScheduleCapture(self, @"viewDidAppear");
}

static void XBPSetTabViews(id self, SEL cmd, id tabViews) {
    if (gOrigSetTabViews) ((void(*)(id,SEL,id))gOrigSetTabViews)(self,cmd,tabViews);
    XBPLog(@"HOOK setTabViews class=%@ argClass=%@ count=%lu",
           NSStringFromClass([self class]),
           NSStringFromClass([tabViews class]),
           [tabViews respondsToSelector:@selector(count)] ? (unsigned long)[tabViews count] : 0UL);
    XBPScheduleCapture(self, @"setTabViews");
}

static void XBPSyncTabBarItems(id self, SEL cmd) {
    if (gOrigSyncTabBarItems) ((void(*)(id,SEL))gOrigSyncTabBarItems)(self,cmd);
    XBPScheduleCapture(self, @"_t1_syncTabBarItems");
}

static void XBPSyncBadges(id self, SEL cmd) {
    XBPLog(@"HOOK syncBadges BEFORE class=%@", NSStringFromClass([self class]));
    XBPCaptureController(self, @"syncBadges:before");

    if (gOrigSyncBadges) ((void(*)(id,SEL))gOrigSyncBadges)(self,cmd);

    XBPLog(@"HOOK syncBadges AFTER class=%@", NSStringFromClass([self class]));
    XBPScheduleCapture(self, @"syncBadges:after");
}

static void XBPTraitCollectionDidChange(id self, SEL cmd, id previous) {
    if (gOrigTraitCollectionDidChange) {
        ((void(*)(id,SEL,id))gOrigTraitCollectionDidChange)(self,cmd,previous);
    }
    XBPScheduleCapture(self, @"traitCollectionDidChange");
}

static void XBPViewDidLayoutSubviews(id self, SEL cmd) {
    if (gOrigViewDidLayoutSubviews) {
        ((void(*)(id,SEL))gOrigViewDidLayoutSubviews)(self,cmd);
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gLastLayoutCapture >= 0.75) {
        gLastLayoutCapture = now;
        XBPScheduleCapture(self, @"viewDidLayoutSubviews");
    }
}

static void XBPSetBadgeValue(UITabBarItem *self, SEL cmd, NSString *value) {
    NSString *old = self.badgeValue;
    XBPLog(@"SET_BADGE item=%p class=%@ title=%@ old=%@ new=%@",
           self,
           NSStringFromClass(self.class),
           XBPStringOrDash(self.title),
           XBPStringOrDash(old),
           XBPStringOrDash(value));

    if (gOrigSetBadgeValue) {
        ((void(*)(id,SEL,id))gOrigSetBadgeValue)(self,cmd,value);
    }

    id controller = XBPFindLiquidGlassController();
    if (controller) XBPScheduleCapture(controller, @"UITabBarItem.setBadgeValue");
}

static void XBPInstallControllerHooks(void) {
    if (gControllerHooksInstalled) return;

    Class cls = NSClassFromString(@"T1LiquidGlassTabBarController");
    if (!cls) {
        XBPLog(@"T1LiquidGlassTabBarController not loaded yet");
        return;
    }

    BOOL any = NO;
    any |= XBPHookMethod(cls,@selector(viewDidLoad),(IMP)XBPViewDidLoad,&gOrigViewDidLoad);
    any |= XBPHookMethod(cls,@selector(viewDidAppear:),(IMP)XBPViewDidAppear,&gOrigViewDidAppear);
    any |= XBPHookMethod(cls,NSSelectorFromString(@"setTabViews:"),(IMP)XBPSetTabViews,&gOrigSetTabViews);
    any |= XBPHookMethod(cls,NSSelectorFromString(@"_t1_syncTabBarItems"),(IMP)XBPSyncTabBarItems,&gOrigSyncTabBarItems);
    any |= XBPHookMethod(cls,NSSelectorFromString(@"syncBadges"),(IMP)XBPSyncBadges,&gOrigSyncBadges);
    any |= XBPHookMethod(cls,@selector(traitCollectionDidChange:),(IMP)XBPTraitCollectionDidChange,&gOrigTraitCollectionDidChange);
    any |= XBPHookMethod(cls,@selector(viewDidLayoutSubviews),(IMP)XBPViewDidLayoutSubviews,&gOrigViewDidLayoutSubviews);

    if (any) {
        gControllerHooksInstalled = YES;
        XBPLog(@"Installed controller hooks on %@.", NSStringFromClass(cls));
    }
}

static void XBPInstallTabBarItemHook(void) {
    if (gTabBarItemHookInstalled) return;

    Class cls = UITabBarItem.class;
    if (XBPHookMethod(cls,@selector(setBadgeValue:),(IMP)XBPSetBadgeValue,&gOrigSetBadgeValue)) {
        gTabBarItemHookInstalled = YES;
        XBPLog(@"Installed UITabBarItem setBadgeValue: hook.");
    }
}

@interface XLiquidGlassBadgeProbeViewController : UITableViewController
@end

@implementation XLiquidGlassBadgeProbeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Badge Probe";
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
    return @"Use com o Liquid Glass ativado. Gere/limpe uma notificação, minimize/maximize a Tab Bar e depois copie o relatório.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"XBPCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }

    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (indexPath.row == 0) {
        cell.textLabel.text = @"Capturar agora";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"Capturas registradas: %lu",
                                     (unsigned long)gCaptureCount];
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"Copiar relatório";
        cell.detailTextLabel.text = XBPLogPath().lastPathComponent;
    } else {
        cell.textLabel.text = @"Limpar relatório";
        cell.detailTextLabel.text = @"Apaga as capturas anteriores.";
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.row == 0) {
        id controller = XBPFindLiquidGlassController();
        XBPCaptureController(controller, @"manual");
        [tableView reloadData];
        return;
    }

    if (indexPath.row == 1) {
        NSString *report = [NSString stringWithContentsOfFile:XBPLogPath()
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil] ?: @"";
        UIPasteboard.generalPasteboard.string = report;

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Badge Probe"
                                                message:[NSString stringWithFormat:
                                                         @"Relatório copiado (%lu caracteres).",
                                                         (unsigned long)report.length]
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                 style:UIAlertActionStyleDefault
                                               handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [[NSFileManager defaultManager] removeItemAtPath:XBPLogPath() error:nil];
    gCaptureCount = 0;
    XBPLog(@"LOG RESET");
    [tableView reloadData];
}

@end

static BOOL XBPSectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"action"] isEqualToString:@"showXLiquidGlassBadgeProbe"]) return YES;
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

    if (![sections isKindOfClass:NSArray.class] || XBPSectionsContainEntry(sections)) return;

    NSMutableArray *updated = [sections mutableCopy];
    NSDictionary *entry = @{
        @"title": @"Badge Probe",
        @"subtitle": @"Diagnóstico da Tab Bar Liquid Glass.",
        @"icon": @"flask",
        @"action": @"showXLiquidGlassBadgeProbe"
    };
    [updated addObject:entry];

    @try {
        [controller setValue:[updated copy] forKey:@"sections"];
    } @catch (__unused NSException *exception) {
    }
}

static void XBPNFBSetupSections(id self, SEL cmd) {
    if (gOrigNFBSetupSections) ((void(*)(id,SEL))gOrigNFBSetupSections)(self,cmd);
    XBPInjectNFBSection(self);
}

static void XBPNFBViewWillAppear(id self, SEL cmd, BOOL animated) {
    if (gOrigNFBViewWillAppear) {
        ((void(*)(id,SEL,BOOL))gOrigNFBViewWillAppear)(self,cmd,animated);
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

    XLiquidGlassBadgeProbeViewController *vc = [XLiquidGlassBadgeProbeViewController new];
    UINavigationController *navigation = ((UIViewController *)self).navigationController;

    if (navigation) {
        [navigation pushViewController:vc animated:YES];
    } else {
        UINavigationController *wrapper =
            [[UINavigationController alloc] initWithRootViewController:vc];
        [(UIViewController *)self presentViewController:wrapper animated:YES completion:nil];
    }
}

static void XBPInstallNFBIntegration(void) {
    if (gNFBHookInstalled) return;

    Class cls = NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;

    class_addMethod(cls,
                    NSSelectorFromString(@"showXLiquidGlassBadgeProbe"),
                    (IMP)XBPShowProbeSettings,
                    "v@:");

    BOOL setup = XBPHookMethod(cls,
                               NSSelectorFromString(@"setupSections"),
                               (IMP)XBPNFBSetupSections,
                               &gOrigNFBSetupSections);

    BOOL appear = XBPHookMethod(cls,
                                @selector(viewWillAppear:),
                                (IMP)XBPNFBViewWillAppear,
                                &gOrigNFBViewWillAppear);

    gNFBHookInstalled = setup || appear;
    if (gNFBHookInstalled) XBPLog(@"Installed optional NeoFreeBird Badge Probe menu.");
}

static void XBPInstallAll(void) {
    XBPInstallTabBarItemHook();
    XBPInstallControllerHooks();
    XBPInstallNFBIntegration();
}

static void XBPScheduleInstall(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        XBPInstallAll();
    });
}

__attribute__((constructor))
static void XLiquidGlassBadgeProbeInit(void) {
    @autoreleasepool {
        XBPLog(@"========== XLiquidGlass Badge Probe 1.0.0 loaded ==========");
        XBPLog(@"logPath=%@", XBPLogPath());
        XBPLog(@"Probe does not change badge values, colors, frames or visibility.");

        XBPInstallAll();

        XBPScheduleInstall(0.05);
        XBPScheduleInstall(0.20);
        XBPScheduleInstall(0.50);
        XBPScheduleInstall(1.00);
        XBPScheduleInstall(2.00);
        XBPScheduleInstall(4.00);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.5*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            XBPDumpExactRuntimeSelectors();
            id controller = XBPFindLiquidGlassController();
            if (controller) XBPCaptureController(controller, @"initial-runtime-scan");
        });
    }
}
