#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <math.h>

static NSString *const kXSEVersion = @"0.5";
static NSString *const kXSEReportName = @"XLiquidGlassCommentsScrollEdgeProbe.txt";
static const NSTimeInterval kXSEPrepDelay = 8.0;
static const NSTimeInterval kXSECaptureDuration = 15.0;

static IMP gEffectLayout = NULL;
static IMP gEffectNeeds = NULL;
static IMP gBackdropLayout = NULL;
static IMP gBackdropNeeds = NULL;
static IMP gSettingsSetup = NULL;
static IMP gSettingsWillAppear = NULL;

static BOOL gVisualHooksInstalled = NO;
static BOOL gSettingsHooksInstalled = NO;
static _Atomic(bool) gCaptureActive = false;
static BOOL gCaptureArmed = NO;
static NSUInteger gCaptureSerial = 0;
static CFTimeInterval gCaptureStart = 0;
static NSString *gLastReport = nil;
static NSMutableDictionary<NSNumber *, NSMutableDictionary *> *gStats = nil;
static uint64_t gIgnoredNonConversation = 0;
static NSString *gEffectLayoutOwner = @"-";
static NSString *gBackdropLayoutOwner = @"-";

static NSString *XSEReportPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs.length) docs = NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:kXSEReportName];
}

static NSString *XSEStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:NSDate.date];
}

static NSString *XSEImageForIMP(IMP imp) {
    if (!imp) return @"-";
    Dl_info info = {0};
    if (!dladdr((const void *)imp, &info) || !info.dli_fname) return @"-";
    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
    return path.lastPathComponent ?: path ?: @"-";
}

static UIScrollView *XSETableAncestor(UIView *view) {
    UIView *cursor = view;
    for (NSUInteger i = 0; cursor && i < 32; i++, cursor = cursor.superview) {
        if ([NSStringFromClass(cursor.class) isEqualToString:@"TFNTableView"] && [cursor isKindOfClass:UIScrollView.class]) {
            return (UIScrollView *)cursor;
        }
    }
    return nil;
}

static BOOL XSEIsCommentsContext(UIView *view) {
    if (!view || !XSETableAncestor(view)) return NO;
    BOOL hasURT = NO;
    BOOL hasConversation = NO;
    UIResponder *r = view;
    for (NSUInteger i = 0; r && i < 40; i++, r = r.nextResponder) {
        if (![r isKindOfClass:UIViewController.class]) continue;
        NSString *name = NSStringFromClass(r.class);
        if ([name isEqualToString:@"T1URTViewController"]) hasURT = YES;
        if ([name isEqualToString:@"T1ConversationContainerViewController"]) hasConversation = YES;
    }
    return hasURT && hasConversation;
}

static NSString *XSEOwnerChain(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIView *cursor = view;
    for (NSUInteger i = 0; cursor && i < 10; i++, cursor = cursor.superview) {
        [parts addObject:[NSString stringWithFormat:@"%@(%p)", NSStringFromClass(cursor.class), cursor]];
        if ([NSStringFromClass(cursor.class) isEqualToString:@"TFNTableView"]) break;
    }
    return [parts componentsJoinedByString:@" -> "];
}

static NSString *XSEStackSample(void) {
    NSArray<NSNumber *> *addresses = NSThread.callStackReturnAddresses;
    NSMutableString *out = [NSMutableString string];
    NSUInteger emitted = 0;
    for (NSUInteger i = 1; i < addresses.count && emitted < 18; i++) {
        uintptr_t addr = (uintptr_t)addresses[i].unsignedLongLongValue;
        Dl_info info = {0};
        if (!dladdr((const void *)addr, &info) || !info.dli_fname) continue;
        NSString *image = [[NSString stringWithUTF8String:info.dli_fname] lastPathComponent] ?: @"?";
        NSString *symbol = info.dli_sname ? [NSString stringWithUTF8String:info.dli_sname] : @"?";
        uintptr_t base = info.dli_saddr ? (uintptr_t)info.dli_saddr : addr;
        [out appendFormat:@"  %02lu %@!%@+0x%llx\n", (unsigned long)emitted, image, symbol, (unsigned long long)(addr - base)];
        emitted++;
    }
    return out.length ? out : @"  - unavailable\n";
}

static uint64_t XSEHashMix(uint64_t h, uint64_t v) {
    h ^= v;
    h *= 1099511628211ULL;
    return h;
}

static NSArray *XSESafeLayerArray(CALayer *layer, NSString *key) {
    @try {
        id value = [layer valueForKey:key];
        return [value isKindOfClass:NSArray.class] ? value : nil;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static id XSESafeLayerValue(CALayer *layer, NSString *key) {
    @try { return [layer valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

typedef struct {
    NSUInteger filtersCount;
    NSUInteger backgroundFiltersCount;
    uintptr_t compositingFilter;
    uint64_t filterSignature;
    NSUInteger recursiveFilteredLayers;
    NSUInteger recursiveFilterObjects;
    uint64_t recursiveSignature;
    NSUInteger sublayerCount;
    uintptr_t maskPtr;
} XSELayerSnapshot;

static uint64_t XSEObjectSignature(id obj) {
    uint64_t h = 1469598103934665603ULL;
    h = XSEHashMix(h, (uintptr_t)(__bridge void *)obj);
    h = XSEHashMix(h, (uintptr_t)(obj ? [obj class] : Nil));
    if (obj) h = XSEHashMix(h, obj.hash);
    return h;
}

static void XSEAccumulateLayerTree(CALayer *layer, NSUInteger depth,
                                   NSUInteger *filteredLayers,
                                   NSUInteger *filterObjects,
                                   uint64_t *signature) {
    if (!layer || depth > 4) return;
    NSArray *filters = XSESafeLayerArray(layer, @"filters") ?: @[];
    NSArray *background = XSESafeLayerArray(layer, @"backgroundFilters") ?: @[];
    id compositing = XSESafeLayerValue(layer, @"compositingFilter");
    NSUInteger count = filters.count + background.count + (compositing ? 1 : 0);
    if (count) (*filteredLayers)++;
    *filterObjects += count;
    *signature = XSEHashMix(*signature, (uintptr_t)(__bridge void *)layer);
    *signature = XSEHashMix(*signature, count);
    for (id obj in filters) *signature = XSEHashMix(*signature, XSEObjectSignature(obj));
    for (id obj in background) *signature = XSEHashMix(*signature, XSEObjectSignature(obj));
    if (compositing) *signature = XSEHashMix(*signature, XSEObjectSignature(compositing));
    for (CALayer *child in layer.sublayers) XSEAccumulateLayerTree(child, depth + 1, filteredLayers, filterObjects, signature);
}

static XSELayerSnapshot XSESnapshotLayer(CALayer *layer) {
    XSELayerSnapshot s = {0};
    NSArray *filters = XSESafeLayerArray(layer, @"filters") ?: @[];
    NSArray *background = XSESafeLayerArray(layer, @"backgroundFilters") ?: @[];
    id compositing = XSESafeLayerValue(layer, @"compositingFilter");
    s.filtersCount = filters.count;
    s.backgroundFiltersCount = background.count;
    s.compositingFilter = (uintptr_t)(__bridge void *)compositing;
    uint64_t h = 1469598103934665603ULL;
    for (id obj in filters) h = XSEHashMix(h, XSEObjectSignature(obj));
    for (id obj in background) h = XSEHashMix(h, XSEObjectSignature(obj));
    if (compositing) h = XSEHashMix(h, XSEObjectSignature(compositing));
    s.filterSignature = h;
    s.recursiveSignature = 1469598103934665603ULL;
    XSEAccumulateLayerTree(layer, 0, &s.recursiveFilteredLayers, &s.recursiveFilterObjects, &s.recursiveSignature);
    s.sublayerCount = layer.sublayers.count;
    s.maskPtr = (uintptr_t)(__bridge void *)layer.mask;
    return s;
}

static NSString *XSELayerDelta(XSELayerSnapshot a, XSELayerSnapshot b, double ms, UIScrollView *table) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (a.filtersCount != b.filtersCount) [parts addObject:[NSString stringWithFormat:@"filters %lu->%lu",(unsigned long)a.filtersCount,(unsigned long)b.filtersCount]];
    if (a.backgroundFiltersCount != b.backgroundFiltersCount) [parts addObject:[NSString stringWithFormat:@"backgroundFilters %lu->%lu",(unsigned long)a.backgroundFiltersCount,(unsigned long)b.backgroundFiltersCount]];
    if (a.compositingFilter != b.compositingFilter) [parts addObject:[NSString stringWithFormat:@"compositing 0x%llx->0x%llx",(unsigned long long)a.compositingFilter,(unsigned long long)b.compositingFilter]];
    if (a.filterSignature != b.filterSignature) [parts addObject:[NSString stringWithFormat:@"directFilterSig %llx->%llx",(unsigned long long)a.filterSignature,(unsigned long long)b.filterSignature]];
    if (a.recursiveFilteredLayers != b.recursiveFilteredLayers || a.recursiveFilterObjects != b.recursiveFilterObjects || a.recursiveSignature != b.recursiveSignature) {
        [parts addObject:[NSString stringWithFormat:@"tree filteredLayers %lu->%lu filterObjects %lu->%lu sig %llx->%llx",
         (unsigned long)a.recursiveFilteredLayers,(unsigned long)b.recursiveFilteredLayers,
         (unsigned long)a.recursiveFilterObjects,(unsigned long)b.recursiveFilterObjects,
         (unsigned long long)a.recursiveSignature,(unsigned long long)b.recursiveSignature]];
    }
    if (a.sublayerCount != b.sublayerCount) [parts addObject:[NSString stringWithFormat:@"sublayers %lu->%lu",(unsigned long)a.sublayerCount,(unsigned long)b.sublayerCount]];
    if (a.maskPtr != b.maskPtr) [parts addObject:[NSString stringWithFormat:@"mask 0x%llx->0x%llx",(unsigned long long)a.maskPtr,(unsigned long long)b.maskPtr]];
    return [NSString stringWithFormat:@"%.3f ms | offset={%.1f,%.1f} | %@", ms, table.contentOffset.x, table.contentOffset.y,
            parts.count ? [parts componentsJoinedByString:@" | "] : @"NO FILTER/LAYER MUTATION"];
}

static NSMutableDictionary *XSEStatForView(UIView *view) {
    if (!gStats) gStats = [NSMutableDictionary dictionary];
    NSNumber *key = @((uintptr_t)(__bridge void *)view);
    NSMutableDictionary *stat = gStats[key];
    if (!stat) {
        stat = [@{
            @"ptr":key,
            @"class":NSStringFromClass(view.class) ?: @"-",
            @"layout":@0,
            @"needs":@0,
            @"changed":@0,
            @"unchanged":@0,
            @"filterDrops":@0,
            @"filterAdds":@0,
            @"filterTreeChanges":@0,
            @"totalMs":@0.0,
            @"maxMs":@0.0,
            @"firstContext":@"",
            @"layoutSamples":[NSMutableArray array],
            @"needsStacks":[NSMutableArray array]
        } mutableCopy];
        gStats[key] = stat;
    }
    return stat;
}

static NSString *XSEContextSummary(UIView *view) {
    UIScrollView *table = XSETableAncestor(view);
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"target=%@(%p) frame=%@\n",NSStringFromClass(view.class),view,NSStringFromCGRect(view.frame)];
    [s appendFormat:@"ownerChain=%@\n",XSEOwnerChain(view)];
    if (table) [s appendFormat:@"table=%@(%p) offset={%.1f,%.1f} size={%.1f,%.1f}\n",NSStringFromClass(table.class),table,table.contentOffset.x,table.contentOffset.y,table.contentSize.width,table.contentSize.height];
    [s appendString:@"responders:\n"];
    UIResponder *r = view;
    for (NSUInteger i=0; r && i<22; i++, r=r.nextResponder) {
        [s appendFormat:@"  %02lu %@(%p)%@\n",(unsigned long)i,NSStringFromClass(r.class),r,[r isKindOfClass:UIViewController.class]?@" <VC>":@""];
    }
    return s;
}

static void XSERecordNeeds(UIView *view) {
    if (!atomic_load(&gCaptureActive) || ![NSThread isMainThread]) return;
    if (!XSEIsCommentsContext(view)) { gIgnoredNonConversation++; return; }
    NSMutableDictionary *stat = XSEStatForView(view);
    stat[@"needs"] = @([stat[@"needs"] unsignedLongLongValue] + 1);
    NSMutableArray *samples = stat[@"needsStacks"];
    if (samples.count < 3) [samples addObject:XSEStackSample()];
}

static void XSERecordLayout(UIView *view, IMP original, SEL cmd) {
    if (!original) return;
    BOOL active = atomic_load(&gCaptureActive) && [NSThread isMainThread];
    BOOL relevant = active && XSEIsCommentsContext(view);
    if (active && !relevant) gIgnoredNonConversation++;
    if (!relevant) { ((void(*)(id,SEL))original)(view,cmd); return; }

    NSMutableDictionary *stat = XSEStatForView(view);
    if (![stat[@"firstContext"] length]) stat[@"firstContext"] = XSEContextSummary(view);
    UIScrollView *table = XSETableAncestor(view);
    XSELayerSnapshot before = XSESnapshotLayer(view.layer);
    CFTimeInterval t0 = CACurrentMediaTime();
    ((void(*)(id,SEL))original)(view,cmd);
    double ms = (CACurrentMediaTime() - t0) * 1000.0;
    XSELayerSnapshot after = XSESnapshotLayer(view.layer);

    stat[@"layout"] = @([stat[@"layout"] unsignedLongLongValue] + 1);
    stat[@"totalMs"] = @([stat[@"totalMs"] doubleValue] + ms);
    stat[@"maxMs"] = @(MAX([stat[@"maxMs"] doubleValue],ms));

    BOOL changed = before.filtersCount != after.filtersCount ||
                   before.backgroundFiltersCount != after.backgroundFiltersCount ||
                   before.compositingFilter != after.compositingFilter ||
                   before.filterSignature != after.filterSignature ||
                   before.recursiveFilteredLayers != after.recursiveFilteredLayers ||
                   before.recursiveFilterObjects != after.recursiveFilterObjects ||
                   before.recursiveSignature != after.recursiveSignature ||
                   before.sublayerCount != after.sublayerCount ||
                   before.maskPtr != after.maskPtr;
    NSString *bucket = changed ? @"changed" : @"unchanged";
    stat[bucket] = @([stat[bucket] unsignedLongLongValue] + 1);
    if (before.recursiveFilterObjects > after.recursiveFilterObjects) stat[@"filterDrops"] = @([stat[@"filterDrops"] unsignedLongLongValue] + 1);
    if (before.recursiveFilterObjects < after.recursiveFilterObjects) stat[@"filterAdds"] = @([stat[@"filterAdds"] unsignedLongLongValue] + 1);
    if (before.recursiveSignature != after.recursiveSignature) stat[@"filterTreeChanges"] = @([stat[@"filterTreeChanges"] unsignedLongLongValue] + 1);

    NSMutableArray *samples = stat[@"layoutSamples"];
    if ((changed || ms > 0.30) && samples.count < 8) {
        [samples addObject:[NSString stringWithFormat:@"sample %lu: %@\n%@",(unsigned long)(samples.count+1),XSELayerDelta(before,after,ms,table),XSEStackSample()]];
    }
}

static void XSEEffectLayout(id self, SEL cmd) { XSERecordLayout(self,gEffectLayout,cmd); }
static void XSEEffectNeeds(id self, SEL cmd) { XSERecordNeeds(self); if (gEffectNeeds) ((void(*)(id,SEL))gEffectNeeds)(self,cmd); }
static void XSEBackdropLayout(id self, SEL cmd) { XSERecordLayout(self,gBackdropLayout,cmd); }
static void XSEBackdropNeeds(id self, SEL cmd) { XSERecordNeeds(self); if (gBackdropNeeds) ((void(*)(id,SEL))gBackdropNeeds)(self,cmd); }

static BOOL XSEHook(Class cls, SEL sel, IMP replacement, IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;
    Method m = class_getInstanceMethod(cls,sel);
    if (!m) return NO;
    IMP current = class_getMethodImplementation(cls,sel);
    if (!current) return NO;
    if (current == replacement) return YES;
    const char *types = method_getTypeEncoding(m);
    if (!types) return NO;
    if (originalOut && !*originalOut) *originalOut = current;
    class_replaceMethod(cls,sel,replacement,types);
    return class_getMethodImplementation(cls,sel) == replacement;
}

static void XSEInstallVisualHooks(void) {
    if (gVisualHooksInstalled) return;
    Class effect = NSClassFromString(@"_TtC5UIKit20ScrollEdgeEffectView");
    if (!effect) effect = NSClassFromString(@"UIKit.ScrollEdgeEffectView");
    Class backdrop = NSClassFromString(@"_TtCC5UIKit20ScrollEdgeEffectView12BackdropView");
    BOOL any = NO;
    if (effect) {
        gEffectLayoutOwner = XSEImageForIMP(class_getMethodImplementation(effect,@selector(layoutSubviews)));
        BOOL a = XSEHook(effect,@selector(layoutSubviews),(IMP)XSEEffectLayout,&gEffectLayout);
        BOOL b = XSEHook(effect,@selector(setNeedsLayout),(IMP)XSEEffectNeeds,&gEffectNeeds);
        any = any || a || b;
    }
    if (backdrop) {
        gBackdropLayoutOwner = XSEImageForIMP(class_getMethodImplementation(backdrop,@selector(layoutSubviews)));
        BOOL a = XSEHook(backdrop,@selector(layoutSubviews),(IMP)XSEBackdropLayout,&gBackdropLayout);
        BOOL b = XSEHook(backdrop,@selector(setNeedsLayout),(IMP)XSEBackdropNeeds,&gBackdropNeeds);
        any = any || a || b;
    }
    gVisualHooksInstalled = any;
}

static NSArray<NSDictionary *> *XSESortedStats(void) {
    return [(gStats.allValues ?: @[]) sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        uint64_t ca=[a[@"layout"] unsignedLongLongValue]+[a[@"needs"] unsignedLongLongValue];
        uint64_t cb=[b[@"layout"] unsignedLongLongValue]+[b[@"needs"] unsignedLongLongValue];
        if (ca>cb) return NSOrderedAscending;
        if (ca<cb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static NSString *XSEBuildReport(double duration) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSMutableString *r = [NSMutableString string];
    [r appendString:@"============================================================\n"];
    [r appendFormat:@"XLiquidGlass Comments ScrollEdge/Backdrop Filter Probe %@ - captura #%lu\n",kXSEVersion,(unsigned long)gCaptureSerial];
    [r appendFormat:@"Data: %@\n",XSEStamp()];
    [r appendFormat:@"App: %@ build %@ | bundle=%@\n",info[@"CFBundleShortVersionString"]?:@"-",info[@"CFBundleVersion"]?:@"-",NSBundle.mainBundle.bundleIdentifier?:@"-"];
    [r appendFormat:@"Duracao real: %.3f s\n",duration];
    [r appendString:@"Probe observacional: mede ScrollEdgeEffectView/BackdropView, setNeedsLayout e filtros CALayer no contexto de comentarios.\n"];
    [r appendString:@"============================================================\n\n"];
    [r appendFormat:@"[HOOK OWNERS]\nScrollEdgeEffectView layout owner=%@\nBackdropView layout owner=%@\n\n",gEffectLayoutOwner,gBackdropLayoutOwner];
    [r appendFormat:@"non-conversation ignored=%llu | objects=%lu\n\n",(unsigned long long)gIgnoredNonConversation,(unsigned long)gStats.count];

    NSUInteger idx=0;
    uint64_t totalLayout=0,totalNeeds=0,totalChanged=0,totalDrops=0,totalAdds=0,totalTree=0;
    double totalMs=0,maxMs=0;
    for (NSDictionary *s in XSESortedStats()) {
        idx++;
        uint64_t layout=[s[@"layout"] unsignedLongLongValue],needs=[s[@"needs"] unsignedLongLongValue];
        uint64_t changed=[s[@"changed"] unsignedLongLongValue],unchanged=[s[@"unchanged"] unsignedLongLongValue];
        uint64_t drops=[s[@"filterDrops"] unsignedLongLongValue],adds=[s[@"filterAdds"] unsignedLongLongValue],tree=[s[@"filterTreeChanges"] unsignedLongLongValue];
        double t=[s[@"totalMs"] doubleValue],m=[s[@"maxMs"] doubleValue];
        totalLayout+=layout; totalNeeds+=needs; totalChanged+=changed; totalDrops+=drops; totalAdds+=adds; totalTree+=tree; totalMs+=t; maxMs=MAX(maxMs,m);
        [r appendFormat:@"#%lu ptr=0x%llx class=%@\n",(unsigned long)idx,[s[@"ptr"] unsignedLongLongValue],s[@"class"]];
        [r appendFormat:@"layout=%llu (%.1f/s) setNeeds=%llu (%.1f/s)\n",(unsigned long long)layout,duration?layout/duration:0,(unsigned long long)needs,duration?needs/duration:0];
        [r appendFormat:@"layout time total=%.3f ms avg=%.4f ms max=%.3f ms\n",t,layout?t/layout:0,m];
        [r appendFormat:@"filter/layer changed=%llu unchanged=%llu | filterDrops=%llu filterAdds=%llu treeSignatureChanges=%llu\n",(unsigned long long)changed,(unsigned long long)unchanged,(unsigned long long)drops,(unsigned long long)adds,(unsigned long long)tree];
        [r appendFormat:@"context:\n%@\n",s[@"firstContext"]];
        NSArray *samples=s[@"layoutSamples"];
        [r appendString:@"layout/filter samples:\n"];
        if (!samples.count) [r appendString:@"  - none\n"];
        for (NSString *sample in samples) [r appendFormat:@"%@\n",sample];
        NSArray *needsStacks=s[@"needsStacks"];
        [r appendString:@"setNeedsLayout stack samples:\n"];
        if (!needsStacks.count) [r appendString:@"  - none\n"];
        NSUInteger n=0; for (NSString *sample in needsStacks) [r appendFormat:@"needs sample %lu:\n%@\n",(unsigned long)++n,sample];
        [r appendString:@"\n"];
    }

    [r appendString:@"[RESUMO]\n"];
    [r appendFormat:@"layout total=%llu (%.1f/s) setNeeds total=%llu (%.1f/s)\n",(unsigned long long)totalLayout,duration?totalLayout/duration:0,(unsigned long long)totalNeeds,duration?totalNeeds/duration:0];
    [r appendFormat:@"filter/layer changed=%llu | filterDrops=%llu filterAdds=%llu treeSignatureChanges=%llu\n",(unsigned long long)totalChanged,(unsigned long long)totalDrops,(unsigned long long)totalAdds,(unsigned long long)totalTree];
    [r appendFormat:@"layout execution total=%.3f ms avg=%.4f ms max=%.3f ms\n",totalMs,totalLayout?totalMs/totalLayout:0,maxMs];
    if (totalDrops) [r appendString:@"SINAL: filtros desaparecem durante layout; forte candidato a churn causado pelo hook de Backdrop/ScrollEdge.\n"];
    else if (totalTree) [r appendString:@"SINAL: a arvore de filtros muda sem queda liquida; pode haver recriacao/substituicao de filtros.\n"];
    else if (totalNeeds > totalLayout*3 && totalLayout) [r appendString:@"SINAL: invalidacao de ScrollEdge muito acima dos layouts reais; investigar origem dos setNeedsLayout.\n"];
    else [r appendString:@"SINAL: nenhum churn de filtro relevante observado nesta captura.\n"];
    [r appendString:@"\n[FIM DA CAPTURA]\n============================================================\n"];
    return r;
}

static void XSEReset(void) { gStats=[NSMutableDictionary dictionary]; gIgnoredNonConversation=0; }

static UIViewController *XSETopController(void) {
    UIWindow *window=nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) { window=w; break; }
        if (window) break;
    }
    UIViewController *vc=window.rootViewController;
    while (YES) {
        UIViewController *next=nil;
        if (vc.presentedViewController) next=vc.presentedViewController;
        else if ([vc isKindOfClass:UINavigationController.class]) next=((UINavigationController *)vc).topViewController;
        else if ([vc isKindOfClass:UITabBarController.class]) next=((UITabBarController *)vc).selectedViewController;
        if (!next || next==vc) break;
        vc=next;
    }
    return vc;
}

static void XSEFinishCapture(void) {
    if (!atomic_exchange(&gCaptureActive,false)) return;
    double duration=CACurrentMediaTime()-gCaptureStart;
    gLastReport=XSEBuildReport(duration);
    [gLastReport writeToFile:XSEReportPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    UIPasteboard.generalPasteboard.string=gLastReport;
    UIViewController *vc=XSETopController();
    if (vc) {
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"ScrollEdge Probe" message:@"Captura concluida e relatorio copiado." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    }
}

static void XSEBeginCapture(void) {
    if (!gCaptureArmed) return;
    gCaptureArmed=NO; gCaptureSerial++; XSEReset(); gCaptureStart=CACurrentMediaTime(); atomic_store(&gCaptureActive,true);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(kXSECaptureDuration*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ XSEFinishCapture(); });
}

@interface XSESettingsViewController : UITableViewController @end
@implementation XSESettingsViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"ScrollEdge Probe"; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 3; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return @"Aguarde 8 s, volte aos comentarios e role continuamente por 15 s. Mede ScrollEdgeEffectView/BackdropView e filtros sem alterar o visual."; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"XSECell"];
    if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"XSECell"];
    if (indexPath.row==0) { cell.textLabel.text=@"Iniciar diagnostico"; cell.detailTextLabel.text=@"8 s de preparo + 15 s de captura"; }
    else if (indexPath.row==1) { cell.textLabel.text=@"Copiar relatorio"; cell.detailTextLabel.text=@"Copia a ultima captura"; }
    else { cell.textLabel.text=@"Limpar relatorio"; cell.detailTextLabel.text=@"Apaga a captura salva"; }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row==0) {
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"ScrollEdge Probe" message:@"Voce tera 8 segundos para voltar aos comentarios. Depois role por 15 segundos." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"Comecar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){ gCaptureArmed=YES; dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(kXSEPrepDelay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ XSEBeginCapture(); }); }]];
        [self presentViewController:a animated:YES completion:nil];
    } else if (indexPath.row==1) {
        NSString *text=gLastReport; if (!text.length) text=[NSString stringWithContentsOfFile:XSEReportPath() encoding:NSUTF8StringEncoding error:nil]; if (text.length) UIPasteboard.generalPasteboard.string=text;
    } else { gLastReport=nil; [[NSFileManager defaultManager] removeItemAtPath:XSEReportPath() error:nil]; }
}
@end

static BOOL XSESectionsContainEntry(NSArray *sections) {
    for (id item in sections) if ([item isKindOfClass:NSDictionary.class] && [item[@"action"] isEqualToString:@"showXLiquidGlassScrollEdgeProbe"]) return YES;
    return NO;
}

static void XSEInjectMenu(id controller) {
    NSArray *sections=nil; @try { sections=[controller valueForKey:@"sections"]; } @catch (__unused NSException *e) { return; }
    if (![sections isKindOfClass:NSArray.class] || XSESectionsContainEntry(sections)) return;
    NSMutableArray *updated=[sections mutableCopy];
    [updated addObject:@{ @"title":@"ScrollEdge Probe", @"subtitle":@"Diagnostico Backdrop/filtros nos comentarios.", @"icon":@"waveform.path.ecg", @"action":@"showXLiquidGlassScrollEdgeProbe" }];
    @try { [controller setValue:[updated copy] forKey:@"sections"]; } @catch (__unused NSException *e) {}
}

static void XSESettingsSetup(id self, SEL cmd) { if (gSettingsSetup) ((void(*)(id,SEL))gSettingsSetup)(self,cmd); XSEInjectMenu(self); }
static void XSESettingsWillAppear(id self, SEL cmd, BOOL animated) { if (gSettingsWillAppear) ((void(*)(id,SEL,BOOL))gSettingsWillAppear)(self,cmd,animated); XSEInjectMenu(self); UITableView *t=nil; @try { t=[self valueForKey:@"tableView"]; } @catch (__unused NSException *e) {} [t reloadData]; }
static void XSEShowProbe(id self, SEL cmd) {
    (void)cmd;
    if (![self isKindOfClass:UIViewController.class]) return;
    UIViewController *vc=(UIViewController *)self; XSESettingsViewController *probe=[XSESettingsViewController new];
    if (vc.navigationController) [vc.navigationController pushViewController:probe animated:YES];
    else [vc presentViewController:[[UINavigationController alloc] initWithRootViewController:probe] animated:YES completion:nil];
}

static void XSEInstallSettingsHooks(void) {
    if (gSettingsHooksInstalled) return;
    Class cls=NSClassFromString(@"ModernSettingsViewController"); if (!cls) return;
    class_addMethod(cls,NSSelectorFromString(@"showXLiquidGlassScrollEdgeProbe"),(IMP)XSEShowProbe,"v@:");
    BOOL a=XSEHook(cls,NSSelectorFromString(@"setupSections"),(IMP)XSESettingsSetup,&gSettingsSetup);
    BOOL b=XSEHook(cls,@selector(viewWillAppear:),(IMP)XSESettingsWillAppear,&gSettingsWillAppear);
    gSettingsHooksInstalled=a||b;
}

static void XSEInstallAll(void) { XSEInstallVisualHooks(); XSEInstallSettingsHooks(); }
static void XSESchedule(NSTimeInterval d) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(d*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ XSEInstallAll(); }); }

__attribute__((constructor))
static void XLiquidGlassCommentsScrollEdgeProbeInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlassCommentsScrollEdgeProbe] %@ loaded",kXSEVersion);
        XSEInstallAll();
        for (NSNumber *d in @[@0.05,@0.20,@0.50,@1.0,@2.0,@4.0,@8.0]) XSESchedule(d.doubleValue);
    }
}
