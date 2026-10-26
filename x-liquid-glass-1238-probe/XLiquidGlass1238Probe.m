#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdint.h>
#import <stdarg.h>

static NSString *const kProbeVersion = @"1.0";
static NSString *const kTargetVersion = @"12.38";
static NSString *const kLogName = @"XLiquidGlass1238Probe.log";
static const NSUInteger kMaxLogBytes = 6 * 1024 * 1024;

static IMP gOrigInstallGateForAccount = NULL;
static IMP gOrigIsRedesignEnabled = NULL;
static IMP gOrigIsPushChromeSnapEnabled = NULL;
static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;
static BOOL gNFBHooked = NO;
static NSUInteger gRedesignCalls = 0;
static NSUInteger gPushChromeCalls = 0;
static BOOL gLastRedesign = NO;
static BOOL gHasLastRedesign = NO;
static BOOL gLastPushChrome = NO;
static BOOL gHasLastPushChrome = NO;

static void XLGInstallHooks(void);
static void XLGCapture(NSString *reason);

#pragma mark - Log

static NSString *XLGLogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kLogName];
}

static NSString *XLGStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    return [formatter stringFromDate:NSDate.date];
}

static void XLGTrimLog(void) {
    NSString *path = XLGLogPath();
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size <= kMaxLogBytes) return;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length <= kMaxLogBytes) return;
    NSUInteger keep = kMaxLogBytes / 2;
    [[data subdataWithRange:NSMakeRange(data.length - keep, keep)] writeToFile:path atomically:YES];
}

static void XLGLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void XLGLog(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", XLGStamp(), body ?: @""];
    NSLog(@"[XLiquidGlass1238Probe] %@", body ?: @"");

    @synchronized(NSFileManager.defaultManager) {
        NSString *path = XLGLogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
        XLGTrimLog();
    }
}

#pragma mark - Runtime helpers

static Class XLGFindClassContaining(NSString *needle) {
    if (!needle.length) return Nil;
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return Nil;
    count = objc_getClassList(classes, count);
    Class result = Nil;
    for (int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if ([name containsString:needle]) { result = classes[i]; break; }
    }
    free(classes);
    return result;
}

static Class XLGFeaturesClass(void) {
    Class cls = NSClassFromString(@"T1TwitterSwift.LiquidGlassRedesignFeatures");
    if (!cls) cls = NSClassFromString(@"_TtC14T1TwitterSwift27LiquidGlassRedesignFeatures");
    if (!cls) cls = XLGFindClassContaining(@"LiquidGlassRedesignFeatures");
    return cls;
}

static NSString *XLGImageForAddress(const void *address, uintptr_t *offsetOut) {
    if (offsetOut) *offsetOut = 0;
    if (!address) return @"-";
    Dl_info info = {0};
    if (!dladdr(address, &info) || !info.dli_fname) return @"-";
    if (offsetOut && info.dli_fbase) *offsetOut = (uintptr_t)address - (uintptr_t)info.dli_fbase;
    NSString *path = [NSString stringWithUTF8String:info.dli_fname] ?: @"-";
    return path.lastPathComponent ?: path;
}

static void XLGLogCaller(NSString *event, void *caller) {
    uintptr_t offset = 0;
    NSString *image = XLGImageForAddress(caller, &offset);
    XLGLog(@"CALLER event=%@ address=%p image=%@ offset=0x%llx",
           event ?: @"-", caller, image, (unsigned long long)offset);
}

static BOOL XLGHookMethod(Class cls, SEL sel, BOOL classMethod, IMP replacement, IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;
    Method method = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    Class target = classMethod ? object_getClass(cls) : cls;
    IMP current = class_getMethodImplementation(target, sel);
    if (current == replacement) return YES;
    if (originalOut && !*originalOut) *originalOut = current;
    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;
    class_replaceMethod(target, sel, replacement, types);
    BOOL ok = class_getMethodImplementation(target, sel) == replacement;
    XLGLog(@"HOOK_INSTALL class=%@ selector=%@ classMethod=%@ result=%@ original=%p replacement=%p types=%s",
           NSStringFromClass(cls), NSStringFromSelector(sel), classMethod ? @"YES" : @"NO",
           ok ? @"YES" : @"NO", current, replacement, types);
    return ok;
}

static void XLGDumpObjectIvars(id object, NSString *reason) {
    if (!object) return;
    Class cls = object_getClass(object);
    NSUInteger instanceSize = class_getInstanceSize(cls);
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    XLGLog(@"OBJECT_STATE_BEGIN reason=%@ class=%@ object=%p instanceSize=%lu",
           reason ?: @"-", NSStringFromClass(cls), object, (unsigned long)instanceSize);

    for (Class current = cls; current && current != NSObject.class; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned int i = 0; i < count; i++) {
            Ivar ivar = ivars[i];
            const char *name = ivar_getName(ivar);
            const char *type = ivar_getTypeEncoding(ivar);
            ptrdiff_t offset = ivar_getOffset(ivar);
            NSString *value = @"<unread>";
            if (offset >= 0 && (NSUInteger)offset < instanceSize) {
                NSUInteger remaining = instanceSize - (NSUInteger)offset;
                char code = (type && type[0]) ? type[0] : '?';
                if ((code == 'B' || code == 'c' || code == 'C') && remaining >= 1) {
                    uint8_t v = 0; memcpy(&v, base + offset, 1);
                    value = [NSString stringWithFormat:@"%u", (unsigned)v];
                } else if ((code == 'i' || code == 'I') && remaining >= 4) {
                    uint32_t v = 0; memcpy(&v, base + offset, 4);
                    value = [NSString stringWithFormat:@"%u", v];
                } else if ((code == 'q' || code == 'Q') && remaining >= 8) {
                    uint64_t v = 0; memcpy(&v, base + offset, 8);
                    value = [NSString stringWithFormat:@"%llu", (unsigned long long)v];
                } else {
                    uint64_t raw = 0;
                    NSUInteger n = MIN((NSUInteger)8, remaining);
                    memcpy(&raw, base + offset, n);
                    value = [NSString stringWithFormat:@"raw0x%016llx", (unsigned long long)raw];
                }
            }
            XLGLog(@"OBJECT_IVAR owner=%@ name=%s type=%s offset=%td value=%@",
                   NSStringFromClass(current), name ?: "?", type ?: "?", offset, value);
        }
        free(ivars);
    }
    XLGLog(@"OBJECT_STATE_END reason=%@", reason ?: @"-");
}

#pragma mark - Passive hooks

static BOOL XLGIsRedesignEnabled(id self, SEL _cmd) {
    BOOL value = gOrigIsRedesignEnabled ? ((BOOL (*)(id,SEL))gOrigIsRedesignEnabled)(self, _cmd) : NO;
    gRedesignCalls++;
    BOOL changed = !gHasLastRedesign || value != gLastRedesign;
    if (gRedesignCalls <= 20 || changed) {
        XLGLog(@"GETTER selector=isRedesignEnabled call=%lu object=%p class=%@ result=%@ changed=%@",
               (unsigned long)gRedesignCalls, self, NSStringFromClass([self class]),
               value ? @"YES" : @"NO", changed ? @"YES" : @"NO");
        void *caller = __builtin_extract_return_addr(__builtin_return_address(0));
        XLGLogCaller(@"isRedesignEnabled", caller);
        if (gRedesignCalls <= 5 || changed) XLGDumpObjectIvars(self, @"isRedesignEnabled");
    }
    gLastRedesign = value;
    gHasLastRedesign = YES;
    return value;
}

static BOOL XLGIsPushChromeSnapEnabled(id self, SEL _cmd) {
    BOOL value = gOrigIsPushChromeSnapEnabled ? ((BOOL (*)(id,SEL))gOrigIsPushChromeSnapEnabled)(self, _cmd) : NO;
    gPushChromeCalls++;
    BOOL changed = !gHasLastPushChrome || value != gLastPushChrome;
    if (gPushChromeCalls <= 20 || changed) {
        XLGLog(@"GETTER selector=isPushChromeSnapEnabled call=%lu object=%p class=%@ result=%@ changed=%@",
               (unsigned long)gPushChromeCalls, self, NSStringFromClass([self class]),
               value ? @"YES" : @"NO", changed ? @"YES" : @"NO");
        void *caller = __builtin_extract_return_addr(__builtin_return_address(0));
        XLGLogCaller(@"isPushChromeSnapEnabled", caller);
        if (gPushChromeCalls <= 5 || changed) XLGDumpObjectIvars(self, @"isPushChromeSnapEnabled");
    }
    gLastPushChrome = value;
    gHasLastPushChrome = YES;
    return value;
}

static void XLGInstallGateForAccount(id self, SEL _cmd, id account) {
    XLGLog(@"GATE_CALL_BEGIN selector=installGateForAccount: account=%p class=%@", account, account ? NSStringFromClass([account class]) : @"nil");
    if (gOrigInstallGateForAccount) ((void (*)(id,SEL,id))gOrigInstallGateForAccount)(self, _cmd, account);
    XLGLog(@"GATE_CALL_END selector=installGateForAccount:");
    dispatch_async(dispatch_get_main_queue(), ^{ XLGCapture(@"after-installGateForAccount"); });
}

#pragma mark - Capture

static void XLGLogDefaults(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray<NSString *> *keys = @[
        @"XLiquidGlassEnabled",
        @"T1LiquidGlassRedesignPersistedGate",
        @"ios_liquid_glass_push_chrome_snap_enabled",
        @"x_liquid_glass_redesign_enabled"
    ];
    XLGLog(@"DEFAULTS_BEGIN");
    for (NSString *key in keys) XLGLog(@"DEFAULT key=%@ value=%@", key, [defaults objectForKey:key] ?: @"<nil>");
    XLGLog(@"DEFAULTS_END");
}

static void XLGRuntimeSummary(void) {
    Class installer = NSClassFromString(@"T1LiquidGlassGateInstaller");
    Class features = XLGFeaturesClass();
    BOOL newGate = installer && class_getClassMethod(installer, NSSelectorFromString(@"installGateForAccount:"));
    BOOL legacyGate = installer && class_getClassMethod(installer, NSSelectorFromString(@"installGateWithRedesignEnabled:"));
    BOOL redesign = features && class_getInstanceMethod(features, NSSelectorFromString(@"isRedesignEnabled"));
    BOOL pushChrome = features && class_getInstanceMethod(features, NSSelectorFromString(@"isPushChromeSnapEnabled"));
    XLGLog(@"RUNTIME installer=%@ features=%@ installGateForAccount=%@ legacyGate=%@ isRedesignEnabled=%@ isPushChromeSnapEnabled=%@",
           installer ? NSStringFromClass(installer) : @"<nil>", features ? NSStringFromClass(features) : @"<nil>",
           newGate ? @"YES" : @"NO", legacyGate ? @"YES" : @"NO", redesign ? @"YES" : @"NO", pushChrome ? @"YES" : @"NO");
}

static void XLGUISnapshot(NSString *reason) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ XLGUISnapshot(reason); }); return; }
    NSArray<NSString *> *needles = @[@"TabBarView", @"TabBarItemView", @"T1TabView", @"Glass", @"LiquidLens"];
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (NSString *needle in needles) counts[needle] = @0;
    NSUInteger visited = 0;
    XLGLog(@"UI_SNAPSHOT_BEGIN reason=%@", reason ?: @"-");
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) {
            NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
            for (NSUInteger i = 0; i < queue.count && visited < 12000; i++, visited++) {
                UIView *view = queue[i];
                NSString *name = NSStringFromClass(view.class);
                for (NSString *needle in needles) if ([name containsString:needle]) counts[needle] = @([counts[needle] unsignedIntegerValue] + 1);
                [queue addObjectsFromArray:view.subviews ?: @[]];
            }
        }
    }
    for (NSString *needle in needles) XLGLog(@"UI_COUNT contains=%@ count=%@", needle, counts[needle]);
    XLGLog(@"UI_SNAPSHOT_END reason=%@ visited=%lu", reason ?: @"-", (unsigned long)visited);
}

static void XLGCapture(NSString *reason) {
    XLGLog(@"CAPTURE_BEGIN reason=%@", reason ?: @"-");
    XLGLogDefaults();
    XLGRuntimeSummary();
    XLGUISnapshot(reason);
    XLGLog(@"SUMMARY redesignCalls=%lu pushChromeCalls=%lu lastRedesign=%@ lastPushChrome=%@",
           (unsigned long)gRedesignCalls, (unsigned long)gPushChromeCalls,
           gHasLastRedesign ? (gLastRedesign ? @"YES" : @"NO") : @"<never-called>",
           gHasLastPushChrome ? (gLastPushChrome ? @"YES" : @"NO") : @"<never-called>");
    XLGLog(@"CAPTURE_END reason=%@", reason ?: @"-");
}

#pragma mark - NFB menu

@interface XLiquidGlass1238ProbeViewController : UITableViewController
@end

@implementation XLiquidGlass1238ProbeViewController

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Liquid Glass 12.38 Probe";
    self.tableView.backgroundColor = UIColor.systemBackgroundColor;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? 2 : 3; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return section == 0 ? @"Estado" : @"Diagnóstico"; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? @"Probe passivo: não força nenhum gate do X." : @"Log: Documents/XLiquidGlass1238Probe.log";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"XLG1238ProbeCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    if (indexPath.section == 0) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Alvo";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"X %@ • Probe %@ • PASSIVE", kTargetVersion, kProbeVersion];
        } else {
            NSString *redesign = gHasLastRedesign ? (gLastRedesign ? @"YES" : @"NO") : @"—";
            NSString *pushChrome = gHasLastPushChrome ? (gLastPushChrome ? @"YES" : @"NO") : @"—";
            cell.textLabel.text = @"Últimos gates";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"Redesign: %@ • PushChrome: %@", redesign, pushChrome];
        }
    } else if (indexPath.row == 0) {
        cell.textLabel.text = @"Capturar agora";
        cell.detailTextLabel.text = @"Registra gates, runtime e snapshot da UI.";
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"Compartilhar log";
        cell.detailTextLabel.text = @"Exporta XLiquidGlass1238Probe.log.";
    } else {
        cell.textLabel.text = @"Limpar log";
        cell.detailTextLabel.text = @"Apaga as capturas anteriores.";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 1) return;

    if (indexPath.row == 0) {
        XLGInstallHooks();
        XLGCapture(@"nfb-manual");
        [self.tableView reloadData];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Probe" message:@"Captura registrada no log." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else if (indexPath.row == 1) {
        NSString *path = XLGLogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) return;
        UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
        if (activity.popoverPresentationController) {
            activity.popoverPresentationController.sourceView = self.view;
            activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        }
        [self presentViewController:activity animated:YES completion:nil];
    } else {
        NSString *path = XLGLogPath();
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        XLGLog(@"NEW_SESSION version=%@ target=X_%@ mode=PASSIVE source=NFB_AFTER_CLEAR", kProbeVersion, kTargetVersion);
    }
}
@end

static BOOL XLGSectionsContainEntry(NSArray *sections) {
    for (id entry in sections) if ([entry isKindOfClass:NSDictionary.class] && [entry[@"action"] isEqualToString:@"showXLiquidGlass1238Probe"]) return YES;
    return NO;
}

static void XLGInjectNFBEntry(id controller) {
    NSArray *sections = nil;
    @try { sections = [controller valueForKey:@"sections"]; } @catch (__unused NSException *e) { return; }
    if (![sections isKindOfClass:NSArray.class] || XLGSectionsContainEntry(sections)) return;
    NSMutableArray *updated = [sections mutableCopy];
    NSDictionary *entry = @{
        @"title": @"Liquid Glass 12.38 Probe",
        @"subtitle": @"Diagnóstico passivo dos gates e da interface.",
        @"icon": @"flask",
        @"action": @"showXLiquidGlass1238Probe"
    };
    [updated insertObject:entry atIndex:MIN((NSUInteger)2, updated.count)];
    @try { [controller setValue:[updated copy] forKey:@"sections"]; } @catch (__unused NSException *e) {}
}

static void XLGNFBSetupSections(id self, SEL _cmd) {
    if (gOrigNFBSetupSections) ((void (*)(id,SEL))gOrigNFBSetupSections)(self, _cmd);
    XLGInjectNFBEntry(self);
}

static void XLGNFBViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigNFBViewWillAppear) ((void (*)(id,SEL,BOOL))gOrigNFBViewWillAppear)(self, _cmd, animated);
    XLGInjectNFBEntry(self);
    UITableView *tableView = nil;
    @try { tableView = [self valueForKey:@"tableView"]; } @catch (__unused NSException *e) {}
    [tableView reloadData];
}

static void XLGShowProbe(id self, SEL _cmd) {
    (void)_cmd;
    if (![self isKindOfClass:UIViewController.class]) return;
    XLiquidGlass1238ProbeViewController *probe = [XLiquidGlass1238ProbeViewController new];
    UINavigationController *nav = ((UIViewController *)self).navigationController;
    if (nav) [nav pushViewController:probe animated:YES];
    else {
        UINavigationController *wrapper = [[UINavigationController alloc] initWithRootViewController:probe];
        [(UIViewController *)self presentViewController:wrapper animated:YES completion:nil];
    }
}

static void XLGInstallNFB(void) {
    if (gNFBHooked) return;
    Class cls = NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;
    class_addMethod(cls, NSSelectorFromString(@"showXLiquidGlass1238Probe"), (IMP)XLGShowProbe, "v@:");
    BOOL a = XLGHookMethod(cls, NSSelectorFromString(@"setupSections"), NO, (IMP)XLGNFBSetupSections, &gOrigNFBSetupSections);
    BOOL b = XLGHookMethod(cls, @selector(viewWillAppear:), NO, (IMP)XLGNFBViewWillAppear, &gOrigNFBViewWillAppear);
    gNFBHooked = a || b;
    if (gNFBHooked) XLGLog(@"NFB_MENU installed=YES class=%@", NSStringFromClass(cls));
}

#pragma mark - Install

static void XLGInstallHooks(void) {
    XLGInstallNFB();
    Class installer = NSClassFromString(@"T1LiquidGlassGateInstaller");
    Class features = XLGFeaturesClass();

    if (installer) XLGHookMethod(installer, NSSelectorFromString(@"installGateForAccount:"), YES, (IMP)XLGInstallGateForAccount, &gOrigInstallGateForAccount);
    if (features) {
        XLGHookMethod(features, NSSelectorFromString(@"isRedesignEnabled"), NO, (IMP)XLGIsRedesignEnabled, &gOrigIsRedesignEnabled);
        XLGHookMethod(features, NSSelectorFromString(@"isPushChromeSnapEnabled"), NO, (IMP)XLGIsPushChromeSnapEnabled, &gOrigIsPushChromeSnapEnabled);
    }

    BOOL legacy = installer && class_getClassMethod(installer, NSSelectorFromString(@"installGateWithRedesignEnabled:"));
    XLGLog(@"HOOK_PASS installer=%@ features=%@ legacyGate=%@ gateHook=%@ redesignHook=%@ pushChromeHook=%@ nfb=%@",
           installer ? NSStringFromClass(installer) : @"<nil>", features ? NSStringFromClass(features) : @"<nil>",
           legacy ? @"YES" : @"NO", gOrigInstallGateForAccount ? @"YES" : @"NO",
           gOrigIsRedesignEnabled ? @"YES" : @"NO", gOrigIsPushChromeSnapEnabled ? @"YES" : @"NO", gNFBHooked ? @"YES" : @"NO");
}

__attribute__((constructor))
static void XLiquidGlass1238ProbeInit(void) {
    @autoreleasepool {
        XLGLog(@"NEW_SESSION version=%@ target=X_%@ mode=PASSIVE", kProbeVersion, kTargetVersion);
        XLGInstallHooks();
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray<NSNumber *> *delays = @[@0.0, @0.25, @0.75, @1.5, @3.0, @6.0, @10.0];
            for (NSNumber *delay in delays) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ XLGInstallHooks(); });
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ XLGCapture(@"launch+1s"); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ XLGCapture(@"launch+5s"); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ XLGCapture(@"launch+12s"); });
        });
    }
}
