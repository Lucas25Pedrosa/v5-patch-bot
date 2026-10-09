#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <math.h>

static NSString *const kXCMVersion = @"0.4";
static NSString *const kXCMReportName = @"XLiquidGlassCommentsXColorProbe.txt";
static const NSTimeInterval kXCMPrepDelay = 8.0;
static const NSTimeInterval kXCMCaptureDuration = 15.0;

static IMP gXDSBlurLayout = NULL;
static IMP gXDSBlurNeeds = NULL;
static IMP gXDSGlassLayout = NULL;
static IMP gXDSGlassNeeds = NULL;
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

#pragma mark - Helpers

static NSString *XCMReportPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs.length) docs = NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:kXCMReportName];
}

static NSString *XCMStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:NSDate.date];
}

static NSString *XCMImageForIMP(IMP imp) {
    if (!imp) return @"-";
    Dl_info info = {0};
    if (!dladdr((const void *)imp, &info) || !info.dli_fname) return @"-";
    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
    return path.lastPathComponent ?: path ?: @"-";
}

static NSString *XCMImageForAddress(const void *address) {
    if (!address) return @"-";
    Dl_info info = {0};
    if (!dladdr(address, &info) || !info.dli_fname) return @"-";
    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
    return path.lastPathComponent ?: path ?: @"-";
}

static NSString *XCMRect(CGRect r) {
    return [NSString stringWithFormat:@"{{%.1f,%.1f},{%.1f,%.1f}}", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static NSString *XCMPoint(CGPoint p) {
    return [NSString stringWithFormat:@"{%.1f,%.1f}", p.x, p.y];
}

static UIScrollView *XCMTableAncestor(UIView *view) {
    UIView *cursor = view;
    for (NSUInteger i = 0; cursor && i < 24; i++, cursor = cursor.superview) {
        if ([NSStringFromClass(cursor.class) isEqualToString:@"TFNTableView"] && [cursor isKindOfClass:UIScrollView.class]) {
            return (UIScrollView *)cursor;
        }
    }
    return nil;
}

static BOOL XCMIsCommentsContext(UIView *view) {
    if (!view || !XCMTableAncestor(view)) return NO;
    BOOL hasURT = NO;
    BOOL hasConversation = NO;
    UIResponder *r = view;
    for (NSUInteger i = 0; r && i < 36; i++, r = r.nextResponder) {
        if (![r isKindOfClass:UIViewController.class]) continue;
        NSString *name = NSStringFromClass(r.class);
        if ([name isEqualToString:@"T1URTViewController"]) hasURT = YES;
        if ([name isEqualToString:@"T1ConversationContainerViewController"]) hasConversation = YES;
    }
    return hasURT && hasConversation;
}

static NSString *XCMOwnerChain(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIView *cursor = view;
    for (NSUInteger i = 0; cursor && i < 8; i++, cursor = cursor.superview) {
        [parts addObject:[NSString stringWithFormat:@"%@(%p)", NSStringFromClass(cursor.class), cursor]];
        if ([NSStringFromClass(cursor.class) isEqualToString:@"TFNTableView"]) break;
    }
    return [parts componentsJoinedByString:@" -> "];
}

static NSString *XCMStackSample(void) {
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
        [out appendFormat:@"  %02lu %@!%@+0x%llx\n", (unsigned long)emitted,
         image, symbol, (unsigned long long)(addr - base)];
        emitted++;
    }
    return out.length ? out : @"  - unavailable\n";
}

static uint64_t XCMHashMix(uint64_t h, uint64_t v) {
    h ^= v;
    h *= 1099511628211ULL;
    return h;
}

static uint64_t XCMHashCGFloat(uint64_t h, CGFloat v) {
    union { double d; uint64_t u; } x;
    x.d = (double)v;
    return XCMHashMix(h, x.u);
}

static uint64_t XCMSubviewSignature(UIView *view, NSUInteger *effectCountOut, uint64_t *effectSignatureOut) {
    uint64_t h = 1469598103934665603ULL;
    uint64_t eh = 1469598103934665603ULL;
    NSUInteger effectCount = 0;
    NSUInteger limit = MIN((NSUInteger)24, view.subviews.count);
    for (NSUInteger i = 0; i < limit; i++) {
        UIView *child = view.subviews[i];
        h = XCMHashMix(h, (uintptr_t)(__bridge void *)child);
        h = XCMHashMix(h, (uintptr_t)child.class);
        h = XCMHashCGFloat(h, child.frame.origin.x);
        h = XCMHashCGFloat(h, child.frame.origin.y);
        h = XCMHashCGFloat(h, child.frame.size.width);
        h = XCMHashCGFloat(h, child.frame.size.height);
        h = XCMHashCGFloat(h, child.alpha);
        h = XCMHashMix(h, child.hidden ? 1 : 0);
        if ([child isKindOfClass:UIVisualEffectView.class]) {
            UIVisualEffectView *ev = (UIVisualEffectView *)child;
            effectCount++;
            eh = XCMHashMix(eh, (uintptr_t)(__bridge void *)ev);
            eh = XCMHashMix(eh, (uintptr_t)(__bridge void *)ev.effect);
            eh = XCMHashMix(eh, (uintptr_t)(ev.effect ? ev.effect.class : Nil));
        }
    }
    if (effectCountOut) *effectCountOut = effectCount;
    if (effectSignatureOut) *effectSignatureOut = eh;
    return h;
}

typedef struct {
    CGRect frame;
    CGRect bounds;
    CGAffineTransform transform;
    CGFloat alpha;
    BOOL hidden;
    NSUInteger subviewCount;
    uint64_t subviewSignature;
    NSUInteger effectCount;
    uint64_t effectSignature;
    uintptr_t layerMask;
    NSUInteger sublayerCount;
    CGFloat layerOpacity;
    CGFloat cornerRadius;
    BOOL masksToBounds;
} XCMSnapshot;

static XCMSnapshot XCMSnapshotView(UIView *view) {
    XCMSnapshot s = {0};
    s.frame = view.frame;
    s.bounds = view.bounds;
    s.transform = view.transform;
    s.alpha = view.alpha;
    s.hidden = view.hidden;
    s.subviewCount = view.subviews.count;
    s.subviewSignature = XCMSubviewSignature(view, &s.effectCount, &s.effectSignature);
    CALayer *layer = view.layer;
    s.layerMask = (uintptr_t)(__bridge void *)layer.mask;
    s.sublayerCount = layer.sublayers.count;
    s.layerOpacity = layer.opacity;
    s.cornerRadius = layer.cornerRadius;
    s.masksToBounds = layer.masksToBounds;
    return s;
}

static BOOL XCMTransformEqual(CGAffineTransform a, CGAffineTransform b) {
    return CGAffineTransformEqualToTransform(a, b);
}

static NSMutableDictionary *XCMStatForView(UIView *view) {
    if (!gStats) gStats = [NSMutableDictionary dictionary];
    NSNumber *key = @((uintptr_t)(__bridge void *)view);
    NSMutableDictionary *stat = gStats[key];
    if (!stat) {
        stat = [@{
            @"ptr": key,
            @"class": NSStringFromClass(view.class) ?: @"-",
            @"layout": @0,
            @"needs": @0,
            @"changed": @0,
            @"unchanged": @0,
            @"frameChanged": @0,
            @"boundsChanged": @0,
            @"transformChanged": @0,
            @"visibilityChanged": @0,
            @"subviewsChanged": @0,
            @"effectsChanged": @0,
            @"layerChanged": @0,
            @"totalMs": @0.0,
            @"maxMs": @0.0,
            @"offsetMin": @(DBL_MAX),
            @"offsetMax": @(-DBL_MAX),
            @"dragging": @0,
            @"decelerating": @0,
            @"tracking": @0,
            @"firstContext": @"",
            @"deltaSamples": [NSMutableArray array],
            @"stackSamples": [NSMutableArray array],
            @"needsStacks": [NSMutableArray array]
        } mutableCopy];
        gStats[key] = stat;
    }
    return stat;
}

static NSString *XCMContextSummary(UIView *view) {
    UIScrollView *table = XCMTableAncestor(view);
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"target=%@(%p) frame=%@ bounds=%@\n", NSStringFromClass(view.class), view, XCMRect(view.frame), XCMRect(view.bounds)];
    [s appendFormat:@"ownerChain=%@\n", XCMOwnerChain(view)];
    if (table) {
        [s appendFormat:@"table=%@(%p) offset=%@ size={%.1f,%.1f} dragging=%d decelerating=%d tracking=%d\n",
         NSStringFromClass(table.class), table, XCMPoint(table.contentOffset), table.contentSize.width, table.contentSize.height,
         table.dragging, table.decelerating, table.tracking];
    }
    [s appendString:@"responders:\n"];
    UIResponder *r = view;
    for (NSUInteger i = 0; r && i < 20; i++, r = r.nextResponder) {
        [s appendFormat:@"  %02lu %@(%p)%@\n", (unsigned long)i, NSStringFromClass(r.class), r,
         [r isKindOfClass:UIViewController.class] ? @" <VC>" : @""];
    }
    return s;
}

static NSString *XCMDeltaDescription(XCMSnapshot a, XCMSnapshot b, UIScrollView *table, double ms) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (!CGRectEqualToRect(a.frame, b.frame)) [parts addObject:[NSString stringWithFormat:@"frame %@ -> %@", XCMRect(a.frame), XCMRect(b.frame)]];
    if (!CGRectEqualToRect(a.bounds, b.bounds)) [parts addObject:[NSString stringWithFormat:@"bounds %@ -> %@", XCMRect(a.bounds), XCMRect(b.bounds)]];
    if (!XCMTransformEqual(a.transform, b.transform)) [parts addObject:@"transform changed"];
    if (a.alpha != b.alpha || a.hidden != b.hidden) [parts addObject:[NSString stringWithFormat:@"visibility alpha %.3f->%.3f hidden %d->%d", a.alpha,b.alpha,a.hidden,b.hidden]];
    if (a.subviewCount != b.subviewCount || a.subviewSignature != b.subviewSignature) [parts addObject:[NSString stringWithFormat:@"subviews count %lu->%lu sig %llx->%llx", (unsigned long)a.subviewCount,(unsigned long)b.subviewCount,(unsigned long long)a.subviewSignature,(unsigned long long)b.subviewSignature]];
    if (a.effectCount != b.effectCount || a.effectSignature != b.effectSignature) [parts addObject:[NSString stringWithFormat:@"effects count %lu->%lu sig %llx->%llx", (unsigned long)a.effectCount,(unsigned long)b.effectCount,(unsigned long long)a.effectSignature,(unsigned long long)b.effectSignature]];
    if (a.layerMask != b.layerMask || a.sublayerCount != b.sublayerCount || a.layerOpacity != b.layerOpacity || a.cornerRadius != b.cornerRadius || a.masksToBounds != b.masksToBounds) {
        [parts addObject:[NSString stringWithFormat:@"layer mask %llx->%llx sublayers %lu->%lu opacity %.3f->%.3f corner %.2f->%.2f clips %d->%d",
         (unsigned long long)a.layerMask,(unsigned long long)b.layerMask,(unsigned long)a.sublayerCount,(unsigned long)b.sublayerCount,a.layerOpacity,b.layerOpacity,a.cornerRadius,b.cornerRadius,a.masksToBounds,b.masksToBounds]];
    }
    NSString *offset = table ? XCMPoint(table.contentOffset) : @"-";
    return [NSString stringWithFormat:@"%.3f ms | offset=%@ | %@", ms, offset, parts.count ? [parts componentsJoinedByString:@" | "] : @"NO OBSERVED MUTATION"];
}

#pragma mark - Recording

static void XCMRecordNeeds(UIView *view) {
    if (!atomic_load(&gCaptureActive) || ![NSThread isMainThread]) return;
    if (!XCMIsCommentsContext(view)) { gIgnoredNonConversation++; return; }
    NSMutableDictionary *stat = XCMStatForView(view);
    stat[@"needs"] = @([stat[@"needs"] unsignedLongLongValue] + 1);
    NSMutableArray *samples = stat[@"needsStacks"];
    if (samples.count < 2) [samples addObject:XCMStackSample()];
}

static void XCMRecordLayout(UIView *view, IMP original, SEL cmd) {
    if (!original) return;
    BOOL active = atomic_load(&gCaptureActive) && [NSThread isMainThread];
    BOOL relevant = active && XCMIsCommentsContext(view);
    if (active && !relevant) gIgnoredNonConversation++;

    if (!relevant) {
        ((void(*)(id,SEL))original)(view, cmd);
        return;
    }

    NSMutableDictionary *stat = XCMStatForView(view);
    if (![stat[@"firstContext"] length]) stat[@"firstContext"] = XCMContextSummary(view);

    UIScrollView *table = XCMTableAncestor(view);
    double y = table ? table.contentOffset.y : 0.0;
    double oldMin = [stat[@"offsetMin"] doubleValue];
    double oldMax = [stat[@"offsetMax"] doubleValue];
    stat[@"offsetMin"] = @(MIN(oldMin, y));
    stat[@"offsetMax"] = @(MAX(oldMax, y));
    if (table.dragging) stat[@"dragging"] = @([stat[@"dragging"] unsignedLongLongValue] + 1);
    if (table.decelerating) stat[@"decelerating"] = @([stat[@"decelerating"] unsignedLongLongValue] + 1);
    if (table.tracking) stat[@"tracking"] = @([stat[@"tracking"] unsignedLongLongValue] + 1);

    XCMSnapshot before = XCMSnapshotView(view);
    CFTimeInterval t0 = CACurrentMediaTime();
    ((void(*)(id,SEL))original)(view, cmd);
    double ms = (CACurrentMediaTime() - t0) * 1000.0;
    XCMSnapshot after = XCMSnapshotView(view);

    uint64_t calls = [stat[@"layout"] unsignedLongLongValue] + 1;
    stat[@"layout"] = @(calls);
    double total = [stat[@"totalMs"] doubleValue] + ms;
    stat[@"totalMs"] = @(total);
    stat[@"maxMs"] = @(MAX([stat[@"maxMs"] doubleValue], ms));

    BOOL frame = !CGRectEqualToRect(before.frame, after.frame);
    BOOL bounds = !CGRectEqualToRect(before.bounds, after.bounds);
    BOOL transform = !XCMTransformEqual(before.transform, after.transform);
    BOOL visibility = before.alpha != after.alpha || before.hidden != after.hidden;
    BOOL subviews = before.subviewCount != after.subviewCount || before.subviewSignature != after.subviewSignature;
    BOOL effects = before.effectCount != after.effectCount || before.effectSignature != after.effectSignature;
    BOOL layer = before.layerMask != after.layerMask || before.sublayerCount != after.sublayerCount || before.layerOpacity != after.layerOpacity || before.cornerRadius != after.cornerRadius || before.masksToBounds != after.masksToBounds;
    BOOL changed = frame || bounds || transform || visibility || subviews || effects || layer;

    NSString *(^inc)(NSString *) = ^NSString *(NSString *key) {
        return @([stat[key] unsignedLongLongValue] + 1);
    };
    stat[changed ? @"changed" : @"unchanged"] = inc(changed ? @"changed" : @"unchanged");
    if (frame) stat[@"frameChanged"] = inc(@"frameChanged");
    if (bounds) stat[@"boundsChanged"] = inc(@"boundsChanged");
    if (transform) stat[@"transformChanged"] = inc(@"transformChanged");
    if (visibility) stat[@"visibilityChanged"] = inc(@"visibilityChanged");
    if (subviews) stat[@"subviewsChanged"] = inc(@"subviewsChanged");
    if (effects) stat[@"effectsChanged"] = inc(@"effectsChanged");
    if (layer) stat[@"layerChanged"] = inc(@"layerChanged");

    NSMutableArray *deltas = stat[@"deltaSamples"];
    if ((changed || ms > 0.25) && deltas.count < 10) {
        [deltas addObject:XCMDeltaDescription(before, after, table, ms)];
    }
    NSMutableArray *stacks = stat[@"stackSamples"];
    if ((changed || ms > 0.50) && stacks.count < 3) {
        [stacks addObject:[NSString stringWithFormat:@"sample %lu: %@\n%@", (unsigned long)(stacks.count + 1), XCMDeltaDescription(before, after, table, ms), XCMStackSample()]];
    }
}

static void XCMXDSBlurLayout(id self, SEL cmd) { XCMRecordLayout(self, gXDSBlurLayout, cmd); }
static void XCMXDSBlurNeeds(id self, SEL cmd) { XCMRecordNeeds(self); if (gXDSBlurNeeds) ((void(*)(id,SEL))gXDSBlurNeeds)(self,cmd); }
static void XCMXDSGlassLayout(id self, SEL cmd) { XCMRecordLayout(self, gXDSGlassLayout, cmd); }
static void XCMXDSGlassNeeds(id self, SEL cmd) { XCMRecordNeeds(self); if (gXDSGlassNeeds) ((void(*)(id,SEL))gXDSGlassNeeds)(self,cmd); }

static BOOL XCMHook(Class cls, SEL sel, IMP replacement, IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP current = class_getMethodImplementation(cls, sel);
    if (!current) return NO;
    if (current == replacement) return YES;
    const char *types = method_getTypeEncoding(m);
    if (!types) return NO;
    if (originalOut && !*originalOut) *originalOut = current;
    class_replaceMethod(cls, sel, replacement, types);
    return class_getMethodImplementation(cls, sel) == replacement;
}

static void XCMInstallVisualHooks(void) {
    if (gVisualHooksInstalled) return;
    Class blur = NSClassFromString(@"XDSBlur");
    Class glass = NSClassFromString(@"XDSGlass");
    BOOL installedAny = NO;
    if (blur) {
        IMP l = class_getMethodImplementation(blur, @selector(layoutSubviews));
        IMP n = class_getMethodImplementation(blur, @selector(setNeedsLayout));
        NSLog(@"[XColorProbe] XDSBlur layout owner=%@ needs owner=%@", XCMImageForIMP(l), XCMImageForIMP(n));
        BOOL a = XCMHook(blur, @selector(layoutSubviews), (IMP)XCMXDSBlurLayout, &gXDSBlurLayout);
        BOOL b = XCMHook(blur, @selector(setNeedsLayout), (IMP)XCMXDSBlurNeeds, &gXDSBlurNeeds);
        installedAny = installedAny || a || b;
    }
    if (glass) {
        IMP l = class_getMethodImplementation(glass, @selector(layoutSubviews));
        IMP n = class_getMethodImplementation(glass, @selector(setNeedsLayout));
        NSLog(@"[XColorProbe] XDSGlass layout owner=%@ needs owner=%@", XCMImageForIMP(l), XCMImageForIMP(n));
        BOOL a = XCMHook(glass, @selector(layoutSubviews), (IMP)XCMXDSGlassLayout, &gXDSGlassLayout);
        BOOL b = XCMHook(glass, @selector(setNeedsLayout), (IMP)XCMXDSGlassNeeds, &gXDSGlassNeeds);
        installedAny = installedAny || a || b;
    }
    gVisualHooksInstalled = installedAny;
}

#pragma mark - Report

static NSArray<NSDictionary *> *XCMSortedStats(void) {
    NSArray *values = gStats.allValues ?: @[];
    return [values sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        uint64_t ca = [a[@"layout"] unsignedLongLongValue] + [a[@"needs"] unsignedLongLongValue];
        uint64_t cb = [b[@"layout"] unsignedLongLongValue] + [b[@"needs"] unsignedLongLongValue];
        if (ca > cb) return NSOrderedAscending;
        if (ca < cb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static NSString *XCMBuildReport(double duration) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSMutableString *r = [NSMutableString string];
    [r appendString:@"============================================================\n"];
    [r appendFormat:@"XLiquidGlass Comments XColor Mutation Probe %@ - captura #%lu\n", kXCMVersion, (unsigned long)gCaptureSerial];
    [r appendFormat:@"Data: %@\n", XCMStamp()];
    [r appendFormat:@"App: %@ build %@ | bundle=%@\n", info[@"CFBundleShortVersionString"] ?: @"-", info[@"CFBundleVersion"] ?: @"-", NSBundle.mainBundle.bundleIdentifier ?: @"-"];
    [r appendFormat:@"Duracao real: %.3f s\n", duration];
    [r appendString:@"Probe observacional: hooks apenas XDSBlur/XDSGlass layoutSubviews + setNeedsLayout no contexto de comentarios.\n"];
    [r appendString:@"============================================================\n\n"];
    [r appendFormat:@"non-conversation ignored=%llu | objects=%lu\n\n", (unsigned long long)gIgnoredNonConversation, (unsigned long)gStats.count];

    NSUInteger index = 0;
    for (NSDictionary *s in XCMSortedStats()) {
        index++;
        uint64_t layout = [s[@"layout"] unsignedLongLongValue];
        uint64_t needs = [s[@"needs"] unsignedLongLongValue];
        uint64_t changed = [s[@"changed"] unsignedLongLongValue];
        uint64_t unchanged = [s[@"unchanged"] unsignedLongLongValue];
        double total = [s[@"totalMs"] doubleValue];
        double max = [s[@"maxMs"] doubleValue];
        double minY = [s[@"offsetMin"] doubleValue];
        double maxY = [s[@"offsetMax"] doubleValue];
        if (minY == DBL_MAX) minY = 0;
        if (maxY == -DBL_MAX) maxY = 0;
        [r appendFormat:@"#%lu ptr=0x%llx class=%@\n", (unsigned long)index, [s[@"ptr"] unsignedLongLongValue], s[@"class"]];
        [r appendFormat:@"layout=%llu (%.1f/s) setNeeds=%llu (%.1f/s)\n", (unsigned long long)layout, duration ? layout/duration : 0, (unsigned long long)needs, duration ? needs/duration : 0];
        [r appendFormat:@"layout time total=%.3f ms avg=%.4f ms max=%.3f ms\n", total, layout ? total/layout : 0, max];
        [r appendFormat:@"changed=%llu unchanged=%llu | frame=%llu bounds=%llu transform=%llu visibility=%llu subviews=%llu effects=%llu layer=%llu\n",
         (unsigned long long)changed,(unsigned long long)unchanged,
         [s[@"frameChanged"] unsignedLongLongValue],[s[@"boundsChanged"] unsignedLongLongValue],[s[@"transformChanged"] unsignedLongLongValue],[s[@"visibilityChanged"] unsignedLongLongValue],[s[@"subviewsChanged"] unsignedLongLongValue],[s[@"effectsChanged"] unsignedLongLongValue],[s[@"layerChanged"] unsignedLongLongValue]];
        [r appendFormat:@"table offset range y=%.1f..%.1f | dragging layouts=%llu decelerating=%llu tracking=%llu\n",
         minY,maxY,[s[@"dragging"] unsignedLongLongValue],[s[@"decelerating"] unsignedLongLongValue],[s[@"tracking"] unsignedLongLongValue]];
        [r appendFormat:@"context:\n%@\n", s[@"firstContext"]];

        NSArray *deltas = s[@"deltaSamples"];
        [r appendString:@"delta samples:\n"];
        if (!deltas.count) [r appendString:@"  - none\n"];
        for (NSString *d in deltas) [r appendFormat:@"  %@\n", d];

        NSArray *stacks = s[@"stackSamples"];
        [r appendString:@"layout stack samples:\n"];
        if (!stacks.count) [r appendString:@"  - none\n"];
        for (NSString *sample in stacks) [r appendFormat:@"%@\n", sample];

        NSArray *needsStacks = s[@"needsStacks"];
        [r appendString:@"setNeedsLayout stack samples:\n"];
        if (!needsStacks.count) [r appendString:@"  - none\n"];
        NSUInteger n = 0;
        for (NSString *sample in needsStacks) [r appendFormat:@"needs sample %lu:\n%@\n", (unsigned long)++n, sample];
        [r appendString:@"\n"];
    }

    uint64_t totalLayout=0,totalNeeds=0,totalChanged=0,totalUnchanged=0;
    double totalMs=0,maxMs=0;
    for (NSDictionary *s in gStats.allValues) {
        totalLayout += [s[@"layout"] unsignedLongLongValue];
        totalNeeds += [s[@"needs"] unsignedLongLongValue];
        totalChanged += [s[@"changed"] unsignedLongLongValue];
        totalUnchanged += [s[@"unchanged"] unsignedLongLongValue];
        totalMs += [s[@"totalMs"] doubleValue];
        maxMs = MAX(maxMs,[s[@"maxMs"] doubleValue]);
    }
    [r appendString:@"[RESUMO]\n"];
    [r appendFormat:@"layout total=%llu (%.1f/s) setNeeds total=%llu (%.1f/s)\n", (unsigned long long)totalLayout,duration?totalLayout/duration:0,(unsigned long long)totalNeeds,duration?totalNeeds/duration:0];
    [r appendFormat:@"layout changed=%llu unchanged=%llu | mutation ratio=%.1f%%\n",(unsigned long long)totalChanged,(unsigned long long)totalUnchanged,totalLayout?100.0*totalChanged/totalLayout:0];
    [r appendFormat:@"layout execution total=%.3f ms avg=%.4f ms max=%.3f ms\n",totalMs,totalLayout?totalMs/totalLayout:0,maxMs];
    if (totalLayout && totalChanged == 0) [r appendString:@"SINAL: XDSBlur/XDSGlass estao sendo recalculados sem mutacao observavel apos layout.\n"];
    else if (totalLayout && totalChanged * 2 < totalLayout) [r appendString:@"SINAL: maioria dos layouts nao altera estado observavel; ha forte churn redundante.\n"];
    else if (totalLayout) [r appendString:@"SINAL: grande parte dos layouts altera estado visual; use delta/stacks para identificar o campo mutado.\n"];
    [r appendString:@"\n[FIM DA CAPTURA]\n============================================================\n"];
    return r;
}

static void XCMReset(void) {
    gStats = [NSMutableDictionary dictionary];
    gIgnoredNonConversation = 0;
}

static UIViewController *XCMTopController(void) {
    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    if (!window) {
        for (UIWindow *w in UIApplication.sharedApplication.windows) if (w.isKeyWindow) { window = w; break; }
    }
    UIViewController *vc = window.rootViewController;
    while (YES) {
        UIViewController *next = nil;
        if (vc.presentedViewController) next = vc.presentedViewController;
        else if ([vc isKindOfClass:UINavigationController.class]) next = ((UINavigationController *)vc).topViewController;
        else if ([vc isKindOfClass:UITabBarController.class]) next = ((UITabBarController *)vc).selectedViewController;
        if (!next || next == vc) break;
        vc = next;
    }
    return vc;
}

static void XCMFinishCapture(void) {
    if (!atomic_exchange(&gCaptureActive, false)) return;
    double duration = CACurrentMediaTime() - gCaptureStart;
    gLastReport = XCMBuildReport(duration);
    [gLastReport writeToFile:XCMReportPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    UIPasteboard.generalPasteboard.string = gLastReport;
    UIViewController *vc = XCMTopController();
    if (vc) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"XColor Probe" message:@"Captura concluida e relatorio copiado." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    }
}

static void XCMBeginCapture(void) {
    if (!gCaptureArmed) return;
    gCaptureArmed = NO;
    gCaptureSerial++;
    XCMReset();
    gCaptureStart = CACurrentMediaTime();
    atomic_store(&gCaptureActive, true);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(kXCMCaptureDuration*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ XCMFinishCapture(); });
}

#pragma mark - Settings UI

@interface XCMSettingsViewController : UITableViewController
@end

@implementation XCMSettingsViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"XColor Probe"; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 3; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return @"Aguarde 8 s, volte aos comentarios e role continuamente por 15 s. Mede XDSBlur/XDSGlass sem alterar o visual."; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"XCMCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"XCMCell"];
    if (indexPath.row == 0) { cell.textLabel.text=@"Iniciar diagnostico"; cell.detailTextLabel.text=@"8 s de preparo + 15 s de captura"; }
    else if (indexPath.row == 1) { cell.textLabel.text=@"Copiar relatorio"; cell.detailTextLabel.text=@"Copia a ultima captura"; }
    else { cell.textLabel.text=@"Limpar relatorio"; cell.detailTextLabel.text=@"Apaga a captura salva"; }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 0) {
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"XColor Probe" message:@"Voce tera 8 segundos para voltar aos comentarios. Depois role por 15 segundos." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"Comecar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
            gCaptureArmed=YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(kXCMPrepDelay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ XCMBeginCapture(); });
        }]];
        [self presentViewController:a animated:YES completion:nil];
    } else if (indexPath.row == 1) {
        NSString *text=gLastReport;
        if (!text.length) text=[NSString stringWithContentsOfFile:XCMReportPath() encoding:NSUTF8StringEncoding error:nil];
        if (text.length) UIPasteboard.generalPasteboard.string=text;
    } else {
        gLastReport=nil;
        [[NSFileManager defaultManager] removeItemAtPath:XCMReportPath() error:nil];
    }
}
@end

static BOOL XCMSectionsContainEntry(NSArray *sections) {
    for (id item in sections) if ([item isKindOfClass:NSDictionary.class] && [item[@"action"] isEqualToString:@"showXLiquidGlassXColorProbe"]) return YES;
    return NO;
}

static void XCMInjectMenu(id controller) {
    NSArray *sections=nil;
    @try { sections=[controller valueForKey:@"sections"]; } @catch (__unused NSException *e) { return; }
    if (![sections isKindOfClass:NSArray.class] || XCMSectionsContainEntry(sections)) return;
    NSMutableArray *updated=[sections mutableCopy];
    [updated addObject:@{ @"title":@"XColor Probe", @"subtitle":@"Diagnostico XDSBlur/XDSGlass nos comentarios.", @"icon":@"waveform.path.ecg", @"action":@"showXLiquidGlassXColorProbe" }];
    @try { [controller setValue:[updated copy] forKey:@"sections"]; } @catch (__unused NSException *e) {}
}

static void XCMSettingsSetup(id self, SEL cmd) { if (gSettingsSetup) ((void(*)(id,SEL))gSettingsSetup)(self,cmd); XCMInjectMenu(self); }
static void XCMSettingsWillAppear(id self, SEL cmd, BOOL animated) { if (gSettingsWillAppear) ((void(*)(id,SEL,BOOL))gSettingsWillAppear)(self,cmd,animated); XCMInjectMenu(self); UITableView *t=nil; @try { t=[self valueForKey:@"tableView"]; } @catch (__unused NSException *e) {} [t reloadData]; }
static void XCMShowProbe(id self, SEL cmd) {
    if (![self isKindOfClass:UIViewController.class]) return;
    UIViewController *vc=(UIViewController *)self;
    XCMSettingsViewController *probe=[XCMSettingsViewController new];
    if (vc.navigationController) [vc.navigationController pushViewController:probe animated:YES];
    else [vc presentViewController:[[UINavigationController alloc] initWithRootViewController:probe] animated:YES completion:nil];
}

static void XCMInstallSettingsHooks(void) {
    if (gSettingsHooksInstalled) return;
    Class cls=NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;
    class_addMethod(cls,NSSelectorFromString(@"showXLiquidGlassXColorProbe"),(IMP)XCMShowProbe,"v@:");
    BOOL a=XCMHook(cls,NSSelectorFromString(@"setupSections"),(IMP)XCMSettingsSetup,&gSettingsSetup);
    BOOL b=XCMHook(cls,@selector(viewWillAppear:),(IMP)XCMSettingsWillAppear,&gSettingsWillAppear);
    gSettingsHooksInstalled=a||b;
}

static void XCMInstallAll(void) { XCMInstallVisualHooks(); XCMInstallSettingsHooks(); }
static void XCMSchedule(NSTimeInterval delay) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ XCMInstallAll(); }); }

__attribute__((constructor))
static void XLiquidGlassCommentsXColorProbeInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlassCommentsXColorProbe] %@ loaded",kXCMVersion);
        XCMInstallAll();
        for (NSNumber *d in @[@0.05,@0.20,@0.50,@1.0,@2.0,@4.0,@8.0]) XCMSchedule(d.doubleValue);
    }
}
