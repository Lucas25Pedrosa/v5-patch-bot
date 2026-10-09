#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <stdatomic.h>

static NSString *const kXCEPReportName = @"XLiquidGlassCommentsEffectProbe.txt";
static const NSTimeInterval kXCEPPrepDelay = 8.0;
static const NSTimeInterval kXCEPCaptureDuration = 15.0;
static const NSUInteger kXCEPMaxTrackedViews = 64;
static const NSUInteger kXCEPMaxEffectPointersPerView = 32;
static const NSUInteger kXCEPMaxFullStacks = 10;

static IMP gNextSetEffect = NULL;
static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;
static BOOL gEffectHookInstalled = NO;
static BOOL gNFBHooksInstalled = NO;
static _Atomic(bool) gCaptureActive = false;
static BOOL gCaptureArmed = NO;
static NSUInteger gCaptureSerial = 0;
static CFTimeInterval gCaptureStart = 0;
static NSString *gSetEffectOwner = @"-";
static NSMutableDictionary<NSNumber *, NSMutableDictionary *> *gViewStats = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gCallerCounts = nil;
static NSString *gLastReport = nil;
static uint64_t gRelevantCalls = 0;
static uint64_t gSkippedNonConversation = 0;
static uint64_t gFullStacksCaptured = 0;
static double gTotalChainMS = 0.0;
static double gMaxChainMS = 0.0;

#pragma mark - Helpers

static NSString *XCEPReportPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs.length) docs = NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:kXCEPReportName];
}

static NSString *XCEPStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:NSDate.date];
}

static NSString *XCEPImageForAddress(const void *address) {
    if (!address) return @"-";
    Dl_info info = {0};
    if (!dladdr(address, &info) || !info.dli_fname) return @"-";
    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
    return path.lastPathComponent ?: path ?: @"-";
}

static NSString *XCEPSymbolForAddress(const void *address) {
    if (!address) return @"-";
    Dl_info info = {0};
    if (!dladdr(address, &info)) return @"-";
    NSString *image = info.dli_fname ? [[NSString stringWithUTF8String:info.dli_fname] lastPathComponent] : @"-";
    NSString *symbol = info.dli_sname ? [NSString stringWithUTF8String:info.dli_sname] : @"?";
    uintptr_t offset = 0;
    if (info.dli_saddr) offset = (uintptr_t)address - (uintptr_t)info.dli_saddr;
    return [NSString stringWithFormat:@"%@!%@+0x%lx", image ?: @"-", symbol ?: @"?", (unsigned long)offset];
}

static NSString *XCEPImageForIMP(IMP imp) {
    return XCEPImageForAddress((const void *)imp);
}

static NSString *XCEPClassName(id object) {
    return object ? (NSStringFromClass([object class]) ?: @"?") : @"nil";
}

static NSString *XCEPEffectDescription(UIVisualEffect *effect) {
    if (!effect) return @"nil";
    return [NSString stringWithFormat:@"%@(%p)", XCEPClassName(effect), effect];
}

static NSString *XCEPRect(CGRect rect) {
    return [NSString stringWithFormat:@"{{%.1f,%.1f},{%.1f,%.1f}}",
            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height];
}

static BOOL XCEPClassHasNeedle(id object, NSString *needle) {
    if (!object || !needle.length) return NO;
    return [XCEPClassName(object) rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL XCEPConversationContextForView(UIView *view) {
    if (!view) return NO;
    BOOL hasConversation = NO;
    BOOL hasURT = NO;
    BOOL hasTable = NO;

    UIView *cursor = view;
    for (NSUInteger depth = 0; cursor && depth < 32; depth++, cursor = cursor.superview) {
        if (XCEPClassHasNeedle(cursor, @"TFNTableView")) hasTable = YES;
        UIResponder *next = cursor.nextResponder;
        if (XCEPClassHasNeedle(next, @"T1URTViewController")) hasURT = YES;
        if (XCEPClassHasNeedle(next, @"T1ConversationContainerViewController")) hasConversation = YES;
    }

    UIResponder *responder = view;
    for (NSUInteger depth = 0; responder && depth < 48; depth++) {
        if (XCEPClassHasNeedle(responder, @"T1URTViewController")) hasURT = YES;
        if (XCEPClassHasNeedle(responder, @"T1ConversationContainerViewController")) hasConversation = YES;
        responder = responder.nextResponder;
    }
    return hasConversation && hasURT && hasTable;
}

static NSString *XCEPOwnerChain(UIView *view) {
    if (!view) return @"-";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIView *cursor = view;
    for (NSUInteger depth = 0; cursor && depth < 24; depth++, cursor = cursor.superview) {
        NSString *name = XCEPClassName(cursor);
        if ([name localizedCaseInsensitiveContainsString:@"XDSBlur"] ||
            [name localizedCaseInsensitiveContainsString:@"XDSGlass"] ||
            [name localizedCaseInsensitiveContainsString:@"ScrollEdge"] ||
            [name localizedCaseInsensitiveContainsString:@"LiquidLens"] ||
            [name localizedCaseInsensitiveContainsString:@"Backdrop"] ||
            [name localizedCaseInsensitiveContainsString:@"TFNTableView"]) {
            [parts addObject:[NSString stringWithFormat:@"%@(%p)", name, cursor]];
        }
    }
    return parts.count ? [parts componentsJoinedByString:@" -> "] : @"-";
}

static NSString *XCEPContextSnapshot(UIView *view) {
    if (!view) return @"-";
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"view=%@(%p) frame=%@ bounds=%@ window=%@(%p)\n",
     XCEPClassName(view), view, XCEPRect(view.frame), XCEPRect(view.bounds),
     XCEPClassName(view.window), view.window];
    [out appendFormat:@"ownerChain=%@\n", XCEPOwnerChain(view)];

    [out appendString:@"superviews:\n"];
    UIView *cursor = view;
    for (NSUInteger depth = 0; cursor && depth < 18; depth++, cursor = cursor.superview) {
        [out appendFormat:@"  %02lu %@(%p) frame=%@\n",
         (unsigned long)depth, XCEPClassName(cursor), cursor, XCEPRect(cursor.frame)];
    }

    [out appendString:@"responders:\n"];
    UIResponder *r = view;
    for (NSUInteger depth = 0; r && depth < 24; depth++) {
        [out appendFormat:@"  %02lu %@(%p)%@\n",
         (unsigned long)depth, XCEPClassName(r), r,
         [r isKindOfClass:UIViewController.class] ? @" <VC>" : @""];
        r = r.nextResponder;
    }
    return out;
}

static NSArray<NSString *> *XCEPStackSnapshot(void) {
    void *frames[28] = {0};
    int count = backtrace(frames, 28);
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (int i = 1; i < count && i < 18; i++) {
        [lines addObject:[NSString stringWithFormat:@"%02d %@", i, XCEPSymbolForAddress(frames[i])]];
    }
    return lines;
}

static void XCEPIncrement(NSMutableDictionary *dict, NSString *key) {
    if (!dict || !key) return;
    dict[key] = @([dict[key] unsignedLongLongValue] + 1);
}

static void XCEPCountString(NSMutableDictionary<NSString *, NSNumber *> *dict, NSString *key) {
    if (!dict || !key.length) return;
    dict[key] = @([dict[key] unsignedLongLongValue] + 1);
}

static NSMutableDictionary *XCEPStatForView(UIVisualEffectView *view, BOOL create) {
    if (!view) return nil;
    if (!gViewStats && create) gViewStats = [NSMutableDictionary dictionary];
    NSNumber *key = @((uintptr_t)(__bridge void *)view);
    NSMutableDictionary *stat = gViewStats[key];
    if (!stat && create && gViewStats.count < kXCEPMaxTrackedViews) {
        stat = [@{
            @"ptr": key,
            @"class": XCEPClassName(view),
            @"calls": @0,
            @"incomingNil": @0,
            @"incomingNonNil": @0,
            @"beforeNil": @0,
            @"afterNil": @0,
            @"incomingEqualsBefore": @0,
            @"afterEqualsIncoming": @0,
            @"beforeEqualsAfter": @0,
            @"nonNilBecameNil": @0,
            @"sameIncomingRepeated": @0,
            @"chainMS": @0.0,
            @"maxMS": @0.0,
            @"ownerChain": XCEPOwnerChain(view) ?: @"-",
            @"context": XCEPContextSnapshot(view) ?: @"-",
            @"incomingEffects": [NSMutableDictionary dictionary],
            @"effectClasses": [NSMutableDictionary dictionary],
            @"callerImages": [NSMutableDictionary dictionary],
            @"stacks": [NSMutableArray array],
            @"lastIncomingPtr": @0
        } mutableCopy];
        gViewStats[key] = stat;
    }
    return stat;
}

static NSString *XCEPEffectPointerKey(UIVisualEffect *effect) {
    if (!effect) return @"nil";
    return [NSString stringWithFormat:@"%p %@", effect, XCEPClassName(effect)];
}

#pragma mark - setEffect hook

static void XCEPSetEffect(id self, SEL cmd, UIVisualEffect *incoming) {
    if (!gNextSetEffect) return;

    if (!atomic_load(&gCaptureActive) ||
        ![NSThread isMainThread] ||
        ![self isKindOfClass:UIVisualEffectView.class]) {
        ((void(*)(id,SEL,id))gNextSetEffect)(self, cmd, incoming);
        return;
    }

    UIVisualEffectView *view = (UIVisualEffectView *)self;
    if (!XCEPConversationContextForView(view)) {
        gSkippedNonConversation++;
        ((void(*)(id,SEL,id))gNextSetEffect)(self, cmd, incoming);
        return;
    }

    gRelevantCalls++;
    NSMutableDictionary *stat = XCEPStatForView(view, YES);
    if (!stat) {
        ((void(*)(id,SEL,id))gNextSetEffect)(self, cmd, incoming);
        return;
    }

    UIVisualEffect *before = view.effect;
    XCEPIncrement(stat, @"calls");
    XCEPIncrement(stat, incoming ? @"incomingNonNil" : @"incomingNil");
    if (!before) XCEPIncrement(stat, @"beforeNil");
    if (incoming && incoming == before) XCEPIncrement(stat, @"incomingEqualsBefore");

    uintptr_t incomingPtr = (uintptr_t)(__bridge void *)incoming;
    uintptr_t lastIncomingPtr = [stat[@"lastIncomingPtr"] unsignedLongLongValue];
    if (incoming && incomingPtr == lastIncomingPtr) XCEPIncrement(stat, @"sameIncomingRepeated");
    stat[@"lastIncomingPtr"] = @(incomingPtr);

    NSMutableDictionary *incomingEffects = stat[@"incomingEffects"];
    if (incomingEffects.count < kXCEPMaxEffectPointersPerView || incomingEffects[XCEPEffectPointerKey(incoming)]) {
        XCEPCountString(incomingEffects, XCEPEffectPointerKey(incoming));
    }
    XCEPCountString(stat[@"effectClasses"], XCEPClassName(incoming));

    void *caller = __builtin_return_address(0);
    NSString *callerImage = XCEPImageForAddress(caller);
    XCEPCountString(gCallerCounts, callerImage);
    XCEPCountString(stat[@"callerImages"], callerImage);

    BOOL canCaptureStack = gFullStacksCaptured < kXCEPMaxFullStacks && [stat[@"stacks"] count] < 2;
    NSArray<NSString *> *pendingStack = canCaptureStack ? XCEPStackSnapshot() : nil;

    CFTimeInterval t0 = CACurrentMediaTime();
    ((void(*)(id,SEL,id))gNextSetEffect)(self, cmd, incoming);
    CFTimeInterval elapsedMS = (CACurrentMediaTime() - t0) * 1000.0;

    UIVisualEffect *after = view.effect;
    if (!after) XCEPIncrement(stat, @"afterNil");
    if (after == incoming) XCEPIncrement(stat, @"afterEqualsIncoming");
    if (before == after) XCEPIncrement(stat, @"beforeEqualsAfter");
    BOOL nonNilBecameNil = incoming && !after;
    if (nonNilBecameNil) XCEPIncrement(stat, @"nonNilBecameNil");

    double statMS = [stat[@"chainMS"] doubleValue] + elapsedMS;
    stat[@"chainMS"] = @(statMS);
    if (elapsedMS > [stat[@"maxMS"] doubleValue]) stat[@"maxMS"] = @(elapsedMS);
    gTotalChainMS += elapsedMS;
    if (elapsedMS > gMaxChainMS) gMaxChainMS = elapsedMS;

    if (pendingStack && (nonNilBecameNil || [stat[@"calls"] unsignedIntegerValue] == 1)) {
        NSMutableArray *stacks = stat[@"stacks"];
        NSString *header = [NSString stringWithFormat:@"incoming=%@ before=%@ after=%@ caller=%@",
                            XCEPEffectDescription(incoming), XCEPEffectDescription(before),
                            XCEPEffectDescription(after), XCEPSymbolForAddress(caller)];
        [stacks addObject:@{ @"header": header, @"lines": pendingStack }];
        gFullStacksCaptured++;
    }
}

static BOOL XCEPHook(Class cls, SEL sel, IMP replacement, IMP *originalOut, NSString **ownerOut) {
    if (!cls || !sel || !replacement) return NO;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    IMP current = class_getMethodImplementation(cls, sel);
    if (!current) return NO;
    if (current == replacement) return YES;
    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;
    if (originalOut && !*originalOut) *originalOut = current;
    if (ownerOut) *ownerOut = XCEPImageForIMP(current);
    class_replaceMethod(cls, sel, replacement, types);
    return class_getMethodImplementation(cls, sel) == replacement;
}

static void XCEPInstallEffectHook(void) {
    if (gEffectHookInstalled) return;
    Class cls = UIVisualEffectView.class;
    BOOL ok = XCEPHook(cls, @selector(setEffect:), (IMP)XCEPSetEffect, &gNextSetEffect, &gSetEffectOwner);
    gEffectHookInstalled = ok;
}

#pragma mark - Report

static NSArray<NSDictionary *> *XCEPSortedDictionaryCounts(NSDictionary<NSString *, NSNumber *> *dict) {
    NSMutableArray *rows = [NSMutableArray array];
    [dict enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *value, BOOL *stop) {
        [rows addObject:@{ @"key": key ?: @"-", @"count": value ?: @0 }];
    }];
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        unsigned long long ca = [a[@"count"] unsignedLongLongValue];
        unsigned long long cb = [b[@"count"] unsignedLongLongValue];
        if (ca > cb) return NSOrderedAscending;
        if (ca < cb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return rows;
}

static NSArray<NSMutableDictionary *> *XCEPSortedViewStats(void) {
    NSArray *values = gViewStats.allValues ?: @[];
    return [values sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSUInteger ca = [a[@"calls"] unsignedIntegerValue];
        NSUInteger cb = [b[@"calls"] unsignedIntegerValue];
        if (ca > cb) return NSOrderedAscending;
        if (ca < cb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static void XCEPAppendTopCounts(NSMutableString *r, NSString *title, NSDictionary *dict, NSUInteger limit) {
    [r appendFormat:@"%@:\n", title];
    NSArray *rows = XCEPSortedDictionaryCounts(dict ?: @{});
    if (!rows.count) { [r appendString:@"  -\n"]; return; }
    for (NSUInteger i = 0; i < MIN(limit, rows.count); i++) {
        NSDictionary *row = rows[i];
        [r appendFormat:@"  %5llu  %@\n", [row[@"count"] unsignedLongLongValue], row[@"key"]];
    }
}

static NSString *XCEPBuildReport(double duration) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSMutableString *r = [NSMutableString string];
    [r appendString:@"============================================================\n"];
    [r appendFormat:@"XLiquidGlass Comments Effect Churn Probe 0.3 - captura #%lu\n", (unsigned long)gCaptureSerial];
    [r appendFormat:@"Data: %@\n", XCEPStamp()];
    [r appendFormat:@"App: %@ build %@ | bundle=%@\n",
     info[@"CFBundleShortVersionString"] ?: @"-", info[@"CFBundleVersion"] ?: @"-",
     NSBundle.mainBundle.bundleIdentifier ?: @"-"];
    [r appendFormat:@"Duracao real: %.3f s\n", duration];
    [r appendString:@"Probe observacional: nao altera effect, blur, glass, layout ou setNeedsLayout.\n"];
    [r appendString:@"============================================================\n\n"];

    [r appendString:@"[HOOK]\n"];
    [r appendFormat:@"UIVisualEffectView setEffect: owner antes da probe=%@\n", gSetEffectOwner ?: @"-"];
    [r appendFormat:@"tracked relevant calls=%llu | non-conversation ignored=%llu | views=%lu\n",
     gRelevantCalls, gSkippedNonConversation, (unsigned long)gViewStats.count];
    [r appendFormat:@"chain total=%.3f ms | avg=%.4f ms/call | max=%.3f ms\n\n",
     gTotalChainMS, gRelevantCalls ? gTotalChainMS/(double)gRelevantCalls : 0.0, gMaxChainMS];

    XCEPAppendTopCounts(r, @"[CALLER IMAGES]", gCallerCounts, 12);
    [r appendString:@"\n"];

    [r appendString:@"[EFFECT VIEWS]\n"];
    NSArray *stats = XCEPSortedViewStats();
    for (NSUInteger i = 0; i < MIN((NSUInteger)16, stats.count); i++) {
        NSDictionary *s = stats[i];
        NSUInteger calls = [s[@"calls"] unsignedIntegerValue];
        [r appendFormat:@"\n#%lu ptr=0x%llx class=%@ calls=%lu (%.1f/s)\n",
         (unsigned long)(i+1), [s[@"ptr"] unsignedLongLongValue], s[@"class"],
         (unsigned long)calls, duration > 0 ? calls/duration : 0.0];
        [r appendFormat:@"incoming nil=%@ nonnil=%@ | beforeNil=%@ afterNil=%@\n",
         s[@"incomingNil"], s[@"incomingNonNil"], s[@"beforeNil"], s[@"afterNil"]];
        [r appendFormat:@"incoming==before=%@ | after==incoming=%@ | before==after=%@\n",
         s[@"incomingEqualsBefore"], s[@"afterEqualsIncoming"], s[@"beforeEqualsAfter"]];
        [r appendFormat:@"NONNIL -> NIL after chain=%@ | same incoming ptr repeated=%@\n",
         s[@"nonNilBecameNil"], s[@"sameIncomingRepeated"]];
        [r appendFormat:@"chain total=%.3f ms avg=%.4f ms max=%.3f ms\n",
         [s[@"chainMS"] doubleValue], calls ? [s[@"chainMS"] doubleValue]/calls : 0.0,
         [s[@"maxMS"] doubleValue]];
        [r appendFormat:@"ownerChain=%@\n", s[@"ownerChain"] ?: @"-"];
        XCEPAppendTopCounts(r, @"incoming effect pointers", s[@"incomingEffects"], 8);
        XCEPAppendTopCounts(r, @"effect classes", s[@"effectClasses"], 6);
        XCEPAppendTopCounts(r, @"caller images", s[@"callerImages"], 6);
        [r appendFormat:@"context:\n%@\n", s[@"context"] ?: @"-"];
        NSArray *stacks = s[@"stacks"];
        for (NSUInteger j = 0; j < stacks.count; j++) {
            NSDictionary *sample = stacks[j];
            [r appendFormat:@"stack sample %lu: %@\n", (unsigned long)(j+1), sample[@"header"] ?: @"-"];
            for (NSString *line in sample[@"lines"] ?: @[]) [r appendFormat:@"  %@\n", line];
        }
    }

    [r appendString:@"\n[INTERPRETACAO AUTOMATICA]\n"];
    uint64_t totalNonNilToNil = 0;
    uint64_t totalIncomingNonNil = 0;
    uint64_t totalAfterEqualsIncoming = 0;
    for (NSDictionary *s in stats) {
        totalNonNilToNil += [s[@"nonNilBecameNil"] unsignedLongLongValue];
        totalIncomingNonNil += [s[@"incomingNonNil"] unsignedLongLongValue];
        totalAfterEqualsIncoming += [s[@"afterEqualsIncoming"] unsignedLongLongValue];
    }
    [r appendFormat:@"incoming nonnil total=%llu | nonnil->nil=%llu | after==incoming=%llu\n",
     totalIncomingNonNil, totalNonNilToNil, totalAfterEqualsIncoming];
    if (totalNonNilToNil > 0) {
        [r appendString:@"SINAL: ha chamadas em que o X entrega um efeito nao-nulo e a cadeia de hooks termina em nil.\n"];
    } else if (totalIncomingNonNil > 0 && totalAfterEqualsIncoming == totalIncomingNonNil) {
        [r appendString:@"SINAL: todos os efeitos nao-nulos observados sobreviveram a cadeia; procurar churn fora do setEffect guard.\n"];
    } else {
        [r appendString:@"SINAL: resultado misto; usar os objetos e stacks acima para localizar o proximo alvo.\n"];
    }
    [r appendString:@"\n[FIM DA CAPTURA]\n============================================================\n"];
    return r;
}

static void XCEPResetStats(void) {
    gViewStats = [NSMutableDictionary dictionary];
    gCallerCounts = [NSMutableDictionary dictionary];
    gRelevantCalls = 0;
    gSkippedNonConversation = 0;
    gFullStacksCaptured = 0;
    gTotalChainMS = 0;
    gMaxChainMS = 0;
}

static UIViewController *XCEPTopController(void) {
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
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:UINavigationController.class]) vc = ((UINavigationController *)vc).topViewController;
    return vc;
}

static void XCEPFinishCapture(void) {
    if (!atomic_exchange(&gCaptureActive, false)) return;
    double duration = CACurrentMediaTime() - gCaptureStart;
    gLastReport = XCEPBuildReport(duration);
    [gLastReport writeToFile:XCEPReportPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    UIViewController *vc = XCEPTopController();
    if (vc) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Effect Churn Probe"
            message:@"Captura concluida. Volte em BHTwitter → Effect Churn Probe e copie o relatorio."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    }
}

static void XCEPBeginCapture(void) {
    if (!gCaptureArmed) return;
    gCaptureArmed = NO;
    gCaptureSerial++;
    XCEPResetStats();
    gCaptureStart = CACurrentMediaTime();
    atomic_store(&gCaptureActive, true);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kXCEPCaptureDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XCEPFinishCapture();
    });
}

#pragma mark - Menu

@interface XCEPSettingsViewController : UITableViewController
@end

@implementation XCEPSettingsViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Effect Churn Probe"; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 3; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Somente observa UIVisualEffectView setEffect: dentro de T1ConversationContainerViewController. 8 s para voltar aos comentarios + 15 s rolando.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"XCEPCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"XCEPCell"];
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (indexPath.row == 0) { cell.textLabel.text = @"Iniciar diagnostico"; cell.detailTextLabel.text = @"8 s de preparo + 15 s de captura"; }
    else if (indexPath.row == 1) { cell.textLabel.text = @"Copiar relatorio"; cell.detailTextLabel.text = @"Copia a ultima captura"; }
    else { cell.textLabel.text = @"Limpar relatorio"; cell.detailTextLabel.text = @"Apaga a captura salva"; }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Effect Churn Probe"
            message:@"Toque em Comecar, volte aos comentarios em ate 8 segundos e role continuamente por 15 segundos."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Comecar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            gCaptureArmed = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kXCEPPrepDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ XCEPBeginCapture(); });
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else if (indexPath.row == 1) {
        NSString *text = gLastReport;
        if (!text.length) text = [NSString stringWithContentsOfFile:XCEPReportPath() encoding:NSUTF8StringEncoding error:nil];
        if (text.length) UIPasteboard.generalPasteboard.string = text;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Effect Churn Probe" message:text.length ? @"Relatorio copiado." : @"Nenhum relatorio disponivel." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } else {
        gLastReport = nil;
        [[NSFileManager defaultManager] removeItemAtPath:XCEPReportPath() error:nil];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Effect Churn Probe" message:@"Relatorio apagado." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}
@end

static BOOL XCEPSectionsContainEntry(NSArray *sections) {
    for (id item in sections) {
        if ([item isKindOfClass:NSDictionary.class] && [item[@"action"] isEqualToString:@"showXLiquidGlassCommentsEffectProbe"]) return YES;
    }
    return NO;
}

static void XCEPInjectMenuEntry(id controller) {
    NSArray *sections = nil;
    @try { sections = [controller valueForKey:@"sections"]; } @catch (__unused NSException *e) { return; }
    if (![sections isKindOfClass:NSArray.class] || XCEPSectionsContainEntry(sections)) return;
    NSMutableArray *updated = [sections mutableCopy];
    NSDictionary *entry = @{ @"title": @"Effect Churn Probe", @"subtitle": @"setEffect nos comentarios.", @"icon": @"waveform.path.ecg", @"action": @"showXLiquidGlassCommentsEffectProbe" };
    [updated addObject:entry];
    @try { [controller setValue:[updated copy] forKey:@"sections"]; } @catch (__unused NSException *e) {}
}

static void XCEPNFBSetupSections(id self, SEL cmd) {
    if (gOrigNFBSetupSections) ((void(*)(id,SEL))gOrigNFBSetupSections)(self, cmd);
    XCEPInjectMenuEntry(self);
}

static void XCEPNFBViewWillAppear(id self, SEL cmd, BOOL animated) {
    if (gOrigNFBViewWillAppear) ((void(*)(id,SEL,BOOL))gOrigNFBViewWillAppear)(self, cmd, animated);
    XCEPInjectMenuEntry(self);
    UITableView *table = nil;
    @try { table = [self valueForKey:@"tableView"]; } @catch (__unused NSException *e) {}
    [table reloadData];
}

static void XCEPShowProbe(id self, SEL cmd) {
    (void)cmd;
    if (![self isKindOfClass:UIViewController.class]) return;
    XCEPSettingsViewController *probe = [XCEPSettingsViewController new];
    UIViewController *vc = (UIViewController *)self;
    if (vc.navigationController) [vc.navigationController pushViewController:probe animated:YES];
    else [vc presentViewController:[[UINavigationController alloc] initWithRootViewController:probe] animated:YES completion:nil];
}

static void XCEPInstallNFBHooks(void) {
    if (gNFBHooksInstalled) return;
    Class cls = NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;
    class_addMethod(cls, NSSelectorFromString(@"showXLiquidGlassCommentsEffectProbe"), (IMP)XCEPShowProbe, "v@:");
    BOOL a = XCEPHook(cls, NSSelectorFromString(@"setupSections"), (IMP)XCEPNFBSetupSections, &gOrigNFBSetupSections, NULL);
    BOOL b = XCEPHook(cls, @selector(viewWillAppear:), (IMP)XCEPNFBViewWillAppear, &gOrigNFBViewWillAppear, NULL);
    gNFBHooksInstalled = a || b;
}

static void XCEPInstallAll(void) {
    XCEPInstallEffectHook();
    XCEPInstallNFBHooks();
}

static void XCEPSchedule(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ XCEPInstallAll(); });
}

__attribute__((constructor))
static void XLiquidGlassCommentsEffectProbeInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlassCommentsEffectProbe] 0.3 loaded");
        XCEPInstallAll();
        for (NSNumber *delay in @[@0.05, @0.20, @0.50, @1.0, @2.0, @4.0, @8.0]) XCEPSchedule(delay.doubleValue);
    }
}
