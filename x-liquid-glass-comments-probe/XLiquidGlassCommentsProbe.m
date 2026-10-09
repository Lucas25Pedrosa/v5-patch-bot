#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <math.h>

static NSString *const kXCPReportName = @"XLiquidGlassCommentsProbe.txt";
static const NSTimeInterval kXCPPrepDelay = 8.0;
static const NSTimeInterval kXCPCaptureDuration = 15.0;

static IMP gOrigScrollEdgeLayout = NULL;
static IMP gOrigScrollEdgeNeedsLayout = NULL;
static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;
static BOOL gScrollHooksInstalled = NO;
static BOOL gNFBHooksInstalled = NO;
static _Atomic(bool) gCaptureActive = false;
static BOOL gCaptureArmed = NO;
static NSUInteger gCaptureSerial = 0;
static CFTimeInterval gCaptureStart = 0;
static NSString *gLayoutOwner = @"-";
static NSString *gNeedsOwner = @"-";
static NSMutableDictionary<NSNumber *, NSMutableDictionary *> *gObjectStats = nil;
static NSString *gLastReport = nil;

static CADisplayLink *gDisplayLink = nil;
static id gDisplayTarget = nil;
static CFTimeInterval gLastFrameTimestamp = 0;
static uint64_t gFrameIntervals = 0;
static uint64_t gSlowIntervals = 0;
static uint64_t gOver33ms = 0;
static uint64_t gEstimatedDrops = 0;
static double gObservedSeconds = 0;
static double gExpectedSeconds = 0;

#pragma mark - Helpers

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

static NSString *XCPRect(CGRect rect) {
    return [NSString stringWithFormat:@"{%.1f,%.1f %.1fx%.1f}",
            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height];
}

static NSString *XCPInsets(UIEdgeInsets insets) {
    return [NSString stringWithFormat:@"{%.1f,%.1f,%.1f,%.1f}",
            insets.top, insets.left, insets.bottom, insets.right];
}

static NSString *XCPStringOrDash(id value) {
    if (!value || value == NSNull.null) return @"-";
    NSString *s = [value isKindOfClass:NSString.class] ? value : [value description];
    return s.length ? s : @"-";
}

static NSString *XCPControllerSummary(UIViewController *vc) {
    if (!vc) return @"-";
    NSMutableArray *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"%@(%p)", NSStringFromClass(vc.class), vc]];
    if (vc.title.length) [parts addObject:[NSString stringWithFormat:@"title=\"%@\"", vc.title]];
    if (vc.parentViewController) [parts addObject:[NSString stringWithFormat:@"parent=%@", NSStringFromClass(vc.parentViewController.class)]];
    if (vc.navigationController) [parts addObject:[NSString stringWithFormat:@"nav=%@ top=%@", NSStringFromClass(vc.navigationController.class), NSStringFromClass(vc.navigationController.topViewController.class)]];
    if (vc.presentingViewController) [parts addObject:[NSString stringWithFormat:@"presenting=%@", NSStringFromClass(vc.presentingViewController.class)]];
    if (vc.presentedViewController) [parts addObject:[NSString stringWithFormat:@"presented=%@", NSStringFromClass(vc.presentedViewController.class)]];
    return [parts componentsJoinedByString:@" | "];
}

static UIViewController *XCPNearestViewController(UIView *view) {
    UIResponder *responder = view;
    for (NSUInteger i = 0; responder && i < 64; i++) {
        responder = responder.nextResponder;
        if ([responder isKindOfClass:UIViewController.class]) return (UIViewController *)responder;
    }

    UIView *cursor = view.superview;
    while (cursor) {
        UIResponder *next = cursor.nextResponder;
        if ([next isKindOfClass:UIViewController.class]) return (UIViewController *)next;
        cursor = cursor.superview;
    }
    return nil;
}

static void XCPAppendControllerHierarchy(NSMutableString *out, UIViewController *root) {
    [out appendString:@"\n  controller hierarchy:\n"];
    UIViewController *vc = root;
    NSMutableSet *seen = [NSMutableSet set];
    for (NSUInteger depth = 0; vc && depth < 16; depth++) {
        NSValue *token = [NSValue valueWithNonretainedObject:vc];
        if ([seen containsObject:token]) break;
        [seen addObject:token];
        [out appendFormat:@"    %02lu %@\n", (unsigned long)depth, XCPControllerSummary(vc)];

        UIViewController *next = nil;
        if (vc.presentedViewController) next = vc.presentedViewController;
        else if ([vc isKindOfClass:UINavigationController.class]) next = ((UINavigationController *)vc).topViewController;
        else if ([vc isKindOfClass:UITabBarController.class]) next = ((UITabBarController *)vc).selectedViewController;
        else if (vc.childViewControllers.count == 1) next = vc.childViewControllers.firstObject;
        vc = next;
    }
}

static NSString *XCPContextSnapshot(UIView *target) {
    if (!target) return @"-";
    NSMutableString *out = [NSMutableString string];
    UIWindow *window = target.window;
    UIViewController *nearest = XCPNearestViewController(target);

    [out appendFormat:@"  target=%@(%p) frame=%@ bounds=%@ hidden=%d alpha=%.3f\n",
     NSStringFromClass(target.class), target, XCPRect(target.frame), XCPRect(target.bounds), target.hidden, target.alpha];
    [out appendFormat:@"  window=%@(%p) root=%@ key=%d\n",
     window ? NSStringFromClass(window.class) : @"-", window,
     window.rootViewController ? NSStringFromClass(window.rootViewController.class) : @"-", window.isKeyWindow];
    [out appendFormat:@"  nearestViewController=%@\n", XCPControllerSummary(nearest)];

    [out appendString:@"\n  superview chain:\n"];
    UIView *cursor = target;
    for (NSUInteger depth = 0; cursor && depth < 18; depth++, cursor = cursor.superview) {
        NSString *aid = cursor.accessibilityIdentifier;
        NSString *label = cursor.accessibilityLabel;
        [out appendFormat:@"    %02lu %@(%p) frame=%@ bounds=%@ hidden=%d alpha=%.2f aid=%@ label=%@\n",
         (unsigned long)depth,
         NSStringFromClass(cursor.class), cursor,
         XCPRect(cursor.frame), XCPRect(cursor.bounds), cursor.hidden, cursor.alpha,
         aid.length ? aid : @"-", label.length ? label : @"-"];
    }

    [out appendString:@"\n  responder chain:\n"];
    UIResponder *responder = target;
    for (NSUInteger depth = 0; responder && depth < 28; depth++) {
        [out appendFormat:@"    %02lu %@(%p)%@\n",
         (unsigned long)depth,
         NSStringFromClass(responder.class), responder,
         [responder isKindOfClass:UIViewController.class] ? @"  <UIViewController>" : @""];
        responder = responder.nextResponder;
    }

    [out appendString:@"\n  scroll ancestors:\n"];
    BOOL foundScroll = NO;
    cursor = target;
    while (cursor) {
        if ([cursor isKindOfClass:UIScrollView.class]) {
            foundScroll = YES;
            UIScrollView *sv = (UIScrollView *)cursor;
            [out appendFormat:@"    %@(%p) offset={%.1f,%.1f} size={%.1f,%.1f} inset=%@ dragging=%d decelerating=%d tracking=%d\n",
             NSStringFromClass(sv.class), sv,
             sv.contentOffset.x, sv.contentOffset.y,
             sv.contentSize.width, sv.contentSize.height,
             XCPInsets(sv.adjustedContentInset), sv.dragging, sv.decelerating, sv.tracking];
        }
        cursor = cursor.superview;
    }
    if (!foundScroll) [out appendString:@"    - none\n"];

    if (target.superview) {
        [out appendString:@"\n  sibling classes:\n    "];
        NSUInteger limit = MIN((NSUInteger)20, target.superview.subviews.count);
        for (NSUInteger i = 0; i < limit; i++) {
            UIView *sibling = target.superview.subviews[i];
            [out appendFormat:@"%@(%p)%@", NSStringFromClass(sibling.class), sibling,
             i + 1 < limit ? @", " : @"\n"];
        }
    }

    if (window.rootViewController) XCPAppendControllerHierarchy(out, window.rootViewController);

    NSMutableArray<NSString *> *markers = [NSMutableArray array];
    NSString *blob = out.lowercaseString;
    for (NSString *needle in @[@"conversation", @"detail", @"thread", @"reply", @"tweet", @"post", @"timeline", @"urt"]) {
        if ([blob containsString:needle]) [markers addObject:needle];
    }
    [out appendFormat:@"\n  context markers=%@\n", markers.count ? [markers componentsJoinedByString:@", "] : @"none"];
    return out;
}

#pragma mark - Frame monitor

@interface XCPDisplayTarget : NSObject
- (void)tick:(CADisplayLink *)link;
@end

@implementation XCPDisplayTarget
- (void)tick:(CADisplayLink *)link {
    if (!atomic_load(&gCaptureActive)) return;
    CFTimeInterval now = link.timestamp;
    if (gLastFrameTimestamp > 0) {
        double observed = now - gLastFrameTimestamp;
        double expected = link.targetTimestamp - link.timestamp;
        if (expected <= 0 || expected > 0.050) expected = 1.0 / (double)MAX(UIScreen.mainScreen.maximumFramesPerSecond, 60);
        gFrameIntervals++;
        gObservedSeconds += observed;
        gExpectedSeconds += expected;
        if (observed > expected * 1.5) gSlowIntervals++;
        if (observed > (1.0 / 30.0) * 1.05) gOver33ms++;
        if (observed > expected * 1.5) {
            long drop = lround(observed / expected) - 1;
            if (drop > 0) gEstimatedDrops += (uint64_t)drop;
        }
    }
    gLastFrameTimestamp = now;
}
@end

static void XCPStartDisplayLink(void) {
    if (!gDisplayTarget) gDisplayTarget = [XCPDisplayTarget new];
    [gDisplayLink invalidate];
    gDisplayLink = [CADisplayLink displayLinkWithTarget:gDisplayTarget selector:@selector(tick:)];
    [gDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

static void XCPStopDisplayLink(void) {
    [gDisplayLink invalidate];
    gDisplayLink = nil;
}

#pragma mark - ScrollEdge hooks

static NSMutableDictionary *XCPStatForObject(id object, BOOL create) {
    if (!object) return nil;
    if (!gObjectStats && create) gObjectStats = [NSMutableDictionary dictionary];
    NSNumber *key = @((uintptr_t)(__bridge void *)object);
    NSMutableDictionary *stat = gObjectStats[key];
    if (!stat && create) {
        stat = [@{
            @"ptr": key,
            @"layout": @0,
            @"needs": @0,
            @"firstContext": @"",
            @"lastContext": @""
        } mutableCopy];
        gObjectStats[key] = stat;
    }
    return stat;
}

static void XCPRecordObject(id object, BOOL isLayout) {
    if (!atomic_load(&gCaptureActive) || ![NSThread isMainThread]) return;
    NSMutableDictionary *stat = XCPStatForObject(object, YES);
    NSString *key = isLayout ? @"layout" : @"needs";
    NSUInteger count = [stat[key] unsignedIntegerValue] + 1;
    stat[key] = @(count);

    NSUInteger total = [stat[@"layout"] unsignedIntegerValue] + [stat[@"needs"] unsignedIntegerValue];
    if (![stat[@"firstContext"] length]) {
        stat[@"firstContext"] = XCPContextSnapshot(object) ?: @"-";
    }
    if (total == 250 || total == 750 || total == 1500 || total == 2500) {
        stat[@"lastContext"] = XCPContextSnapshot(object) ?: @"-";
    }
}

static void XCPScrollEdgeLayout(id self, SEL cmd) {
    XCPRecordObject(self, YES);
    if (gOrigScrollEdgeLayout) ((void(*)(id,SEL))gOrigScrollEdgeLayout)(self, cmd);
}

static void XCPScrollEdgeNeedsLayout(id self, SEL cmd) {
    XCPRecordObject(self, NO);
    if (gOrigScrollEdgeNeedsLayout) ((void(*)(id,SEL))gOrigScrollEdgeNeedsLayout)(self, cmd);
}

static BOOL XCPHook(Class cls, SEL sel, IMP replacement, IMP *originalOut, NSString **ownerOut) {
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

static void XCPInstallScrollHooks(void) {
    if (gScrollHooksInstalled) return;
    Class cls = NSClassFromString(@"XDesignSystem.ScrollEdgeTreatment");
    if (!cls) return;
    BOOL a = XCPHook(cls, @selector(layoutSubviews), (IMP)XCPScrollEdgeLayout, &gOrigScrollEdgeLayout, &gLayoutOwner);
    BOOL b = XCPHook(cls, @selector(setNeedsLayout), (IMP)XCPScrollEdgeNeedsLayout, &gOrigScrollEdgeNeedsLayout, &gNeedsOwner);
    gScrollHooksInstalled = a && b;
}

#pragma mark - Report

static NSArray<NSMutableDictionary *> *XCPSortedStats(void) {
    NSArray *values = gObjectStats.allValues ?: @[];
    return [values sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSUInteger ca = [a[@"layout"] unsignedIntegerValue] + [a[@"needs"] unsignedIntegerValue];
        NSUInteger cb = [b[@"layout"] unsignedIntegerValue] + [b[@"needs"] unsignedIntegerValue];
        if (ca > cb) return NSOrderedAscending;
        if (ca < cb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static NSString *XCPBuildReport(double duration) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = XCPStringOrDash(info[@"CFBundleShortVersionString"]);
    NSString *build = XCPStringOrDash(info[@"CFBundleVersion"]);
    NSMutableString *r = [NSMutableString string];

    [r appendString:@"============================================================\n"];
    [r appendFormat:@"XLiquidGlass Comments Context Probe - captura #%lu\n", (unsigned long)gCaptureSerial];
    [r appendFormat:@"Data: %@\n", XCPStamp()];
    [r appendFormat:@"App: %@ build %@ | bundle=%@\n", version, build, NSBundle.mainBundle.bundleIdentifier ?: @"-"];
    [r appendFormat:@"Duracao real: %.3f s | tela maxFPS=%ld\n", duration, (long)UIScreen.mainScreen.maximumFramesPerSecond];
    [r appendString:@"Probe: somente diagnostico; nao altera layout, blur, glass ou ScrollEdgeTreatment.\n"];
    [r appendString:@"============================================================\n\n"];

    double fps = gObservedSeconds > 0 ? (double)gFrameIntervals / gObservedSeconds : 0;
    double expected = gExpectedSeconds > 0 ? (double)gFrameIntervals / gExpectedSeconds : 0;
    [r appendString:@"[FRAME PERFORMANCE]\n"];
    [r appendFormat:@"intervalos=%llu\n", (unsigned long long)gFrameIntervals];
    [r appendFormat:@"fps observado=%.2f | fps esperado medio=%.2f\n", fps, expected];
    [r appendFormat:@"intervalos >1.5x esperado=%llu | >~33.3ms=%llu | drops estimados=%llu\n\n",
     (unsigned long long)gSlowIntervals, (unsigned long long)gOver33ms, (unsigned long long)gEstimatedDrops];

    [r appendString:@"[HOOK OWNER]\n"];
    [r appendFormat:@"XDesignSystem.ScrollEdgeTreatment layoutSubviews owner=%@\n", gLayoutOwner ?: @"-"];
    [r appendFormat:@"XDesignSystem.ScrollEdgeTreatment setNeedsLayout owner=%@\n\n", gNeedsOwner ?: @"-"];

    NSArray *sorted = XCPSortedStats();
    [r appendString:@"[SCROLLEDGE OBJECTS]\n"];
    if (!sorted.count) [r appendString:@"- nenhum ScrollEdgeTreatment observado durante a captura\n"];
    NSUInteger objectIndex = 0;
    for (NSDictionary *stat in sorted) {
        objectIndex++;
        NSUInteger layout = [stat[@"layout"] unsignedIntegerValue];
        NSUInteger needs = [stat[@"needs"] unsignedIntegerValue];
        [r appendFormat:@"\n#%lu ptr=0x%llx layout=%lu (%.1f/s) setNeedsLayout=%lu (%.1f/s) total=%lu\n",
         (unsigned long)objectIndex,
         [stat[@"ptr"] unsignedLongLongValue],
         (unsigned long)layout, duration > 0 ? layout / duration : 0,
         (unsigned long)needs, duration > 0 ? needs / duration : 0,
         (unsigned long)(layout + needs)];
        [r appendString:@"\n[FIRST CONTEXT]\n"];
        [r appendString:[stat[@"firstContext"] length] ? stat[@"firstContext"] : @"-\n"];
        if ([stat[@"lastContext"] length]) {
            [r appendString:@"\n[LATER CONTEXT]\n"];
            [r appendString:stat[@"lastContext"]];
        }
        if (objectIndex >= 6) break;
    }

    [r appendString:@"\n[FIM DA CAPTURA]\n============================================================\n\n"];
    return r;
}

static void XCPResetStats(void) {
    gObjectStats = [NSMutableDictionary dictionary];
    gLastFrameTimestamp = 0;
    gFrameIntervals = 0;
    gSlowIntervals = 0;
    gOver33ms = 0;
    gEstimatedDrops = 0;
    gObservedSeconds = 0;
    gExpectedSeconds = 0;
}

static UIViewController *XCPTopController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
            if (!window && !candidate.hidden) window = candidate;
        }
    }
    UIViewController *vc = window.rootViewController;
    BOOL advanced = YES;
    while (vc && advanced) {
        advanced = NO;
        if (vc.presentedViewController) { vc = vc.presentedViewController; advanced = YES; continue; }
        if ([vc isKindOfClass:UINavigationController.class] && ((UINavigationController *)vc).topViewController) {
            vc = ((UINavigationController *)vc).topViewController; advanced = YES; continue;
        }
        if ([vc isKindOfClass:UITabBarController.class] && ((UITabBarController *)vc).selectedViewController) {
            vc = ((UITabBarController *)vc).selectedViewController; advanced = YES; continue;
        }
    }
    return vc;
}

static void XCPFinishCapture(void) {
    if (!atomic_exchange(&gCaptureActive, false)) return;
    XCPStopDisplayLink();
    double duration = CACurrentMediaTime() - gCaptureStart;
    gLastReport = XCPBuildReport(duration);
    [gLastReport writeToFile:XCPReportPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];

    UIViewController *vc = XCPTopController();
    if (vc) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Comments Probe"
            message:@"Captura concluída. Volte em BHTwitter → Comments Probe e copie o relatório."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    }
}

static void XCPBeginCapture(void) {
    if (!gCaptureArmed) return;
    gCaptureArmed = NO;
    gCaptureSerial++;
    XCPResetStats();
    gCaptureStart = CACurrentMediaTime();
    atomic_store(&gCaptureActive, true);
    XCPStartDisplayLink();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kXCPCaptureDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XCPFinishCapture();
    });
}

#pragma mark - Menu

@interface XCPSettingsViewController : UITableViewController
@end

@implementation XCPSettingsViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Comments Probe"; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 3; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Focado no ScrollEdgeTreatment da tela de comentários. Aguarde 8 s após iniciar, volte aos comentários e role por 15 s.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"XCPCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"XCPCell"];
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (indexPath.row == 0) { cell.textLabel.text = @"Iniciar diagnóstico"; cell.detailTextLabel.text = @"8 s para voltar aos comentários + 15 s de captura"; }
    else if (indexPath.row == 1) { cell.textLabel.text = @"Copiar relatório"; cell.detailTextLabel.text = @"Copia a última captura"; }
    else { cell.textLabel.text = @"Limpar relatório"; cell.detailTextLabel.text = @"Apaga a captura salva"; }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Comments Probe"
            message:@"Ao tocar em Começar, você terá 8 segundos para voltar aos comentários. Depois role continuamente por 15 segundos."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Começar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            gCaptureArmed = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kXCPPrepDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ XCPBeginCapture(); });
        }]];
        [self presentViewController:alert animated:YES completion:nil];
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
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Comments Probe" message:@"Relatório apagado." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}
@end

static BOOL XCPSectionsContainEntry(NSArray *sections) {
    for (id item in sections) {
        if ([item isKindOfClass:NSDictionary.class] && [item[@"action"] isEqualToString:@"showXLiquidGlassCommentsProbe"]) return YES;
    }
    return NO;
}

static void XCPInjectMenuEntry(id controller) {
    NSArray *sections = nil;
    @try { sections = [controller valueForKey:@"sections"]; } @catch (__unused NSException *e) { return; }
    if (![sections isKindOfClass:NSArray.class] || XCPSectionsContainEntry(sections)) return;
    NSMutableArray *updated = [sections mutableCopy];
    NSDictionary *entry = @{ @"title": @"Comments Probe", @"subtitle": @"Diagnóstico do engasgo nos comentários.", @"icon": @"flask", @"action": @"showXLiquidGlassCommentsProbe" };
    [updated addObject:entry];
    @try { [controller setValue:[updated copy] forKey:@"sections"]; } @catch (__unused NSException *e) {}
}

static void XCPNFBSetupSections(id self, SEL cmd) {
    if (gOrigNFBSetupSections) ((void(*)(id,SEL))gOrigNFBSetupSections)(self, cmd);
    XCPInjectMenuEntry(self);
}

static void XCPNFBViewWillAppear(id self, SEL cmd, BOOL animated) {
    if (gOrigNFBViewWillAppear) ((void(*)(id,SEL,BOOL))gOrigNFBViewWillAppear)(self, cmd, animated);
    XCPInjectMenuEntry(self);
    UITableView *table = nil;
    @try { table = [self valueForKey:@"tableView"]; } @catch (__unused NSException *e) {}
    [table reloadData];
}

static void XCPShowProbe(id self, SEL cmd) {
    if (![self isKindOfClass:UIViewController.class]) return;
    XCPSettingsViewController *probe = [XCPSettingsViewController new];
    UIViewController *vc = (UIViewController *)self;
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
    XCPInstallScrollHooks();
    XCPInstallNFBHooks();
}

static void XCPSchedule(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ XCPInstallAll(); });
}

__attribute__((constructor))
static void XLiquidGlassCommentsProbeInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlassCommentsProbe] 0.2 loaded");
        XCPInstallAll();
        for (NSNumber *delay in @[@0.05, @0.20, @0.50, @1.0, @2.0, @4.0]) XCPSchedule(delay.doubleValue);
    }
}
