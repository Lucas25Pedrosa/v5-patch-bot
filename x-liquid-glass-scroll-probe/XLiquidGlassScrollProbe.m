#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <math.h>
#import <stdio.h>
#import <string.h>

static NSString *const kXSPLogFileName = @"XLiquidGlassScrollProbe.txt";
static const NSTimeInterval kXSPPreparationDelay = 8.0;
static const NSTimeInterval kXSPCaptureDuration = 15.0;
static const NSUInteger kXSPMaxLogBytes = 2 * 1024 * 1024;

typedef NS_ENUM(uint8_t, XSPHookKind) {
    XSPHookKindLayout = 1,
    XSPHookKindNeedsLayout = 2,
    XSPHookKindDidMove = 3,
    XSPHookKindEffect = 4,
};

typedef struct {
    uintptr_t clsPtr;
    SEL selector;
    IMP original;
    XSPHookKind kind;
    char className[160];
    char originalImage[320];

    _Atomic(uint64_t) calls;
    _Atomic(uint64_t) totalTicks;
    _Atomic(uint64_t) maxTicks;

    bool stackCaptured;
    int stackCount;
    void *stack[14];
} XSPHookRecord;

#define XSP_MAX_HOOKS 96
static XSPHookRecord gHooks[XSP_MAX_HOOKS];
static size_t gHookCount = 0;

typedef struct {
    uintptr_t objectPtr;
    uint16_t hookIndex;
    uint64_t calls;
} XSPObjectStat;

#define XSP_OBJECT_TABLE_SIZE 2048
static XSPObjectStat gObjectStats[XSP_OBJECT_TABLE_SIZE];

static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;
static BOOL gNFBHookInstalled = NO;

static _Atomic(bool) gCaptureActive = false;
static BOOL gCaptureArmed = NO;
static NSUInteger gCaptureSerial = 0;
static NSUInteger gCaptureCount = 0;

static CADisplayLink *gDisplayLink = nil;
static id gDisplayLinkTarget = nil;
static CFTimeInterval gCaptureStartTime = 0;
static CFTimeInterval gLastFrameTimestamp = 0;

static uint64_t gFrameIntervals = 0;
static uint64_t gSlowDynamic = 0;
static uint64_t gOver16ms = 0;
static uint64_t gOver33ms = 0;
static uint64_t gEstimatedDropped = 0;
static double gObservedFrameSeconds = 0.0;
static double gExpectedFrameSeconds = 0.0;

static mach_timebase_info_data_t gTimebase;
static int gRemainingStackSamples = 8;

#pragma mark - Paths / report I/O

static NSString *XSPLogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kXSPLogFileName];
}

static NSString *XSPStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:NSDate.date];
}

static void XSPTrimLogIfNeeded(void) {
    NSString *path = XSPLogPath();
    NSDictionary *attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size <= kXSPMaxLogBytes) return;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length <= kXSPMaxLogBytes) return;

    NSUInteger keep = kXSPMaxLogBytes / 2;
    NSData *tail =
        [data subdataWithRange:NSMakeRange(data.length - keep, keep)];
    [tail writeToFile:path atomically:YES];
}

static void XSPAppendReport(NSString *report) {
    if (!report.length) return;

    NSString *path = XSPLogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [@"" writeToFile:path
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;

    [handle seekToEndOfFile];
    [handle writeData:[report dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];

    XSPTrimLogIfNeeded();
}

#pragma mark - Time / image helpers

static double XSPTicksToMilliseconds(uint64_t ticks) {
    if (gTimebase.denom == 0) mach_timebase_info(&gTimebase);
    long double nanos =
        ((long double)ticks * (long double)gTimebase.numer) /
        (long double)gTimebase.denom;
    return (double)(nanos / 1000000.0L);
}

static NSString *XSPImageForIMP(IMP imp) {
    if (!imp) return @"-";
    Dl_info info = {0};
    if (!dladdr((const void *)imp, &info) || !info.dli_fname) return @"-";
    return [NSString stringWithUTF8String:info.dli_fname] ?: @"-";
}

static NSString *XSPShortImage(NSString *path) {
    if (!path.length || [path isEqualToString:@"-"]) return @"-";
    return path.lastPathComponent.length ? path.lastPathComponent : path;
}

static NSString *XSPSymbolForAddress(void *address) {
    Dl_info info = {0};
    if (!address || !dladdr(address, &info)) {
        return [NSString stringWithFormat:@"%p", address];
    }

    NSString *image = info.dli_fname
        ? [NSString stringWithUTF8String:info.dli_fname].lastPathComponent
        : @"?";
    NSString *symbol = info.dli_sname
        ? [NSString stringWithUTF8String:info.dli_sname]
        : @"?";

    uintptr_t offset = 0;
    if (info.dli_saddr) {
        offset = (uintptr_t)address - (uintptr_t)info.dli_saddr;
    }

    return [NSString stringWithFormat:@"%@!%@+0x%lx",
            image ?: @"?",
            symbol ?: @"?",
            (unsigned long)offset];
}

static BOOL XSPImageLooksRelevant(NSString *path) {
    NSString *lower = path.lowercaseString;
    return [lower containsString:@"xliquidglass"] ||
           [lower containsString:@"orionblur"] ||
           [lower containsString:@"neofreebird"] ||
           [lower containsString:@"bhtwitter"];
}

#pragma mark - Hook bookkeeping

static XSPHookRecord *XSPRecordForClassSelector(Class cls, SEL selector) {
    uintptr_t clsPtr = (uintptr_t)(__bridge void *)cls;
    for (size_t i = 0; i < gHookCount; i++) {
        if (gHooks[i].clsPtr == clsPtr && gHooks[i].selector == selector) {
            return &gHooks[i];
        }
    }
    return NULL;
}

static XSPHookRecord *XSPRecordForObjectSelector(id object, SEL selector) {
    if (!object || !selector) return NULL;

    for (Class cls = object_getClass(object);
         cls != Nil;
         cls = class_getSuperclass(cls)) {
        XSPHookRecord *record = XSPRecordForClassSelector(cls, selector);
        if (record) return record;
    }
    return NULL;
}

static void XSPAtomicMax(_Atomic(uint64_t) *slot, uint64_t value) {
    uint64_t current = atomic_load(slot);
    while (value > current &&
           !atomic_compare_exchange_weak(slot, &current, value)) {
    }
}

static void XSPHitObject(id object, XSPHookRecord *record) {
    if (!object || !record || ![NSThread isMainThread]) return;

    size_t hookIndex = (size_t)(record - gHooks);
    uintptr_t ptr = (uintptr_t)(__bridge void *)object;
    uintptr_t mixed = (ptr >> 4) ^
                      ((uintptr_t)(hookIndex + 1) * 11400714819323198485ull);
    size_t start = (size_t)(mixed % XSP_OBJECT_TABLE_SIZE);

    for (size_t step = 0; step < 24; step++) {
        size_t index = (start + step) % XSP_OBJECT_TABLE_SIZE;
        XSPObjectStat *slot = &gObjectStats[index];

        if (slot->objectPtr == 0) {
            slot->objectPtr = ptr;
            slot->hookIndex = (uint16_t)hookIndex;
            slot->calls = 1;
            return;
        }

        if (slot->objectPtr == ptr && slot->hookIndex == hookIndex) {
            slot->calls++;
            return;
        }
    }
}

static void XSPCaptureStackOnce(XSPHookRecord *record) {
    if (!record || record->stackCaptured || ![NSThread isMainThread]) return;
    if (gRemainingStackSamples <= 0) return;
    gRemainingStackSamples--;
    record->stackCaptured = true;
    record->stackCount = backtrace(record->stack, 14);
}

static void XSPRecordCall(id object,
                          XSPHookRecord *record,
                          uint64_t elapsedTicks) {
    if (!record || !atomic_load(&gCaptureActive)) return;

    atomic_fetch_add(&record->calls, 1);
    atomic_fetch_add(&record->totalTicks, elapsedTicks);
    XSPAtomicMax(&record->maxTicks, elapsedTicks);

    XSPCaptureStackOnce(record);
    XSPHitObject(object, record);
}

static void XSPVoidHook(id self, SEL cmd) {
    XSPHookRecord *record = XSPRecordForObjectSelector(self, cmd);
    IMP original = record ? record->original : NULL;

    if (!atomic_load(&gCaptureActive)) {
        if (original) ((void(*)(id,SEL))original)(self, cmd);
        return;
    }

    uint64_t begin = mach_absolute_time();
    if (original) ((void(*)(id,SEL))original)(self, cmd);
    uint64_t end = mach_absolute_time();

    XSPRecordCall(self, record, end - begin);
}

static void XSPEffectHook(UIVisualEffectView *self,
                          SEL cmd,
                          UIVisualEffect *effect) {
    XSPHookRecord *record = XSPRecordForObjectSelector(self, cmd);
    IMP original = record ? record->original : NULL;

    if (!atomic_load(&gCaptureActive)) {
        if (original) ((void(*)(id,SEL,id))original)(self, cmd, effect);
        return;
    }

    uint64_t begin = mach_absolute_time();
    if (original) ((void(*)(id,SEL,id))original)(self, cmd, effect);
    uint64_t end = mach_absolute_time();

    XSPRecordCall(self, record, end - begin);
}

static BOOL XSPInstallHook(Class cls,
                           SEL selector,
                           IMP replacement,
                           XSPHookKind kind) {
    if (!cls || !selector || !replacement) return NO;

    XSPHookRecord *existing = XSPRecordForClassSelector(cls, selector);
    if (existing) return YES;

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;

    IMP current = class_getMethodImplementation(cls, selector);
    if (!current || current == replacement) return current == replacement;
    if (gHookCount >= XSP_MAX_HOOKS) return NO;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    XSPHookRecord *record = &gHooks[gHookCount];
    memset(record, 0, sizeof(*record));

    record->clsPtr = (uintptr_t)(__bridge void *)cls;
    record->selector = selector;
    record->original = current;
    record->kind = kind;

    NSString *className = NSStringFromClass(cls) ?: @"?";
    NSString *image = XSPImageForIMP(current);

    snprintf(record->className,
             sizeof(record->className),
             "%s",
             className.UTF8String ?: "?");
    snprintf(record->originalImage,
             sizeof(record->originalImage),
             "%s",
             image.UTF8String ?: "-");

    class_replaceMethod(cls, selector, replacement, types);
    if (class_getMethodImplementation(cls, selector) != replacement) {
        memset(record, 0, sizeof(*record));
        return NO;
    }

    gHookCount++;
    return YES;
}

#pragma mark - Target class discovery

static BOOL XSPClassIsUIViewSubclass(Class cls) {
    for (Class current = cls; current != Nil; current = class_getSuperclass(current)) {
        if (current == UIView.class) return YES;
    }
    return NO;
}

static BOOL XSPIsSuspectClassName(NSString *name) {
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"xdsblur"] ||
           [lower containsString:@"xdsglass"] ||
           [lower containsString:@"scrolledge"] ||
           [lower containsString:@"liquidlens"] ||
           [lower containsString:@"clearglassview"];
}

static NSArray<Class> *XSPSuspectClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return @[];

    Class *classes =
        (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);

    NSMutableArray<Class> *result = [NSMutableArray array];

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls);
        if (!name.length) continue;
        if (!XSPIsSuspectClassName(name)) continue;
        if (!XSPClassIsUIViewSubclass(cls)) continue;
        [result addObject:cls];
    }

    free(classes);

    [result sortUsingComparator:^NSComparisonResult(Class a, Class b) {
        return [NSStringFromClass(a) compare:NSStringFromClass(b)];
    }];

    return result;
}

static void XSPInstallPerformanceHooks(void) {
    XSPInstallHook(UIVisualEffectView.class,
                   @selector(setEffect:),
                   (IMP)XSPEffectHook,
                   XSPHookKindEffect);

    for (Class cls in XSPSuspectClasses()) {
        XSPInstallHook(cls,
                       @selector(layoutSubviews),
                       (IMP)XSPVoidHook,
                       XSPHookKindLayout);

        XSPInstallHook(cls,
                       @selector(setNeedsLayout),
                       (IMP)XSPVoidHook,
                       XSPHookKindNeedsLayout);

        XSPInstallHook(cls,
                       @selector(didMoveToWindow),
                       (IMP)XSPVoidHook,
                       XSPHookKindDidMove);
    }
}

#pragma mark - Frame monitor

@interface XSPDisplayLinkTarget : NSObject
- (void)tick:(CADisplayLink *)link;
@end

@implementation XSPDisplayLinkTarget

- (void)tick:(CADisplayLink *)link {
    if (!atomic_load(&gCaptureActive)) return;

    CFTimeInterval now = link.timestamp;
    if (gLastFrameTimestamp > 0) {
        double observed = now - gLastFrameTimestamp;
        double expected = link.targetTimestamp - link.timestamp;

        if (expected <= 0.0 || expected > 0.050) {
            NSInteger maxFPS = UIScreen.mainScreen.maximumFramesPerSecond;
            expected = 1.0 / (double)MAX(maxFPS, 60);
        }

        gFrameIntervals++;
        gObservedFrameSeconds += observed;
        gExpectedFrameSeconds += expected;

        if (observed > expected * 1.50) gSlowDynamic++;
        if (observed > (1.0 / 60.0) * 1.05) gOver16ms++;
        if (observed > (1.0 / 30.0) * 1.05) gOver33ms++;

        if (expected > 0.0 && observed > expected * 1.50) {
            long dropped = lround(observed / expected) - 1;
            if (dropped > 0) gEstimatedDropped += (uint64_t)dropped;
        }
    }

    gLastFrameTimestamp = now;
}

@end

#pragma mark - Runtime inventory

static void XSPAppendLoadedImages(NSMutableString *report) {
    [report appendString:@"\n[IMAGENS RELEVANTES CARREGADAS]\n"];

    uint32_t count = _dyld_image_count();
    BOOL any = NO;

    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;

        NSString *path = [NSString stringWithUTF8String:name];
        if (!XSPImageLooksRelevant(path)) continue;

        any = YES;
        [report appendFormat:@"- %@\n", path];
    }

    if (!any) [report appendString:@"- nenhuma imagem alvo encontrada\n"];
}

static void XSPAppendHookInventory(NSMutableString *report) {
    [report appendString:@"\n[HOOKS INSTALADOS / OWNER ORIGINAL]\n"];

    if (gHookCount == 0) {
        [report appendString:@"- nenhum hook instalado\n"];
        return;
    }

    for (size_t i = 0; i < gHookCount; i++) {
        XSPHookRecord *record = &gHooks[i];
        NSString *image = [NSString stringWithUTF8String:record->originalImage] ?: @"-";

        [report appendFormat:
            @"[%zu] %@ %@ owner=%@\n",
            i,
            [NSString stringWithUTF8String:record->className] ?: @"?",
            NSStringFromSelector(record->selector),
            XSPShortImage(image)];
    }
}

static void XSPAppendStacks(NSMutableString *report) {
    [report appendString:@"\n[AMOSTRAS DE PILHA - PRIMEIRA CHAMADA DURANTE A ROLAGEM]\n"];

    for (size_t i = 0; i < gHookCount; i++) {
        XSPHookRecord *record = &gHooks[i];
        uint64_t calls = atomic_load(&record->calls);
        if (calls == 0 || record->stackCount <= 0) continue;

        [report appendFormat:@"\n#%zu %@ %@ calls=%llu\n",
         i,
         [NSString stringWithUTF8String:record->className] ?: @"?",
         NSStringFromSelector(record->selector),
         (unsigned long long)calls];

        int limit = MIN(record->stackCount, 10);
        for (int f = 0; f < limit; f++) {
            [report appendFormat:@"  %02d %@\n",
             f,
             XSPSymbolForAddress(record->stack[f])];
        }
    }
}

#pragma mark - Stats reset / ranking

static void XSPResetCaptureStats(void) {
    for (size_t i = 0; i < gHookCount; i++) {
        atomic_store(&gHooks[i].calls, 0);
        atomic_store(&gHooks[i].totalTicks, 0);
        atomic_store(&gHooks[i].maxTicks, 0);
        gHooks[i].stackCaptured = false;
        gHooks[i].stackCount = 0;
        memset(gHooks[i].stack, 0, sizeof(gHooks[i].stack));
    }

    memset(gObjectStats, 0, sizeof(gObjectStats));

    gFrameIntervals = 0;
    gSlowDynamic = 0;
    gOver16ms = 0;
    gOver33ms = 0;
    gEstimatedDropped = 0;
    gObservedFrameSeconds = 0.0;
    gExpectedFrameSeconds = 0.0;
    gLastFrameTimestamp = 0.0;
    gRemainingStackSamples = 8;
}

static NSString *XSPHookLabel(XSPHookRecord *record) {
    if (!record) return @"-";
    NSString *className =
        [NSString stringWithUTF8String:record->className] ?: @"?";
    return [NSString stringWithFormat:@"%@ %@",
            className,
            NSStringFromSelector(record->selector)];
}

static void XSPAppendTopObjects(NSMutableString *report) {
    [report appendString:@"\n[OBJETOS MAIS REPROCESSADOS]\n"];

    XSPObjectStat top[10];
    memset(top, 0, sizeof(top));

    for (size_t i = 0; i < XSP_OBJECT_TABLE_SIZE; i++) {
        XSPObjectStat candidate = gObjectStats[i];
        if (candidate.objectPtr == 0 || candidate.calls == 0) continue;

        for (size_t j = 0; j < 10; j++) {
            if (candidate.calls > top[j].calls) {
                for (size_t k = 9; k > j; k--) top[k] = top[k - 1];
                top[j] = candidate;
                break;
            }
        }
    }

    BOOL any = NO;
    for (size_t i = 0; i < 10; i++) {
        if (top[i].calls == 0 || top[i].hookIndex >= gHookCount) continue;
        any = YES;

        XSPHookRecord *record = &gHooks[top[i].hookIndex];
        [report appendFormat:
            @"%zu. ptr=0x%llx calls=%llu hook=%@\n",
            i + 1,
            (unsigned long long)top[i].objectPtr,
            (unsigned long long)top[i].calls,
            XSPHookLabel(record)];
    }

    if (!any) [report appendString:@"- nenhum objeto repetido capturado\n"];
}

#pragma mark - Automatic verdict

typedef NS_ENUM(NSInteger, XSPVerdictType) {
    XSPVerdictNone = 0,
    XSPVerdictEffect,
    XSPVerdictLayout,
    XSPVerdictNeedsLayout,
    XSPVerdictViewChurn,
};

static void XSPAppendVerdict(NSMutableString *report, double duration) {
    double effectRate = 0.0;
    double layoutRate = 0.0;
    double needsRate = 0.0;
    double moveRate = 0.0;

    XSPHookRecord *heaviest = NULL;
    double heaviestMs = 0.0;
    BOOL heaviestOwnedByXLG = NO;

    for (size_t i = 0; i < gHookCount; i++) {
        XSPHookRecord *record = &gHooks[i];
        uint64_t calls = atomic_load(&record->calls);
        double rate = duration > 0.0 ? (double)calls / duration : 0.0;
        double totalMs = XSPTicksToMilliseconds(atomic_load(&record->totalTicks));

        if (record->kind == XSPHookKindEffect) effectRate += rate;
        if (record->kind == XSPHookKindLayout) layoutRate += rate;
        if (record->kind == XSPHookKindNeedsLayout) needsRate += rate;
        if (record->kind == XSPHookKindDidMove) moveRate += rate;

        if (totalMs > heaviestMs) {
            heaviestMs = totalMs;
            heaviest = record;
            NSString *image =
                [NSString stringWithUTF8String:record->originalImage] ?: @"";
            heaviestOwnedByXLG =
                [image.lowercaseString containsString:@"xliquidglass"];
        }
    }

    double slowRatio = gFrameIntervals
        ? ((double)gSlowDynamic / (double)gFrameIntervals)
        : 0.0;

    XSPVerdictType verdict = XSPVerdictNone;
    double bestScore = 0.0;

    double effectScore = effectRate / 20.0;
    double layoutScore = layoutRate / 80.0;
    double needsScore = needsRate / 160.0;
    double moveScore = moveRate / 8.0;

    if (effectScore > bestScore) {
        bestScore = effectScore;
        verdict = XSPVerdictEffect;
    }
    if (layoutScore > bestScore) {
        bestScore = layoutScore;
        verdict = XSPVerdictLayout;
    }
    if (needsScore > bestScore) {
        bestScore = needsScore;
        verdict = XSPVerdictNeedsLayout;
    }
    if (moveScore > bestScore) {
        bestScore = moveScore;
        verdict = XSPVerdictViewChurn;
    }

    [report appendString:@"\n[DIAGNOSTICO AUTOMATICO]\n"];

    NSString *severity = @"BAIXA";
    if (bestScore >= 2.0 || slowRatio >= 0.20) severity = @"ALTA";
    else if (bestScore >= 1.0 || slowRatio >= 0.08) severity = @"MEDIA";

    switch (verdict) {
        case XSPVerdictEffect:
            [report appendFormat:
                @"PRINCIPAL: churn de UIVisualEffectView/setEffect: (%@)\n"
                 "EVIDENCIA: %.1f chamadas/s durante a captura.\n",
                 severity, effectRate];
            break;

        case XSPVerdictLayout:
            [report appendFormat:
                @"PRINCIPAL: layout excessivo nas superficies Glass/Blur (%@)\n"
                 "EVIDENCIA: %.1f layoutSubviews/s nas classes alvo.\n",
                 severity, layoutRate];
            break;

        case XSPVerdictNeedsLayout:
            [report appendFormat:
                @"PRINCIPAL: invalidacao continua de layout (%@)\n"
                 "EVIDENCIA: %.1f setNeedsLayout/s nas classes alvo.\n",
                 severity, needsRate];
            break;

        case XSPVerdictViewChurn:
            [report appendFormat:
                @"PRINCIPAL: recriacao/reinsercao de superficies Glass (%@)\n"
                 "EVIDENCIA: %.1f didMoveToWindow/s nas classes alvo.\n",
                 severity, moveRate];
            break;

        default:
            [report appendString:
                @"PRINCIPAL: nenhum churn CPU obvio foi identificado.\n"
                 "HIPOTESE: custo de composicao/renderizacao GPU ou outro caminho fora dos hooks observados.\n"];
            break;
    }

    [report appendFormat:
        @"FRAMES: %.1f%% dos intervalos excederam 1.5x o periodo esperado; drops estimados=%llu.\n",
        slowRatio * 100.0,
        (unsigned long long)gEstimatedDropped];

    if (heaviest) {
        NSString *image =
            [NSString stringWithUTF8String:heaviest->originalImage] ?: @"-";
        [report appendFormat:
            @"HOOK MAIS CARO: %@ | %.2f ms acumulados | owner=%@\n",
            XSPHookLabel(heaviest),
            heaviestMs,
            XSPShortImage(image)];

        if (heaviestOwnedByXLG) {
            [report appendString:
                @"VINCULO FORTE: o IMP anterior do hook mais caro pertence ao XLiquidGlass.dylib.\n"];
        }
    }

    [report appendFormat:
        @"TAXAS: setEffect=%.1f/s layout=%.1f/s setNeedsLayout=%.1f/s didMoveToWindow=%.1f/s\n",
        effectRate, layoutRate, needsRate, moveRate];
}

#pragma mark - Report builder

static NSString *XSPBuildReport(double duration) {
    NSMutableString *report = [NSMutableString string];

    NSBundle *bundle = NSBundle.mainBundle;
    NSString *version =
        [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *build =
        [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";

    [report appendFormat:
        @"\n============================================================\n"
         "XLiquidGlass Scroll Probe - captura #%lu\n"
         "Data: %@\n"
         "App: %@ build %@ | bundle=%@\n"
         "Duracao real: %.3f s | tela maxFPS=%ld\n"
         "Probe: somente diagnostico; nao altera blur, glass, layout ou tema.\n"
         "============================================================\n",
         (unsigned long)gCaptureCount,
         XSPStamp(),
         version,
         build,
         bundle.bundleIdentifier ?: @"?",
         duration,
         (long)UIScreen.mainScreen.maximumFramesPerSecond];

    double measuredFPS = gObservedFrameSeconds > 0.0
        ? (double)gFrameIntervals / gObservedFrameSeconds
        : 0.0;
    double expectedFPS = gExpectedFrameSeconds > 0.0
        ? (double)gFrameIntervals / gExpectedFrameSeconds
        : 0.0;

    [report appendString:@"\n[FRAME PERFORMANCE]\n"];
    [report appendFormat:@"intervalos=%llu\n",
     (unsigned long long)gFrameIntervals];
    [report appendFormat:@"fps observado=%.2f | fps esperado medio=%.2f\n",
     measuredFPS, expectedFPS];
    [report appendFormat:@"intervalos >1.5x esperado=%llu\n",
     (unsigned long long)gSlowDynamic];
    [report appendFormat:@"intervalos >~16.7ms=%llu | >~33.3ms=%llu\n",
     (unsigned long long)gOver16ms,
     (unsigned long long)gOver33ms];
    [report appendFormat:@"drops estimados=%llu\n",
     (unsigned long long)gEstimatedDropped];

    [report appendString:@"\n[HOT HOOKS]\n"];

    BOOL any = NO;
    for (size_t i = 0; i < gHookCount; i++) {
        XSPHookRecord *record = &gHooks[i];
        uint64_t calls = atomic_load(&record->calls);
        if (calls == 0) continue;
        any = YES;

        double totalMs =
            XSPTicksToMilliseconds(atomic_load(&record->totalTicks));
        double maxMs =
            XSPTicksToMilliseconds(atomic_load(&record->maxTicks));
        double rate = duration > 0.0 ? (double)calls / duration : 0.0;
        NSString *image =
            [NSString stringWithUTF8String:record->originalImage] ?: @"-";

        [report appendFormat:
            @"#%zu %@ | calls=%llu | %.1f/s | total=%.3fms | max=%.3fms | owner=%@\n",
            i,
            XSPHookLabel(record),
            (unsigned long long)calls,
            rate,
            totalMs,
            maxMs,
            XSPShortImage(image)];
    }

    if (!any) [report appendString:@"- nenhuma chamada alvo durante a captura\n"];

    XSPAppendVerdict(report, duration);
    XSPAppendTopObjects(report);
    XSPAppendLoadedImages(report);
    XSPAppendHookInventory(report);
    XSPAppendStacks(report);

    [report appendString:
        @"\n[FIM DA CAPTURA]\n"
         "============================================================\n"];

    return report;
}

#pragma mark - Capture lifecycle

static UIViewController *XSPTopViewController(void) {
    UIWindow *window = nil;

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;

        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (window) break;
    }

    UIViewController *vc = window.rootViewController;
    while (vc) {
        if (vc.presentedViewController) {
            vc = vc.presentedViewController;
            continue;
        }
        if ([vc isKindOfClass:UINavigationController.class]) {
            vc = ((UINavigationController *)vc).visibleViewController;
            continue;
        }
        if ([vc isKindOfClass:UITabBarController.class]) {
            vc = ((UITabBarController *)vc).selectedViewController;
            continue;
        }
        break;
    }
    return vc;
}

static void XSPShowMessage(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = XSPTopViewController();
        if (!vc) return;

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:title
                                                message:message
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

static void XSPStopCapture(NSUInteger serial) {
    if (serial != gCaptureSerial || !atomic_load(&gCaptureActive)) return;

    atomic_store(&gCaptureActive, false);

    [gDisplayLink invalidate];
    gDisplayLink = nil;
    gDisplayLinkTarget = nil;

    double duration = CACurrentMediaTime() - gCaptureStartTime;
    if (duration <= 0.0) duration = kXSPCaptureDuration;

    gCaptureCount++;
    NSString *report = XSPBuildReport(duration);
    XSPAppendReport(report);

    XSPShowMessage(
        @"Scroll Probe concluído",
        [NSString stringWithFormat:
            @"Captura #%lu salva em %@. Abra novamente o Scroll Probe para copiar o relatório.",
            (unsigned long)gCaptureCount,
            kXSPLogFileName]);
}

static void XSPStartCaptureNow(NSUInteger serial) {
    if (serial != gCaptureSerial || atomic_load(&gCaptureActive)) return;

    gCaptureArmed = NO;
    XSPInstallPerformanceHooks();
    XSPResetCaptureStats();

    gDisplayLinkTarget = [XSPDisplayLinkTarget new];
    gDisplayLink =
        [CADisplayLink displayLinkWithTarget:gDisplayLinkTarget
                                    selector:@selector(tick:)];
    [gDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                       forMode:NSRunLoopCommonModes];

    gCaptureStartTime = CACurrentMediaTime();
    atomic_store(&gCaptureActive, true);

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(kXSPCaptureDuration * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            XSPStopCapture(serial);
        });
}

static void XSPCommitArmCapture(void) {
    if (gCaptureArmed || atomic_load(&gCaptureActive)) return;

    gCaptureArmed = YES;
    gCaptureSerial++;
    NSUInteger serial = gCaptureSerial;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(kXSPPreparationDelay * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            if (serial != gCaptureSerial || !gCaptureArmed) return;
            XSPStartCaptureNow(serial);
        });
}

static void XSPArmCapture(void) {
    if (gCaptureArmed || atomic_load(&gCaptureActive)) {
        XSPShowMessage(@"Scroll Probe", @"Já existe um diagnóstico em andamento.");
        return;
    }

    UIViewController *vc = XSPTopViewController();
    if (!vc) {
        XSPCommitArmCapture();
        return;
    }

    UIAlertController *alert =
        [UIAlertController
            alertControllerWithTitle:@"Iniciar diagnóstico"
                             message:
                [NSString stringWithFormat:
                    @"Ao tocar em Começar, você terá %.0f segundos para voltar à timeline. Depois role normalmente por %.0f segundos.",
                    kXSPPreparationDelay,
                    kXSPCaptureDuration]
                      preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:
        [UIAlertAction actionWithTitle:@"Cancelar"
                                 style:UIAlertActionStyleCancel
                               handler:nil]];

    [alert addAction:
        [UIAlertAction actionWithTitle:@"Começar"
                                 style:UIAlertActionStyleDefault
                               handler:^(__unused UIAlertAction *action) {
                                   XSPCommitArmCapture();
                               }]];

    [vc presentViewController:alert animated:YES completion:nil];
}

#pragma mark - BHTwitter / NeoFreeBird menu

@interface XLiquidGlassScrollProbeViewController : UITableViewController
@end

@implementation XLiquidGlassScrollProbeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Scroll Probe";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
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
    return @"Diagnóstico único de rolagem: mede frames, setEffect:, layoutSubviews, setNeedsLayout e churn das superfícies XDSBlur/XDSGlass/ScrollEdgeTreatment sem alterar o Liquid Glass.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"XSPCell";

    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
          reuseIdentifier:identifier];
    }

    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (indexPath.row == 0) {
        cell.textLabel.text = @"Iniciar diagnóstico";
        if (atomic_load(&gCaptureActive)) {
            cell.detailTextLabel.text = @"Capturando agora…";
        } else if (gCaptureArmed) {
            cell.detailTextLabel.text = @"Armado — volte à timeline.";
        } else {
            cell.detailTextLabel.text =
                [NSString stringWithFormat:@"%.0fs de preparo + %.0fs de rolagem",
                 kXSPPreparationDelay,
                 kXSPCaptureDuration];
        }
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"Copiar relatório";
        cell.detailTextLabel.text =
            [NSString stringWithFormat:@"%@ · capturas: %lu",
             kXSPLogFileName,
             (unsigned long)gCaptureCount];
    } else {
        cell.textLabel.text = @"Limpar relatório";
        cell.detailTextLabel.text = @"Apaga as capturas anteriores.";
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.row == 0) {
        XSPArmCapture();
        [tableView reloadData];
        return;
    }

    if (indexPath.row == 1) {
        NSString *report =
            [NSString stringWithContentsOfFile:XSPLogPath()
                                      encoding:NSUTF8StringEncoding
                                         error:nil] ?: @"";

        UIPasteboard.generalPasteboard.string = report;

        XSPShowMessage(
            @"Scroll Probe",
            [NSString stringWithFormat:
                @"Relatório copiado (%lu caracteres).",
                (unsigned long)report.length]);
        return;
    }

    [[NSFileManager defaultManager] removeItemAtPath:XSPLogPath() error:nil];
    gCaptureCount = 0;
    XSPShowMessage(@"Scroll Probe", @"Relatório apagado.");
    [tableView reloadData];
}

@end

static BOOL XSPSectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"action"] isEqualToString:@"showXLiquidGlassScrollProbe"]) {
            return YES;
        }
    }
    return NO;
}

static void XSPInjectNFBSection(id controller) {
    NSArray *sections = nil;

    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        return;
    }

    if (![sections isKindOfClass:NSArray.class] ||
        XSPSectionsContainEntry(sections)) {
        return;
    }

    NSMutableArray *updated = [sections mutableCopy];
    [updated addObject:@{
        @"title": @"Scroll Probe",
        @"subtitle": @"Diagnóstico de engasgos do Liquid Glass.",
        @"icon": @"flask",
        @"action": @"showXLiquidGlassScrollProbe"
    }];

    @try {
        [controller setValue:[updated copy] forKey:@"sections"];
    } @catch (__unused NSException *exception) {
    }
}

static void XSPNFBSetupSections(id self, SEL cmd) {
    if (gOrigNFBSetupSections) {
        ((void(*)(id,SEL))gOrigNFBSetupSections)(self, cmd);
    }
    XSPInjectNFBSection(self);
}

static void XSPNFBViewWillAppear(id self, SEL cmd, BOOL animated) {
    if (gOrigNFBViewWillAppear) {
        ((void(*)(id,SEL,BOOL))gOrigNFBViewWillAppear)(self, cmd, animated);
    }

    XSPInjectNFBSection(self);

    UITableView *tableView = nil;
    @try {
        tableView = [self valueForKey:@"tableView"];
    } @catch (__unused NSException *exception) {
    }

    [tableView reloadData];
}

static void XSPShowProbeSettings(id self, SEL cmd) {
    (void)cmd;
    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassScrollProbeViewController *vc =
        [XLiquidGlassScrollProbeViewController new];

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

static BOOL XSPHookSimpleMethod(Class cls,
                                SEL selector,
                                IMP replacement,
                                IMP *originalOut) {
    if (!cls || !selector || !replacement) return NO;

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;

    IMP current = class_getMethodImplementation(cls, selector);
    if (current == replacement) return YES;

    if (originalOut && !*originalOut) *originalOut = current;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    class_replaceMethod(cls, selector, replacement, types);
    return class_getMethodImplementation(cls, selector) == replacement;
}

static void XSPInstallNFBIntegration(void) {
    if (gNFBHookInstalled) return;

    Class cls = NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;

    class_addMethod(cls,
                    NSSelectorFromString(@"showXLiquidGlassScrollProbe"),
                    (IMP)XSPShowProbeSettings,
                    "v@:");

    BOOL setup =
        XSPHookSimpleMethod(cls,
                            NSSelectorFromString(@"setupSections"),
                            (IMP)XSPNFBSetupSections,
                            &gOrigNFBSetupSections);

    BOOL appear =
        XSPHookSimpleMethod(cls,
                            @selector(viewWillAppear:),
                            (IMP)XSPNFBViewWillAppear,
                            &gOrigNFBViewWillAppear);

    gNFBHookInstalled = setup || appear;
}

#pragma mark - Install / constructor

static void XSPInstallAll(void) {
    XSPInstallPerformanceHooks();
    XSPInstallNFBIntegration();
}

static void XSPScheduleInstall(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            XSPInstallAll();
        });
}

__attribute__((constructor))
static void XLiquidGlassScrollProbeInit(void) {
    @autoreleasepool {
        mach_timebase_info(&gTimebase);
        NSLog(@"[XLiquidGlassScrollProbe] 0.1 loaded; report=%@",
              XSPLogPath());

        XSPInstallAll();

        XSPScheduleInstall(0.05);
        XSPScheduleInstall(0.20);
        XSPScheduleInstall(0.50);
        XSPScheduleInstall(1.00);
        XSPScheduleInstall(2.00);
        XSPScheduleInstall(4.00);
    }
}
