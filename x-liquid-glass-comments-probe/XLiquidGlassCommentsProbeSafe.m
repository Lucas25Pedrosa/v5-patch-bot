#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdatomic.h>

static NSString *const kXCPReportName = @"XLiquidGlassCommentsProbe.txt";
static const NSTimeInterval kXCPPrepDelay = 8.0;
static const NSTimeInterval kXCPCaptureDuration = 15.0;

static IMP gOrigScrollEdgeLayout = NULL;
static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;
static BOOL gScrollHookInstalled = NO;
static BOOL gNFBHooksInstalled = NO;
static _Atomic(bool) gCaptureActive = false;
static BOOL gCaptureArmed = NO;
static NSUInteger gCaptureSerial = 0;
static CFTimeInterval gCaptureStart = 0;
static NSString *gLayoutOwner = @"-";
static NSMutableDictionary<NSNumber *, NSMutableDictionary *> *gObjectStats;
static NSString *gLastReport;

static NSString *XCPReportPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs.length) docs = NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:kXCPReportName];
}

static NSString *XCPStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:NSDate.date];
}

static NSString *XCPImageForIMP(IMP imp) {
    if (!imp) return @"-";
    Dl_info info = {0};
    if (!dladdr((const void *)imp, &info) || !info.dli_fname) return @"-";
    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
    return path.lastPathComponent ?: path ?: @"-";
}

static UIViewController *XCPNearestViewController(UIView *view) {
    UIResponder *r = view;
    for (NSUInteger i = 0; r && i < 48; i++) {
        r = r.nextResponder;
        if ([r isKindOfClass:UIViewController.class]) return (UIViewController *)r;
    }
    return nil;
}

static NSString *XCPContextSnapshot(UIView *target) {
    if (!target) return @"-\n";
    NSMutableString *out = [NSMutableString string];
    UIViewController *nearest = XCPNearestViewController(target);
    UIWindow *window = target.window;

    [out appendFormat:@"target=%@(%p) frame=%@ bounds=%@\n",
     NSStringFromClass(target.class), target,
     NSStringFromCGRect(target.frame), NSStringFromCGRect(target.bounds)];
    [out appendFormat:@"window=%@(%p) root=%@\n",
     window ? NSStringFromClass(window.class) : @"-", window,
     window.rootViewController ? NSStringFromClass(window.rootViewController.class) : @"-"];
    [out appendFormat:@"nearestVC=%@(%p) title=%@\n",
     nearest ? NSStringFromClass(nearest.class) : @"-", nearest,
     nearest.title.length ? nearest.title : @"-"];

    [out appendString:@"superviews:\n"];
    UIView *cursor = target;
    for (NSUInteger depth = 0; cursor && depth < 16; depth++, cursor = cursor.superview) {
        [out appendFormat:@"  %02lu %@(%p) frame=%@\n",
         (unsigned long)depth, NSStringFromClass(cursor.class), cursor,
         NSStringFromCGRect(cursor.frame)];
    }

    [out appendString:@"responders:\n"];
    UIResponder *responder = target;
    for (NSUInteger depth = 0; responder && depth < 20; depth++, responder = responder.nextResponder) {
        [out appendFormat:@"  %02lu %@(%p)%@\n",
         (unsigned long)depth,
         NSStringFromClass(responder.class), responder,
         [responder isKindOfClass:UIViewController.class] ? @" <VC>" : @""];
    }

    [out appendString:@"scrollAncestors:\n"];
    BOOL anyScroll = NO;
    cursor = target;
    while (cursor) {
        if ([cursor isKindOfClass:UIScrollView.class]) {
            anyScroll = YES;
            UIScrollView *sv = (UIScrollView *)cursor;
            [out appendFormat:@"  %@(%p) offset={%.1f,%.1f} size={%.1f,%.1f}\n",
             NSStringFromClass(sv.class), sv,
             sv.contentOffset.x, sv.contentOffset.y,
             sv.contentSize.width, sv.contentSize.height];
        }
        cursor = cursor.superview;
    }
    if (!anyScroll) [out appendString:@"  - none\n"];

    if (nearest) {
        [out appendString:@"controllerAncestors:\n"];
        UIViewController *vc = nearest;
        for (NSUInteger depth = 0; vc && depth < 12; depth++, vc = vc.parentViewController) {
            [out appendFormat:@"  %02lu %@(%p)\n", (unsigned long)depth, NSStringFromClass(vc.class), vc];
        }
        if (nearest.navigationController) {
            [out appendFormat:@"navigation=%@ top=%@\n",
             NSStringFromClass(nearest.navigationController.class),
             nearest.navigationController.topViewController ? NSStringFromClass(nearest.navigationController.topViewController.class) : @"-"];
        }
    }

    return out;
}

static NSMutableDictionary *XCPStatForObject(id object) {
    if (!object) return nil;
    if (!gObjectStats) gObjectStats = [NSMutableDictionary dictionary];
    NSNumber *key = @((uintptr_t)(__bridge void *)object);
    NSMutableDictionary *stat = gObjectStats[key];
    if (!stat) {
        stat = [@{ @"ptr": key, @"layout": @0, @"context": @"" } mutableCopy];
        gObjectStats[key] = stat;
    }
    return stat;
}

static void XCPRecordObject(id object) {
    if (!atomic_load(&gCaptureActive) || ![NSThread isMainThread]) return;
    NSMutableDictionary *stat = XCPStatForObject(object);
    NSUInteger count = [stat[@"layout"] unsignedIntegerValue] + 1;
    stat[@"layout"] = @(count);
    if (count == 1) stat[@"context"] = XCPContextSnapshot(object) ?: @"-\n";
}

static void XCPScrollEdgeLayout(id self, SEL cmd) {
    IMP original = gOrigScrollEdgeLayout;
    if (original) ((void(*)(id,SEL))original)(self, cmd);
    XCPRecordObject(self);
}

static BOOL XCPHook(Class cls, SEL sel, IMP replacement, IMP *originalOut, NSString * __strong *ownerOut) {
    if (!cls || !sel || !replacement) return NO;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    IMP current = class_getMethodImplementation(cls, sel);
    if (!current) return NO;
    if (current == replacement) return YES;
    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;
    if (originalOut && !*originalOut) *originalOut = current;
    if (ownerOut) *ownerOut = XCPImageForIMP(current);
    class_replaceMethod(cls, sel, replacement, types);
    return class_getMethodImplementation(cls, sel) == replacement;
}

static void XCPInstallScrollHook(void) {
    if (gScrollHookInstalled) return;
    Class cls = NSClassFromString(@"XDesignSystem.ScrollEdgeTreatment");
    if (!cls) return;
    gScrollHookInstalled = XCPHook(cls, @selector(layoutSubviews), (IMP)XCPScrollEdgeLayout,
                                   &gOrigScrollEdgeLayout, &gLayoutOwner);
}

static NSArray<NSDictionary *> *XCPSortedStats(void) {
    NSArray *values = gObjectStats.allValues ?: @[];
    return [values sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSUInteger ca = [a[@"layout"] unsignedIntegerValue];
        NSUInteger cb = [b[@"layout"] unsignedIntegerValue];
        if (ca > cb) return NSOrderedAscending;
        if (ca < cb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static NSString *XCPBuildReport(double duration) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSMutableString *r = [NSMutableString string];
    [r appendString:@"============================================================\n"];
    [r appendFormat:@"XLiquidGlass Comments Context Probe 0.2.1 - captura #%lu\n", (unsigned long)gCaptureSerial];
    [r appendFormat:@"Data: %@\n", XCPStamp()];
    [r appendFormat:@"App: %@ build %@ | bundle=%@\n",
     info[@"CFBundleShortVersionString"] ?: @"-", info[@"CFBundleVersion"] ?: @"-",
     NSBundle.mainBundle.bundleIdentifier ?: @"-"];
    [r appendFormat:@"Duracao real: %.3f s\n", duration];
    [r appendString:@"Probe context-only: nao altera blur, glass, setEffect ou setNeedsLayout.\n"];
    [r appendString:@"============================================================\n\n"];
    [r appendFormat:@"[HOOK OWNER]\nlayoutSubviews owner=%@\n\n", gLayoutOwner ?: @"-"];
    [r appendString:@"[SCROLLEDGE OBJECTS]\n"];

    NSArray *sorted = XCPSortedStats();
    if (!sorted.count) [r appendString:@"- nenhum ScrollEdgeTreatment observado durante a captura\n"];
    NSUInteger idx = 0;
    for (NSDictionary *stat in sorted) {
        if (++idx > 8) break;
        NSUInteger count = [stat[@"layout"] unsignedIntegerValue];
        [r appendFormat:@"\n#%lu ptr=0x%llx layout=%lu (%.1f/s)\n",
         (unsigned long)idx, [stat[@"ptr"] unsignedLongLongValue],
         (unsigned long)count, duration > 0 ? (double)count / duration : 0.0];
        [r appendString:([stat[@"context"] length] ? stat[@"context"] : @"-\n")];
    }
    [r appendString:@"\n[FIM DA CAPTURA]\n============================================================\n"];
    return r;
}

static UIViewController *XCPTopController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
            if (!window && !candidate.hidden) window = candidate;
        }
        if (window.isKeyWindow) break;
    }
    UIViewController *vc = window.rootViewController;
    BOOL changed = YES;
    while (vc && changed) {
        changed = NO;
        if (vc.presentedViewController) { vc = vc.presentedViewController; changed = YES; continue; }
        if ([vc isKindOfClass:UINavigationController.class] && ((UINavigationController *)vc).topViewController) {
            vc = ((UINavigationController *)vc).topViewController; changed = YES; continue;
        }
        if ([vc isKindOfClass:UITabBarController.class] && ((UITabBarController *)vc).selectedViewController) {
            vc = ((UITabBarController *)vc).selectedViewController; changed = YES;
        }
    }
    return vc;
}

static void XCPFinishCapture(void) {
    if (!atomic_exchange(&gCaptureActive, false)) return;
    double duration = CACurrentMediaTime() - gCaptureStart;
    gLastReport = XCPBuildReport(duration);
    [gLastReport writeToFile:XCPReportPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    UIViewController *vc = XCPTopController();
    if (vc) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Comments Probe"
            message:@"Captura concluída. Volte em BHTwitter → Comments Probe e copie o relatório."
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    }
}

static void XCPBeginCapture(void) {
    if (!gCaptureArmed) return;
    gCaptureArmed = NO;
    gCaptureSerial++;
    gObjectStats = [NSMutableDictionary dictionary];
    gCaptureStart = CACurrentMediaTime();
    atomic_store(&gCaptureActive, true);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kXCPCaptureDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XCPFinishCapture();
    });
}

@interface XCPSettingsViewController : UITableViewController @end
@implementation XCPSettingsViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Comments Probe"; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 3; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Probe 0.2.1 context-only. Aguarde 8 s, volte aos comentários e role por 15 s.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"XCPCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"XCPCell"];
    if (indexPath.row == 0) { cell.textLabel.text = @"Iniciar diagnóstico"; cell.detailTextLabel.text = @"8 s + 15 s de captura"; }
    else if (indexPath.row == 1) { cell.textLabel.text = @"Copiar relatório"; cell.detailTextLabel.text = @"Copia a última captura"; }
    else { cell.textLabel.text = @"Limpar relatório"; cell.detailTextLabel.text = @"Apaga a captura salva"; }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Comments Probe"
            message:@"Ao tocar em Começar, você terá 8 segundos para voltar aos comentários. Depois role por 15 segundos."
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"Começar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            gCaptureArmed = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kXCPPrepDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ XCPBeginCapture(); });
        }]];
        [self presentViewController:a animated:YES completion:nil];
    } else if (indexPath.row == 1) {
        NSString *text = gLastReport;
        if (!text.length) text = [NSString stringWithContentsOfFile:XCPReportPath() encoding:NSUTF8StringEncoding error:nil];
        if (text.length) UIPasteboard.generalPasteboard.string = text;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Comments Probe" message:text.length ? @"Relatório copiado." : @"Nenhum relatório disponível." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } else {
        gLastReport = nil;
        [[NSFileManager defaultManager] removeItemAtPath:XCPReportPath() error:nil];
    }
}
@end

static BOOL XCPSectionsContainEntry(NSArray *sections) {
    for (id item in sections) if ([item isKindOfClass:NSDictionary.class] && [item[@"action"] isEqualToString:@"showXLiquidGlassCommentsProbe"]) return YES;
    return NO;
}

static void XCPInjectMenuEntry(id controller) {
    NSArray *sections = nil;
    @try { sections = [controller valueForKey:@"sections"]; } @catch (__unused NSException *e) { return; }
    if (![sections isKindOfClass:NSArray.class] || XCPSectionsContainEntry(sections)) return;
    NSMutableArray *updated = [sections mutableCopy];
    [updated addObject:@{ @"title": @"Comments Probe", @"subtitle": @"Mapeia o ScrollEdge dos comentários.", @"icon": @"flask", @"action": @"showXLiquidGlassCommentsProbe" }];
    @try { [controller setValue:[updated copy] forKey:@"sections"]; } @catch (__unused NSException *e) {}
}

static void XCPNFBSetupSections(id self, SEL cmd) {
    if (gOrigNFBSetupSections) ((void(*)(id,SEL))gOrigNFBSetupSections)(self, cmd);
    XCPInjectMenuEntry(self);
}

static void XCPNFBViewWillAppear(id self, SEL cmd, BOOL animated) {
    if (gOrigNFBViewWillAppear) ((void(*)(id,SEL,BOOL))gOrigNFBViewWillAppear)(self, cmd, animated);
    XCPInjectMenuEntry(self);
}

static void XCPShowProbe(id self, SEL cmd) {
    if (![self isKindOfClass:UIViewController.class]) return;
    UIViewController *vc = (UIViewController *)self;
    XCPSettingsViewController *probe = [XCPSettingsViewController new];
    if (vc.navigationController) [vc.navigationController pushViewController:probe animated:YES];
    else [vc presentViewController:[[UINavigationController alloc] initWithRootViewController:probe] animated:YES completion:nil];
}

static void XCPInstallNFBHooks(void) {
    if (gNFBHooksInstalled) return;
    Class cls = NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;
    class_addMethod(cls, NSSelectorFromString(@"showXLiquidGlassCommentsProbe"), (IMP)XCPShowProbe, "v@:");
    BOOL a = XCPHook(cls, NSSelectorFromString(@"setupSections"), (IMP)XCPNFBSetupSections, &gOrigNFBSetupSections, NULL);
    BOOL b = XCPHook(cls, @selector(viewWillAppear:), (IMP)XCPNFBViewWillAppear, &gOrigNFBViewWillAppear, NULL);
    gNFBHooksInstalled = a || b;
}

static void XCPInstallAll(void) {
    XCPInstallScrollHook();
    XCPInstallNFBHooks();
}

__attribute__((constructor))
static void XLiquidGlassCommentsProbeInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlassCommentsProbe] 0.2.1 safe loaded");
        dispatch_async(dispatch_get_main_queue(), ^{
            XCPInstallAll();
            for (NSNumber *delay in @[@0.2, @0.5, @1.0, @2.0, @4.0]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ XCPInstallAll(); });
            }
        });
    }
}
