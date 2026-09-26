#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kTBPLogFileName = @"XLiquidGlassTimelineBlurProbe.log";
static const NSUInteger kTBPMaxLogBytes = 4 * 1024 * 1024;

static BOOL gTBPCaptureArmed = NO;
static NSUInteger gTBPCaptureSerial = 0;

static IMP gTBPOrigUIApplicationSendEvent = NULL;
static IMP gTBPOrigNFBSetupSections = NULL;
static IMP gTBPOrigNFBViewWillAppear = NULL;

#pragma mark - Log

static NSString *TBPLogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kTBPLogFileName];
}

static NSString *TBPStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:NSDate.date];
}

static NSString *TBPText(id value) {
    if (!value || value == NSNull.null) return @"-";
    NSString *text = [value description] ?: @"-";
    if (text.length > 1200) {
        text = [[text substringToIndex:1200] stringByAppendingString:@"…"];
    }
    return text.length ? text : @"-";
}

static void TBPTrimLog(void) {
    NSString *path = TBPLogPath();
    NSDictionary *attrs =
        [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size <= kTBPMaxLogBytes) return;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length <= kTBPMaxLogBytes) return;

    NSUInteger keep = kTBPMaxLogBytes / 2;
    NSData *tail = [data subdataWithRange:NSMakeRange(data.length - keep, keep)];
    [tail writeToFile:path atomically:YES];
}

static void TBPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void TBPLog(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"[%@] %@\n", TBPStamp(), body ?: @""];
    NSLog(@"[XLiquidGlassTimelineBlurProbe] %@", body ?: @"");

    @synchronized(NSFileManager.defaultManager) {
        NSString *path = TBPLogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [@"" writeToFile:path atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
        TBPTrimLog();
    }
}

#pragma mark - Safe helpers

static id TBPSafeValue(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL TBPHookInstanceMethod(Class cls,
                                  SEL sel,
                                  IMP replacement,
                                  IMP *original) {
    if (!cls || !sel || !replacement) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP current = class_getMethodImplementation(cls, sel);
    if (current == replacement) return YES;
    if (original && !*original) *original = current;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    class_replaceMethod(cls, sel, replacement, types);
    return class_getMethodImplementation(cls, sel) == replacement;
}

static NSString *TBPColor(UIColor *color) {
    if (!color) return @"nil";

    CGFloat r=0,g=0,b=0,a=0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        return [NSString stringWithFormat:@"rgba(%.3f,%.3f,%.3f,%.3f)",
                r,g,b,a];
    }

    CGFloat w=0;
    if ([color getWhite:&w alpha:&a]) {
        return [NSString stringWithFormat:@"white(%.3f,%.3f)",w,a];
    }

    return TBPText(color);
}

static NSString *TBPResponderPath(UIResponder *responder) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    UIResponder *cursor = responder;
    for (NSUInteger i=0; cursor && i<40; i++, cursor=cursor.nextResponder) {
        [parts addObject:NSStringFromClass(cursor.class) ?: @"?"];
    }

    return [parts componentsJoinedByString:@" > "];
}

static BOOL TBPResponderContains(UIResponder *responder, NSString *needle) {
    if (!needle.length) return NO;

    UIResponder *cursor = responder;
    for (NSUInteger i=0; cursor && i<50; i++, cursor=cursor.nextResponder) {
        if ([NSStringFromClass(cursor.class) containsString:needle]) return YES;
    }
    return NO;
}

static BOOL TBPWindowContainsClass(UIWindow *window, NSString *needle) {
    if (!window || !needle.length) return NO;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    for (NSUInteger i=0; i<queue.count && i<4096; i++) {
        UIView *view = queue[i];
        if ([NSStringFromClass(view.class) containsString:needle]) return YES;
        [queue addObjectsFromArray:view.subviews ?: @[]];
    }
    return NO;
}

static NSString *TBPViewPath(UIView *view, UIWindow *window) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    UIView *cursor = view;
    for (NSUInteger i=0; cursor && i<32; i++, cursor=cursor.superview) {
        NSString *name = NSStringFromClass(cursor.class) ?: @"?";
        [parts addObject:name];
        if (cursor == window) break;
    }

    return [parts componentsJoinedByString:@" < "];
}

static BOOL TBPInterestingClassName(NSString *name) {
    if (!name.length) return NO;

    NSArray<NSString *> *needles = @[
        @"VisualEffect",
        @"Backdrop",
        @"Blur",
        @"Glass",
        @"Liquid",
        @"Material",
        @"Navigation",
        @"TabBar",
        @"BarBackground",
        @"Chrome",
        @"Platter",
        @"Pill"
    ];

    for (NSString *needle in needles) {
        if ([name localizedCaseInsensitiveContainsString:needle]) return YES;
    }
    return NO;
}

static NSString *TBPRegionForFrame(CGRect frame,
                                   CGFloat topLimit,
                                   CGFloat bottomStart) {
    BOOL top = CGRectGetMaxY(frame) > 0.0 &&
               CGRectGetMinY(frame) < topLimit;
    BOOL bottom = CGRectGetMaxY(frame) > bottomStart;

    if (top && bottom) return @"BOTH";
    if (top) return @"TOP";
    if (bottom) return @"BOTTOM";
    return nil;
}

#pragma mark - Controller dump

static void TBPDumpControllerTree(UIViewController *vc,
                                  NSUInteger depth,
                                  NSMutableSet<NSValue *> *visited) {
    if (!vc || depth>10) return;

    NSValue *token = [NSValue valueWithNonretainedObject:vc];
    if ([visited containsObject:token]) return;
    [visited addObject:token];

    TBPLog(@"CONTROLLER depth=%lu class=%@ ptr=%p viewClass=%@ presented=%@ children=%lu",
           (unsigned long)depth,
           NSStringFromClass(vc.class),
           vc,
           vc.isViewLoaded ? NSStringFromClass(vc.view.class) : @"notLoaded",
           vc.presentedViewController
                ? NSStringFromClass(vc.presentedViewController.class) : @"nil",
           (unsigned long)vc.childViewControllers.count);

    if ([vc isKindOfClass:UINavigationController.class]) {
        UINavigationController *nav = (UINavigationController *)vc;
        TBPLog(@"NAV_CONTROLLER depth=%lu visible=%@ top=%@ count=%lu",
               (unsigned long)depth,
               nav.visibleViewController
                    ? NSStringFromClass(nav.visibleViewController.class) : @"nil",
               nav.topViewController
                    ? NSStringFromClass(nav.topViewController.class) : @"nil",
               (unsigned long)nav.viewControllers.count);
    }

    if ([vc isKindOfClass:UITabBarController.class]) {
        UITabBarController *tab = (UITabBarController *)vc;
        TBPLog(@"TAB_CONTROLLER depth=%lu selectedIndex=%lu selectedClass=%@",
               (unsigned long)depth,
               (unsigned long)tab.selectedIndex,
               tab.selectedViewController
                    ? NSStringFromClass(tab.selectedViewController.class) : @"nil");
    }

    if (vc.presentedViewController) {
        TBPDumpControllerTree(vc.presentedViewController, depth+1, visited);
    }

    for (UIViewController *child in vc.childViewControllers ?: @[]) {
        TBPDumpControllerTree(child, depth+1, visited);
    }
}

#pragma mark - Runtime class dump

static BOOL TBPInterestingRuntimeName(NSString *name) {
    NSString *lower = name.lowercaseString ?: @"";
    return [lower containsString:@"effect"] ||
           [lower containsString:@"blur"] ||
           [lower containsString:@"glass"] ||
           [lower containsString:@"material"] ||
           [lower containsString:@"background"] ||
           [lower containsString:@"layout"] ||
           [lower containsString:@"tint"] ||
           [lower containsString:@"alpha"];
}

static void TBPDumpRuntimeClass(Class cls) {
    if (!cls) return;

    NSString *className = NSStringFromClass(cls) ?: @"?";
    TBPLog(@"RUNTIME_CLASS_BEGIN class=%@ ptr=%p", className, cls);

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    for (unsigned int i=0; i<ivarCount; i++) {
        NSString *name = [NSString stringWithUTF8String:
            ivar_getName(ivars[i]) ?: ""];
        if (!TBPInterestingRuntimeName(name)) continue;

        TBPLog(@"IVAR class=%@ name=%@ type=%s offset=%td",
               className,
               name,
               ivar_getTypeEncoding(ivars[i]) ?: "-",
               ivar_getOffset(ivars[i]));
    }
    free(ivars);

    unsigned int propertyCount = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &propertyCount);
    for (unsigned int i=0; i<propertyCount; i++) {
        NSString *name = [NSString stringWithUTF8String:
            property_getName(properties[i]) ?: ""];
        if (!TBPInterestingRuntimeName(name)) continue;

        TBPLog(@"PROPERTY class=%@ name=%@ attrs=%s",
               className,
               name,
               property_getAttributes(properties[i]) ?: "-");
    }
    free(properties);

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned int i=0; i<methodCount; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        if (!TBPInterestingRuntimeName(name)) continue;

        TBPLog(@"METHOD class=%@ selector=%@ encoding=%s imp=%p",
               className,
               name,
               method_getTypeEncoding(methods[i]) ?: "-",
               method_getImplementation(methods[i]));
    }
    free(methods);

    TBPLog(@"RUNTIME_CLASS_END class=%@", className);
}

#pragma mark - Timeline snapshot

static void TBPLogHitTest(UIWindow *window, CGPoint point, NSString *label) {
    UIView *hit = [window hitTest:point withEvent:nil];
    TBPLog(@"HITTEST label=%@ point=(%.1f,%.1f) class=%@ ptr=%p responderPath=%@",
           label,
           point.x,
           point.y,
           hit ? NSStringFromClass(hit.class) : @"nil",
           hit,
           hit ? TBPResponderPath(hit) : @"-");
}

static void TBPSnapshotWindow(UIWindow *window, NSString *reason) {
    if (!window) return;

    CGRect bounds = window.bounds;
    CGFloat height = CGRectGetHeight(bounds);
    CGFloat topLimit = MIN(220.0, height * 0.30);
    CGFloat bottomStart = MAX(height - 220.0, height * 0.70);

    TBPLog(@"========== TIMELINE_SNAPSHOT reason=%@ window=%p class=%@ bounds=%@ safeInsets=%@ topLimit=%.1f bottomStart=%.1f ==========",
           reason ?: @"-",
           window,
           NSStringFromClass(window.class),
           NSStringFromCGRect(bounds),
           NSStringFromUIEdgeInsets(window.safeAreaInsets),
           topLimit,
           bottomStart);

    TBPLog(@"WINDOW_ROOT controller=%@ ptr=%p",
           window.rootViewController
                ? NSStringFromClass(window.rootViewController.class) : @"nil",
           window.rootViewController);

    NSMutableSet<NSValue *> *visitedControllers = [NSMutableSet set];
    TBPDumpControllerTree(window.rootViewController,0,visitedControllers);

    TBPLogHitTest(window,
                  CGPointMake(CGRectGetMidX(bounds),
                              MIN(CGRectGetMaxY(bounds)-1.0, 80.0)),
                  @"top-center");
    TBPLogHitTest(window,
                  CGPointMake(CGRectGetMidX(bounds),
                              MAX(1.0, CGRectGetMaxY(bounds)-80.0)),
                  @"bottom-center");

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    NSMutableSet<NSString *> *interestingClasses = [NSMutableSet set];
    NSUInteger logged = 0;

    for (NSUInteger i=0; i<queue.count && i<8192; i++) {
        UIView *view = queue[i];
        [queue addObjectsFromArray:view.subviews ?: @[]];

        if (view.hidden || view.alpha <= 0.001) continue;

        CGRect frame = CGRectZero;
        @try {
            frame = [view convertRect:view.bounds toView:window];
        } @catch (__unused NSException *exception) {
            continue;
        }

        NSString *region = TBPRegionForFrame(frame, topLimit, bottomStart);
        if (!region) continue;

        NSString *className = NSStringFromClass(view.class) ?: @"?";
        BOOL isEffect = [view isKindOfClass:UIVisualEffectView.class];

        id filters = TBPSafeValue(view.layer, @"filters");
        id backgroundFilters = TBPSafeValue(view.layer, @"backgroundFilters");
        id compositingFilter = TBPSafeValue(view.layer, @"compositingFilter");

        BOOL hasLayerEffect =
            ([filters respondsToSelector:@selector(count)] && [filters count] > 0) ||
            ([backgroundFilters respondsToSelector:@selector(count)] &&
             [backgroundFilters count] > 0) ||
            compositingFilter != nil;

        if (!isEffect &&
            !hasLayerEffect &&
            !TBPInterestingClassName(className)) {
            continue;
        }

        NSString *effectClass = @"-";
        NSString *effectText = @"-";
        if (isEffect) {
            UIVisualEffect *effect = ((UIVisualEffectView *)view).effect;
            effectClass = effect ? NSStringFromClass(effect.class) : @"nil";
            effectText = TBPText(effect);
        }

        TBPLog(@"VIEW n=%lu region=%@ class=%@ ptr=%p frameWindow=%@ alpha=%.3f hidden=%d userInteraction=%d bg=%@ tint=%@ cornerRadius=%.2f effectClass=%@ effect=%@ filters=%@ backgroundFilters=%@ compositingFilter=%@ label=%@ identifier=%@ path=%@",
               (unsigned long)logged++,
               region,
               className,
               view,
               NSStringFromCGRect(frame),
               view.alpha,
               view.hidden,
               view.userInteractionEnabled,
               TBPColor(view.backgroundColor),
               TBPColor(view.tintColor),
               view.layer.cornerRadius,
               effectClass,
               effectText,
               TBPText(filters),
               TBPText(backgroundFilters),
               TBPText(compositingFilter),
               TBPText(view.accessibilityLabel),
               TBPText(view.accessibilityIdentifier),
               TBPViewPath(view,window));

        [interestingClasses addObject:className];
    }

    TBPLog(@"SNAPSHOT_VIEW_COUNT reason=%@ count=%lu classes=%@",
           reason ?: @"-",
           (unsigned long)logged,
           [[interestingClasses allObjects]
               sortedArrayUsingSelector:@selector(compare:)]);

    for (NSString *className in
         [[interestingClasses allObjects]
            sortedArrayUsingSelector:@selector(compare:)]) {
        TBPDumpRuntimeClass(NSClassFromString(className));
    }

    TBPLog(@"========== TIMELINE_SNAPSHOT_END reason=%@ ==========",
           reason ?: @"-");
}

static UIWindow *TBPBestWindow(void) {
    UIWindow *best = nil;

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;

        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) {
            if (window.hidden || window.alpha <= 0.01) continue;
            if (!best || window.isKeyWindow) best = window;
            if (window.isKeyWindow) return window;
        }
    }

    return best;
}

static void TBPSnapshotBestWindow(NSString *reason) {
    UIWindow *window = TBPBestWindow();
    if (!window) {
        TBPLog(@"TIMELINE_SNAPSHOT reason=%@ window=nil",reason ?: @"-");
        return;
    }
    TBPSnapshotWindow(window,reason);
}

static void TBPScheduleSnapshots(NSUInteger serial, UIWindow *window) {
    NSArray<NSNumber *> *delays = @[@0.35,@1.00];

    for (NSNumber *number in delays) {
        NSTimeInterval delay = number.doubleValue;
        __weak UIWindow *weakWindow = window;

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay*NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (serial != gTBPCaptureSerial) return;
                UIWindow *strongWindow = weakWindow;
                if (!strongWindow) return;

                TBPSnapshotWindow(
                    strongWindow,
                    [NSString stringWithFormat:
                        @"tap+%.0fms",delay*1000.0]);
            });
    }
}

#pragma mark - Touch capture

static BOOL TBPShouldIgnoreTouch(UITouch *touch) {
    UIView *view = touch.view;
    if (!view) return YES;

    if (TBPResponderContains(view, @"TimelineBlurProbe")) return YES;
    if (TBPResponderContains(view, @"ModernSettingsViewController")) return YES;
    if (TBPResponderContains(view, @"UIAlertController")) return YES;

    UIWindow *window = touch.window;
    if (!window) return YES;

    // Require the main X navigation shell so the report is not captured inside
    // an unrelated modal or setup screen.
    if (!TBPWindowContainsClass(window, @"XNavigation.TabBarView")) return YES;

    return NO;
}

static void TBPUIApplicationSendEvent(id self, SEL cmd, UIEvent *event) {
    UITouch *captureTouch = nil;

    if (gTBPCaptureArmed && event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches ?: [NSSet set]) {
            if (touch.phase != UITouchPhaseEnded) continue;
            if (TBPShouldIgnoreTouch(touch)) continue;
            captureTouch = touch;
            break;
        }
    }

    if (gTBPOrigUIApplicationSendEvent) {
        ((void(*)(id,SEL,UIEvent *))
            gTBPOrigUIApplicationSendEvent)(self,cmd,event);
    }

    if (!captureTouch) return;

    gTBPCaptureArmed = NO;
    NSUInteger serial = ++gTBPCaptureSerial;

    UIWindow *window = captureTouch.window;
    CGPoint point = [captureTouch locationInView:window];

    TBPLog(@"========== TIMELINE_TOUCH_CAPTURE serial=%lu ==========",
           (unsigned long)serial);
    TBPLog(@"TOUCH class=%@ ptr=%p point=(%.1f,%.1f) responderPath=%@",
           captureTouch.view
                ? NSStringFromClass(captureTouch.view.class) : @"nil",
           captureTouch.view,
           point.x,
           point.y,
           captureTouch.view ? TBPResponderPath(captureTouch.view) : @"-");

    TBPSnapshotWindow(window,@"touch");
    TBPScheduleSnapshots(serial,window);
}

static void TBPInstallRuntimeHooks(void) {
    TBPHookInstanceMethod(
        UIApplication.class,
        @selector(sendEvent:),
        (IMP)TBPUIApplicationSendEvent,
        &gTBPOrigUIApplicationSendEvent);

    TBPLog(@"HOOK_STATUS sendEvent=%d",
           gTBPOrigUIApplicationSendEvent != NULL);
}

#pragma mark - NFB UI

@interface XLiquidGlassTimelineBlurProbeViewController : UITableViewController
@end

@implementation XLiquidGlassTimelineBlurProbeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Timeline Blur Probe";
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 5;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return @"Arme a captura, volte à timeline e toque uma vez em qualquer ponto do feed. O probe registra os materiais/blur do topo e da região da Tab Bar sem modificar a interface.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"TBProbeCell";
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
          reuseIdentifier:identifier];
    }

    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    if (indexPath.row == 0) {
        cell.textLabel.text = @"Estado";
        cell.detailTextLabel.text =
            gTBPCaptureArmed ? @"Aguardando toque na timeline" : @"Pronto";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"Capturar próximo toque";
        cell.detailTextLabel.text = @"Limpa o log e arma uma captura.";
    } else if (indexPath.row == 2) {
        cell.textLabel.text = @"Snapshot agora";
        cell.detailTextLabel.text = @"Registra a janela atualmente visível.";
    } else if (indexPath.row == 3) {
        cell.textLabel.text = @"Copiar relatório";
        cell.detailTextLabel.text = kTBPLogFileName;
    } else {
        cell.textLabel.text = @"Limpar relatório";
        cell.detailTextLabel.text = @"Apaga a captura atual.";
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.row == 0) return;

    if (indexPath.row == 1) {
        [[NSFileManager defaultManager]
            removeItemAtPath:TBPLogPath()
                       error:nil];

        gTBPCaptureArmed = YES;
        gTBPCaptureSerial++;

        TBPLog(@"========== LOG RESET FROM NFB ==========");
        TBPLog(@"========== Timeline Blur Probe armed ==========");
        TBPLog(@"INSTRUCTION return-to-timeline-and-tap-once");

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"Timeline Blur Probe"
                                 message:@"Captura armada. Volte à timeline e toque uma vez em qualquer ponto do feed."
                          preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        [tableView reloadData];
        return;
    }

    if (indexPath.row == 2) {
        TBPSnapshotBestWindow(@"manual-NFB");
        return;
    }

    if (indexPath.row == 3) {
        NSString *report =
            [NSString stringWithContentsOfFile:TBPLogPath()
                                      encoding:NSUTF8StringEncoding
                                         error:nil] ?: @"";

        UIPasteboard.generalPasteboard.string = report;

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"Timeline Blur Probe"
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

    gTBPCaptureArmed = NO;
    gTBPCaptureSerial++;

    [[NSFileManager defaultManager]
        removeItemAtPath:TBPLogPath()
                   error:nil];
    TBPLog(@"LOG RESET");
    [tableView reloadData];
}

@end

static BOOL TBPSectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"action"]
                isEqualToString:@"showXLiquidGlassTimelineBlurProbe"]) {
            return YES;
        }
    }
    return NO;
}

static void TBPInjectNFBSection(id controller) {
    NSArray *sections = nil;

    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        return;
    }

    if (![sections isKindOfClass:NSArray.class] ||
        TBPSectionsContainEntry(sections)) {
        return;
    }

    NSMutableArray *updated = [sections mutableCopy];
    [updated addObject:@{
        @"title": @"Timeline Blur Probe",
        @"subtitle": @"Mapeia blur/material do topo e da Tab Bar.",
        @"icon": @"viewfinder",
        @"action": @"showXLiquidGlassTimelineBlurProbe"
    }];

    @try {
        [controller setValue:[updated copy] forKey:@"sections"];
    } @catch (__unused NSException *exception) {
    }
}

static void TBPNFBSetupSections(id self, SEL cmd) {
    if (gTBPOrigNFBSetupSections) {
        ((void(*)(id,SEL))gTBPOrigNFBSetupSections)(self,cmd);
    }
    TBPInjectNFBSection(self);
}

static void TBPNFBViewWillAppear(id self,
                                 SEL cmd,
                                 BOOL animated) {
    if (gTBPOrigNFBViewWillAppear) {
        ((void(*)(id,SEL,BOOL))
            gTBPOrigNFBViewWillAppear)(self,cmd,animated);
    }

    TBPInjectNFBSection(self);

    UITableView *tableView = nil;
    @try {
        tableView = [self valueForKey:@"tableView"];
    } @catch (__unused NSException *exception) {
    }
    [tableView reloadData];
}

static void TBPShowSettings(id self, SEL cmd) {
    (void)cmd;
    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassTimelineBlurProbeViewController *vc =
        [XLiquidGlassTimelineBlurProbeViewController new];

    UINavigationController *nav =
        ((UIViewController *)self).navigationController;

    if (nav) {
        [nav pushViewController:vc animated:YES];
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

static void TBPInstallNFBIntegration(void) {
    Class cls = NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;

    class_addMethod(
        cls,
        NSSelectorFromString(@"showXLiquidGlassTimelineBlurProbe"),
        (IMP)TBPShowSettings,
        "v@:");

    if (!gTBPOrigNFBSetupSections) {
        TBPHookInstanceMethod(
            cls,
            NSSelectorFromString(@"setupSections"),
            (IMP)TBPNFBSetupSections,
            &gTBPOrigNFBSetupSections);
    }

    if (!gTBPOrigNFBViewWillAppear) {
        TBPHookInstanceMethod(
            cls,
            @selector(viewWillAppear:),
            (IMP)TBPNFBViewWillAppear,
            &gTBPOrigNFBViewWillAppear);
    }
}

#pragma mark - Install

static void TBPInstallAll(void) {
    TBPInstallRuntimeHooks();
    TBPInstallNFBIntegration();
}

static void TBPRetry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(delay*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            TBPInstallAll();
        });
}

__attribute__((constructor))
static void XLiquidGlassTimelineBlurProbeInit(void) {
    @autoreleasepool {
        TBPLog(@"========== XLiquidGlass Timeline Blur Probe 0.1.0 loaded ==========");
        TBPLog(@"logPath=%@",TBPLogPath());

        TBPInstallAll();

        TBPRetry(0.05);
        TBPRetry(0.20);
        TBPRetry(0.50);
        TBPRetry(1.00);
        TBPRetry(2.00);
        TBPRetry(4.00);
    }
}
