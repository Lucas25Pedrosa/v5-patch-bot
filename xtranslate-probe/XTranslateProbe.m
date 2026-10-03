#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kXTPLogFileName = @"XTranslateProbe.log";
static const NSUInteger kXTPMaxLogBytes = 4 * 1024 * 1024;
static const NSTimeInterval kXTPCaptureWindow = 30.0;

static IMP gOrigApplicationSendAction = NULL;
static IMP gOrigPresentViewController = NULL;
static IMP gOrigPushViewController = NULL;
static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;

static BOOL gApplicationHooked = NO;
static BOOL gPresentationHooked = NO;
static BOOL gNavigationHooked = NO;
static BOOL gNFBHooked = NO;

static NSUInteger gRuntimeScanCount = 0;
static NSUInteger gSnapshotCount = 0;
static NSUInteger gSessionCount = 0;
static NSTimeInterval gArmedUntil = 0.0;

#pragma mark - Logging

static NSString *XTPLogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kXTPLogFileName];
}

static NSString *XTPStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:NSDate.date];
}

static NSString *XTPText(id value) {
    if (!value || value == NSNull.null) return @"-";
    NSString *text = [value description] ?: @"-";
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    if (text.length > 700) {
        text = [[text substringToIndex:700] stringByAppendingString:@"…"];
    }
    return text.length ? text : @"-";
}

static void XTPTrimLogIfNeeded(void) {
    NSString *path = XTPLogPath();
    NSDictionary *attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size <= kXTPMaxLogBytes) return;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length <= kXTPMaxLogBytes) return;

    NSUInteger keep = kXTPMaxLogBytes / 2;
    NSData *tail = [data subdataWithRange:NSMakeRange(data.length - keep, keep)];
    [tail writeToFile:path atomically:YES];
}

static void XTPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void XTPLog(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"[%@] %@\n", XTPStamp(), body ?: @""];
    NSLog(@"[XTranslateProbe] %@", body ?: @"");

    @synchronized([NSFileManager defaultManager]) {
        NSString *path = XTPLogPath();
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

        XTPTrimLogIfNeeded();
    }
}

#pragma mark - Helpers

static BOOL XTPArmed(void) {
    return NSDate.date.timeIntervalSince1970 < gArmedUntil;
}

static BOOL XTPHookMethod(Class cls, SEL sel, IMP replacement, IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP current = class_getMethodImplementation(cls, sel);
    if (current == replacement) return YES;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    if (originalOut && !*originalOut) *originalOut = current;

    class_replaceMethod(cls, sel, replacement, types);
    return class_getMethodImplementation(cls, sel) == replacement;
}

static UIWindow *XTPKeyWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!fallback && !window.hidden && window.alpha > 0.01) {
                fallback = window;
            }
            if (window.isKeyWindow) return window;
        }
    }
    return fallback;
}

static UIViewController *XTPVisibleViewController(void) {
    UIViewController *vc = XTPKeyWindow().rootViewController;
    if (!vc) return nil;

    BOOL advanced = YES;
    NSUInteger guard = 0;
    while (advanced && guard++ < 32) {
        advanced = NO;

        if (vc.presentedViewController) {
            vc = vc.presentedViewController;
            advanced = YES;
            continue;
        }

        if ([vc isKindOfClass:UINavigationController.class]) {
            UIViewController *next =
                ((UINavigationController *)vc).visibleViewController;
            if (next && next != vc) {
                vc = next;
                advanced = YES;
                continue;
            }
        }

        if ([vc isKindOfClass:UITabBarController.class]) {
            UIViewController *next =
                ((UITabBarController *)vc).selectedViewController;
            if (next && next != vc) {
                vc = next;
                advanced = YES;
                continue;
            }
        }

        if (vc.childViewControllers.count == 1) {
            UIViewController *next = vc.childViewControllers.firstObject;
            if (next && next != vc) {
                vc = next;
                advanced = YES;
                continue;
            }
        }
    }

    return vc;
}

static NSString *XTPControlSummary(id source) {
    if (!source) return @"-";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:NSStringFromClass([source class]) ?: @"?"];

    if ([source isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)source;
        if (control.accessibilityLabel.length)
            [parts addObject:[NSString stringWithFormat:@"a11y=%@", control.accessibilityLabel]];
        if (control.accessibilityIdentifier.length)
            [parts addObject:[NSString stringWithFormat:@"id=%@", control.accessibilityIdentifier]];
    }

    if ([source isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)source;
        NSString *title = [button titleForState:UIControlStateNormal];
        if (title.length)
            [parts addObject:[NSString stringWithFormat:@"title=%@", title]];
    }

    return [parts componentsJoinedByString:@" "];
}

static BOOL XTPCandidateText(NSString *text) {
    NSString *lower = text.lowercaseString ?: @"";
    return [lower containsString:@"translate"] ||
           [lower containsString:@"translation"] ||
           [lower containsString:@"traduz"] ||
           [lower containsString:@"traduç"] ||
           [lower containsString:@"grok"] ||
           [lower containsString:@"language"] ||
           [lower containsString:@"idioma"];
}

#pragma mark - Environment

static void XTPLogEnvironment(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *version =
        [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"-";
    NSString *build =
        [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"-";

    XTPLog(@"ENV app=%@ version=%@ build=%@ bundle=%@",
           bundle.bundleURL.lastPathComponent,
           version,
           build,
           bundle.bundleIdentifier ?: @"-");
    XTPLog(@"ENV os=%@ locale=%@ preferredLanguages=%@",
           UIDevice.currentDevice.systemVersion,
           NSLocale.currentLocale.localeIdentifier,
           NSLocale.preferredLanguages);
    XTPLog(@"ENV NeoFreeBird ModernSettings=%d AppearanceSettings=%d",
           NSClassFromString(@"ModernSettingsViewController") != Nil,
           NSClassFromString(@"AppearanceSettingsViewController") != Nil);
    XTPLog(@"ENV XLiquidGlassSettings=%d",
           NSClassFromString(@"XLiquidGlassSettingsViewController") != Nil);
}

#pragma mark - Runtime scan

static void XTPRuntimeScan(void) {
    gRuntimeScanCount++;
    XTPLog(@"========== RUNTIME_SCAN #%lu BEGIN ==========",
           (unsigned long)gRuntimeScanCount);

    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) {
        XTPLog(@"RUNTIME_SCAN no classes");
        return;
    }

    Class *classes =
        (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
    classCount = objc_getClassList(classes, classCount);

    NSUInteger candidateClasses = 0;
    NSUInteger candidateMethods = 0;

    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        NSString *className = NSStringFromClass(cls) ?: @"";
        NSString *classLower = className.lowercaseString;

        BOOL classCandidate =
            [classLower containsString:@"translate"] ||
            [classLower containsString:@"translation"] ||
            [classLower containsString:@"grok"] ||
            [classLower containsString:@"language"] ||
            [classLower containsString:@"localization"];

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        NSMutableArray<NSString *> *hits = [NSMutableArray array];

        for (unsigned int j = 0; j < methodCount; j++) {
            SEL sel = method_getName(methods[j]);
            NSString *selector = NSStringFromSelector(sel) ?: @"";
            NSString *lower = selector.lowercaseString;

            if ([lower containsString:@"translate"] ||
                [lower containsString:@"translation"] ||
                [lower containsString:@"grok"] ||
                [lower containsString:@"language"] ||
                [lower containsString:@"locale"]) {
                const char *types = method_getTypeEncoding(methods[j]);
                [hits addObject:
                    [NSString stringWithFormat:@"%@ <%s>",
                     selector,
                     types ?: "-"]];
            }
        }

        free(methods);

        if (classCandidate || hits.count) {
            candidateClasses++;
            candidateMethods += hits.count;
            XTPLog(@"CLASS_CANDIDATE %@ image=%@ methodHits=%lu",
                   className,
                   XTPText([NSBundle bundleForClass:cls].bundlePath),
                   (unsigned long)hits.count);

            NSUInteger limit = MIN((NSUInteger)40, hits.count);
            for (NSUInteger k = 0; k < limit; k++) {
                XTPLog(@"METHOD_CANDIDATE %@ :: %@", className, hits[k]);
            }
            if (hits.count > limit) {
                XTPLog(@"METHOD_CANDIDATE %@ truncated=%lu",
                       className,
                       (unsigned long)(hits.count - limit));
            }
        }
    }

    free(classes);

    XTPLog(@"RUNTIME_SCAN summary classes=%d candidateClasses=%lu candidateMethods=%lu",
           classCount,
           (unsigned long)candidateClasses,
           (unsigned long)candidateMethods);
    XTPLog(@"========== RUNTIME_SCAN #%lu END ==========",
           (unsigned long)gRuntimeScanCount);
}

#pragma mark - Visible hierarchy snapshots

static NSString *XTPViewText(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        return ((UILabel *)view).text ?: @"";
    }
    if ([view isKindOfClass:UITextView.class]) {
        return ((UITextView *)view).text ?: @"";
    }
    if ([view isKindOfClass:UITextField.class]) {
        return ((UITextField *)view).text ?: @"";
    }
    if ([view isKindOfClass:UIButton.class]) {
        NSString *title =
            [((UIButton *)view) titleForState:UIControlStateNormal];
        if (title.length) return title;
    }
    return @"";
}

static void XTPSnapshotVisibleHierarchy(NSString *reason) {
    gSnapshotCount++;

    UIWindow *window = XTPKeyWindow();
    UIViewController *visible = XTPVisibleViewController();

    XTPLog(@"========== SNAPSHOT #%lu BEGIN reason=%@ armed=%d ==========",
           (unsigned long)gSnapshotCount,
           reason ?: @"-",
           XTPArmed());
    XTPLog(@"VISIBLE_CONTROLLER class=%@ title=%@ ptr=%p",
           visible ? NSStringFromClass(visible.class) : @"nil",
           XTPText(visible.title),
           visible);

    if (!window) {
        XTPLog(@"SNAPSHOT no key window");
        XTPLog(@"========== SNAPSHOT #%lu END ==========",
               (unsigned long)gSnapshotCount);
        return;
    }

    NSMutableArray<UIView *> *queue =
        [NSMutableArray arrayWithObject:window];
    NSUInteger logged = 0;

    for (NSUInteger i = 0; i < queue.count && i < 3000; i++) {
        UIView *view = queue[i];
        if (!view || view.hidden || view.alpha < 0.01) continue;

        [queue addObjectsFromArray:view.subviews ?: @[]];

        NSString *text = XTPViewText(view);
        NSString *a11y = view.accessibilityLabel ?: @"";
        NSString *identifier = view.accessibilityIdentifier ?: @"";
        NSString *className = NSStringFromClass(view.class) ?: @"";

        BOOL useful =
            text.length ||
            a11y.length ||
            identifier.length ||
            XTPCandidateText(className);

        if (!useful) continue;

        CGRect frame = [view convertRect:view.bounds toView:window];

        XTPLog(@"VIEW class=%@ frame=%@ text=%@ a11y=%@ id=%@ enabled=%d",
               className,
               NSStringFromCGRect(frame),
               XTPText(text),
               XTPText(a11y),
               XTPText(identifier),
               [view isKindOfClass:UIControl.class]
                    ? ((UIControl *)view).enabled
                    : 1);

        if (++logged >= 700) {
            XTPLog(@"SNAPSHOT view log truncated at %lu",
                   (unsigned long)logged);
            break;
        }
    }

    XTPLog(@"SNAPSHOT summary traversed=%lu logged=%lu",
           (unsigned long)queue.count,
           (unsigned long)logged);
    XTPLog(@"========== SNAPSHOT #%lu END ==========",
           (unsigned long)gSnapshotCount);
}

#pragma mark - Passive observation hooks

static BOOL XTPApplicationSendAction(UIApplication *self,
                                     SEL _cmd,
                                     SEL action,
                                     id target,
                                     id sender,
                                     UIEvent *event) {
    if (XTPArmed()) {
        NSString *selector = NSStringFromSelector(action) ?: @"-";
        NSString *targetClass =
            target ? NSStringFromClass([target class]) : @"nil";
        NSString *source = XTPControlSummary(sender);

        XTPLog(@"ACTION selector=%@ target=%@ sender=%@ event=%@ candidate=%d",
               selector,
               targetClass,
               XTPText(source),
               event ? NSStringFromClass(event.class) : @"nil",
               XTPCandidateText(selector) ||
               XTPCandidateText(targetClass) ||
               XTPCandidateText(source));
    }

    if (gOrigApplicationSendAction) {
        return ((BOOL(*)(id,SEL,SEL,id,id,id))gOrigApplicationSendAction)(
            self, _cmd, action, target, sender, event);
    }
    return NO;
}

static void XTPPresentViewController(UIViewController *self,
                                     SEL _cmd,
                                     UIViewController *viewController,
                                     BOOL animated,
                                     void (^completion)(void)) {
    if (XTPArmed()) {
        XTPLog(@"PRESENT from=%@ to=%@ title=%@ animated=%d",
               NSStringFromClass(self.class),
               viewController ? NSStringFromClass(viewController.class) : @"nil",
               XTPText(viewController.title),
               animated);
    }

    if (gOrigPresentViewController) {
        ((void(*)(id,SEL,id,BOOL,id))gOrigPresentViewController)(
            self, _cmd, viewController, animated, completion);
    }
}

static void XTPPushViewController(UINavigationController *self,
                                  SEL _cmd,
                                  UIViewController *viewController,
                                  BOOL animated) {
    if (XTPArmed()) {
        XTPLog(@"PUSH nav=%@ to=%@ title=%@ animated=%d",
               NSStringFromClass(self.class),
               viewController ? NSStringFromClass(viewController.class) : @"nil",
               XTPText(viewController.title),
               animated);
    }

    if (gOrigPushViewController) {
        ((void(*)(id,SEL,id,BOOL))gOrigPushViewController)(
            self, _cmd, viewController, animated);
    }
}

static void XTPInstallObservationHooks(void) {
    if (!gApplicationHooked) {
        gApplicationHooked =
            XTPHookMethod(UIApplication.class,
                          @selector(sendAction:to:from:forEvent:),
                          (IMP)XTPApplicationSendAction,
                          &gOrigApplicationSendAction);
        XTPLog(@"HOOK UIApplication.sendAction installed=%d",
               gApplicationHooked);
    }

    if (!gPresentationHooked) {
        gPresentationHooked =
            XTPHookMethod(UIViewController.class,
                          @selector(presentViewController:animated:completion:),
                          (IMP)XTPPresentViewController,
                          &gOrigPresentViewController);
        XTPLog(@"HOOK UIViewController.present installed=%d",
               gPresentationHooked);
    }

    if (!gNavigationHooked) {
        gNavigationHooked =
            XTPHookMethod(UINavigationController.class,
                          @selector(pushViewController:animated:),
                          (IMP)XTPPushViewController,
                          &gOrigPushViewController);
        XTPLog(@"HOOK UINavigationController.push installed=%d",
               gNavigationHooked);
    }
}

#pragma mark - Capture session

static void XTPArmCapture(void) {
    gSessionCount++;
    gArmedUntil = NSDate.date.timeIntervalSince1970 + kXTPCaptureWindow;

    XTPLog(@"========== CAPTURE_SESSION #%lu BEGIN ==========",
           (unsigned long)gSessionCount);
    XTPLog(@"CAPTURE armedFor=%.0fs instruction=return_to_post_and_tap_translate_once",
           kXTPCaptureWindow);

    XTPSnapshotVisibleHierarchy(@"arm-baseline");

    NSArray<NSNumber *> *delays = @[@1.0, @4.0, @8.0, @15.0, @25.0, @30.2];
    NSUInteger session = gSessionCount;

    for (NSNumber *delayNumber in delays) {
        NSTimeInterval delay = delayNumber.doubleValue;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay * NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{
                if (session != gSessionCount) return;

                if (delay <= kXTPCaptureWindow) {
                    XTPSnapshotVisibleHierarchy(
                        [NSString stringWithFormat:@"session-%lu-%.1fs",
                         (unsigned long)session,
                         delay]);
                } else {
                    XTPLog(@"========== CAPTURE_SESSION #%lu END ==========",
                           (unsigned long)session);
                }
            });
    }
}

#pragma mark - NeoFreeBird integration

@interface XTranslateProbeViewController : UITableViewController
@end

@implementation XTranslateProbeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"XTranslate Probe";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 3 : 2;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? @"Diagnóstico" : @"Relatório";
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return @"A captura de 30 s é somente observacional. Volte ao post, toque uma vez em “Traduzir post” e deixe a resposta aparecer. A probe não traduz, não chama Cloudflare e não bloqueia o Grok.";
    }
    return @"O relatório fica em Documents/XTranslateProbe.log e pode ser copiado integralmente.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"XTPCell";

    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
          reuseIdentifier:identifier];
    }

    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.textLabel.text = @"Mapear runtime";
        cell.detailTextLabel.text =
            [NSString stringWithFormat:@"Varreduras: %lu",
             (unsigned long)gRuntimeScanCount];
    } else if (indexPath.section == 0 && indexPath.row == 1) {
        cell.textLabel.text = @"Capturar tela atual";
        cell.detailTextLabel.text =
            [NSString stringWithFormat:@"Snapshots: %lu",
             (unsigned long)gSnapshotCount];
    } else if (indexPath.section == 0 && indexPath.row == 2) {
        cell.textLabel.text = @"Armar captura por 30 s";
        cell.detailTextLabel.text =
            XTPArmed()
                ? @"ARMADA — volte ao post e toque em Traduzir post."
                : @"Observa ações e a interface sem alterar o X.";
    } else if (indexPath.section == 1 && indexPath.row == 0) {
        cell.textLabel.text = @"Copiar relatório";
        cell.detailTextLabel.text = kXTPLogFileName;
    } else {
        cell.textLabel.text = @"Limpar relatório";
        cell.detailTextLabel.text = @"Remove o relatório anterior.";
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0 && indexPath.row == 0) {
        XTPRuntimeScan();
        [tableView reloadData];
        return;
    }

    if (indexPath.section == 0 && indexPath.row == 1) {
        XTPSnapshotVisibleHierarchy(@"manual");
        [tableView reloadData];
        return;
    }

    if (indexPath.section == 0 && indexPath.row == 2) {
        XTPArmCapture();
        [tableView reloadData];

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"XTranslate Probe"
                                 message:@"Captura armada por 30 segundos. Volte ao post e toque uma vez em “Traduzir post”."
                          preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:nil]];

        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    if (indexPath.section == 1 && indexPath.row == 0) {
        NSString *report =
            [NSString stringWithContentsOfFile:XTPLogPath()
                                      encoding:NSUTF8StringEncoding
                                         error:nil] ?: @"";

        UIPasteboard.generalPasteboard.string = report;

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"XTranslate Probe"
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

    [[NSFileManager defaultManager] removeItemAtPath:XTPLogPath() error:nil];
    gRuntimeScanCount = 0;
    gSnapshotCount = 0;
    gSessionCount = 0;
    gArmedUntil = 0.0;
    XTPLog(@"LOG RESET");
    [tableView reloadData];
}

@end

static BOOL XTPSectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"action"] isEqualToString:@"showXTranslateProbe"]) {
            return YES;
        }
    }
    return NO;
}

static void XTPInjectNFBSection(id controller) {
    NSArray *sections = nil;

    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        return;
    }

    if (![sections isKindOfClass:NSArray.class] ||
        XTPSectionsContainEntry(sections)) {
        return;
    }

    NSMutableArray *updated = [sections mutableCopy];
    [updated addObject:@{
        @"title": @"XTranslate Probe",
        @"subtitle": @"Mapear o fluxo de Traduzir post/Grok.",
        @"icon": @"flask",
        @"action": @"showXTranslateProbe"
    }];

    @try {
        [controller setValue:[updated copy] forKey:@"sections"];
    } @catch (__unused NSException *exception) {
    }
}

static void XTPNFBSetupSections(id self, SEL _cmd) {
    if (gOrigNFBSetupSections) {
        ((void(*)(id,SEL))gOrigNFBSetupSections)(self, _cmd);
    }
    XTPInjectNFBSection(self);
}

static void XTPNFBViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigNFBViewWillAppear) {
        ((void(*)(id,SEL,BOOL))gOrigNFBViewWillAppear)(
            self, _cmd, animated);
    }

    XTPInjectNFBSection(self);

    UITableView *tableView = nil;
    @try {
        tableView = [self valueForKey:@"tableView"];
    } @catch (__unused NSException *exception) {
    }
    [tableView reloadData];
}

static void XTPShowProbe(id self, SEL _cmd) {
    (void)_cmd;
    if (![self isKindOfClass:UIViewController.class]) return;

    XTranslateProbeViewController *vc = [XTranslateProbeViewController new];
    UINavigationController *navigation =
        ((UIViewController *)self).navigationController;

    if (navigation) {
        [navigation pushViewController:vc animated:YES];
    } else {
        UINavigationController *wrapper =
            [[UINavigationController alloc] initWithRootViewController:vc];
        [(UIViewController *)self
            presentViewController:wrapper
                         animated:YES
                       completion:nil];
    }
}

static void XTPInstallNFBIntegration(void) {
    if (gNFBHooked) return;

    Class cls = NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;

    class_addMethod(cls,
                    NSSelectorFromString(@"showXTranslateProbe"),
                    (IMP)XTPShowProbe,
                    "v@:");

    BOOL setup =
        XTPHookMethod(cls,
                      NSSelectorFromString(@"setupSections"),
                      (IMP)XTPNFBSetupSections,
                      &gOrigNFBSetupSections);

    BOOL appear =
        XTPHookMethod(cls,
                      @selector(viewWillAppear:),
                      (IMP)XTPNFBViewWillAppear,
                      &gOrigNFBViewWillAppear);

    gNFBHooked = setup || appear;
    XTPLog(@"HOOK NeoFreeBird installed=%d setup=%d appear=%d",
           gNFBHooked,
           setup,
           appear);
}

#pragma mark - Install

static void XTPInstallAll(void) {
    XTPInstallObservationHooks();
    XTPInstallNFBIntegration();
}

static void XTPScheduleInstall(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            XTPInstallAll();
        });
}

__attribute__((constructor))
static void XTranslateProbeInit(void) {
    @autoreleasepool {
        XTPLog(@"========== XTranslate Probe 0.1.0 loaded ==========");
        XTPLog(@"MODE read_only=1 network=0 translation=0 grok_override=0");
        XTPLog(@"logPath=%@", XTPLogPath());
        XTPLogEnvironment();

        XTPInstallAll();

        XTPScheduleInstall(0.05);
        XTPScheduleInstall(0.20);
        XTPScheduleInstall(0.50);
        XTPScheduleInstall(1.00);
        XTPScheduleInstall(2.00);
        XTPScheduleInstall(4.00);

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(2.5 * NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{
                XTPInstallAll();
                XTPLogEnvironment();
            });
    }
}
