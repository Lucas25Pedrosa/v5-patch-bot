#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <stdint.h>
#include <string.h>

static NSString *const kVersion = @"1.0";
static NSString *const kLogName = @"GlassXPostActivationProbe.log";
static IMP gOrigRedesign = NULL;
static IMP gOrigPushChrome = NULL;
static BOOL gFeatureHooksInstalled = NO;
static NSUInteger gRedesignCalls = 0;
static NSUInteger gPushChromeCalls = 0;

static const uint8_t kXServiceUUID[16] = {
    0xFD,0x66,0x1A,0xA4,0x70,0x47,0x3C,0x70,
    0x96,0x0A,0x64,0x99,0xC8,0x00,0xD7,0x28
};
static const uintptr_t kGateByteOffset = 0x49840c0;

static NSString *LogPath(void) {
    NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!d.length) d = NSTemporaryDirectory();
    return [d stringByAppendingPathComponent:kLogName];
}

static void PLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void PLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", NSDate.date, body ?: @""];
    @synchronized(NSFileManager.defaultManager) {
        NSString *p = LogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:p]) [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
        if (h) { [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile]; }
    }
    NSLog(@"[GlassXPostActivationProbe] %@", body ?: @"");
}

static NSString *GlassXCompanion(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i); if (!p) continue;
        NSString *name = [[NSString stringWithUTF8String:p] lastPathComponent];
        if ([name isEqualToString:@"GlassX.dylib"] || [name isEqualToString:@"GlassXDE.dylib"]) return name;
    }
    return @"<not-loaded>";
}

static BOOL HeaderHasKnownUUID(const struct mach_header *header) {
    if (!header || header->magic != MH_MAGIC_64) return NO;
    const struct mach_header_64 *h = (const struct mach_header_64 *)header;
    const struct load_command *cmd = (const struct load_command *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        if (cmd->cmd == LC_UUID && cmd->cmdsize >= sizeof(struct uuid_command)) {
            return memcmp(((const struct uuid_command *)cmd)->uuid, kXServiceUUID, 16) == 0;
        }
        cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
    }
    return NO;
}

static const struct mach_header *XServiceHeader(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i); if (!p) continue;
        const char *name = strrchr(p, '/'); name = name ? name + 1 : p;
        if (strcmp(name, "XServiceLibraries") == 0) return _dyld_get_image_header(i);
    }
    return NULL;
}

static void LogGlobalState(NSString *reason) {
    const struct mach_header *h = XServiceHeader();
    if (!h) PLog(@"GLOBAL_GATE reason=%@ xservice=missing", reason);
    else if (!HeaderHasKnownUUID(h)) PLog(@"GLOBAL_GATE reason=%@ uuid=unknown value=unread-safe", reason);
    else {
        const volatile uint8_t *b = (const volatile uint8_t *)((uintptr_t)h + kGateByteOffset);
        PLog(@"GLOBAL_GATE reason=%@ value=%u note=expected-forced-by-GlassX", reason, (unsigned)*b);
    }

    Class c = NSClassFromString(@"XAppearance.Appearance");
    if (!c) c = NSClassFromString(@"_TtC11XAppearance10Appearance");
    if (!c) { PLog(@"APPEARANCE reason=%@ class=missing", reason); return; }
    NSArray *names = @[@"isLiquidGlassEnabled", @"isLiquidGlassChromeActive", @"isLiquidGlassForcedBySystem"];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *name in names) {
        SEL s = NSSelectorFromString(name); Method m = class_getClassMethod(c, s);
        if (!m) { [parts addObject:[NSString stringWithFormat:@"%@=missing", name]]; continue; }
        BOOL v = ((BOOL(*)(id,SEL))method_getImplementation(m))(c, s);
        [parts addObject:[NSString stringWithFormat:@"%@=%d", name, v ? 1 : 0]];
    }
    PLog(@"APPEARANCE reason=%@ %@", reason, [parts componentsJoinedByString:@" "]);
}

static NSArray<NSString *> *KnownFlags(void) {
    return @[
        @"ios_liquid_glass_avatar_badge_enabled",
        @"ios_liquid_glass_push_chrome_snap_enabled",
        @"ios_liquid_glass_redesign_enabled",
        @"x_liquid_glass_redesign_enabled",
        @"ios_liquid_glass_redesign_quick_composer_enabled",
        @"ios_liquid_glass_xchat_conversation_header_enabled",
        @"ios_liquid_glass_grok_composer_enabled",
        @"ios_liquid_glass_grok_glass_composer_enabled",
        @"T1LiquidGlassRedesignPersistedGate"
    ];
}

static void LogSubgates(NSString *reason) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    PLog(@"SUBGATES_BEGIN reason=%@", reason);
    for (NSString *key in KnownFlags()) {
        id v = [d objectForKey:key];
        PLog(@"SUBGATE key=%@ value=%@ bool=%d", key, v ?: @"<nil>", [d boolForKey:key] ? 1 : 0);
    }
    NSDictionary *all = [d dictionaryRepresentation];
    NSArray *keys = [[all allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *key in keys) {
        NSString *lower = key.lowercaseString;
        if ([lower containsString:@"liquid_glass"] || [lower containsString:@"liquidglass"]) {
            if (![KnownFlags() containsObject:key]) PLog(@"DISCOVERED_SUBGATE key=%@ value=%@", key, all[key]);
        }
    }
    PLog(@"SUBGATES_END reason=%@", reason);
}

static Class FeaturesClass(void) {
    Class c = NSClassFromString(@"T1TwitterSwift.LiquidGlassRedesignFeatures");
    if (!c) c = NSClassFromString(@"_TtC14T1TwitterSwift27LiquidGlassRedesignFeatures");
    return c;
}

static BOOL RedesignHook(id self, SEL _cmd) {
    BOOL v = gOrigRedesign ? ((BOOL(*)(id,SEL))gOrigRedesign)(self,_cmd) : NO;
    gRedesignCalls++;
    if (gRedesignCalls <= 50) PLog(@"FEATURE_VALUE selector=isRedesignEnabled call=%lu value=%d", (unsigned long)gRedesignCalls, v ? 1 : 0);
    return v;
}

static BOOL PushChromeHook(id self, SEL _cmd) {
    BOOL v = gOrigPushChrome ? ((BOOL(*)(id,SEL))gOrigPushChrome)(self,_cmd) : NO;
    gPushChromeCalls++;
    if (gPushChromeCalls <= 50) PLog(@"FEATURE_VALUE selector=isPushChromeSnapEnabled call=%lu value=%d", (unsigned long)gPushChromeCalls, v ? 1 : 0);
    return v;
}

static void InstallFeatureHooks(void) {
    if (gFeatureHooksInstalled) return;
    Class c = FeaturesClass(); if (!c) return;
    SEL r = NSSelectorFromString(@"isRedesignEnabled"); Method rm = class_getInstanceMethod(c, r);
    if (rm) { gOrigRedesign = class_getMethodImplementation(c, r); class_replaceMethod(c, r, (IMP)RedesignHook, method_getTypeEncoding(rm)); }
    SEL p = NSSelectorFromString(@"isPushChromeSnapEnabled"); Method pm = class_getInstanceMethod(c, p);
    if (pm) { gOrigPushChrome = class_getMethodImplementation(c, p); class_replaceMethod(c, p, (IMP)PushChromeHook, method_getTypeEncoding(pm)); }
    gFeatureHooksInstalled = YES;
    PLog(@"FEATURE_HOOKS redesign=%d pushChrome=%d readOnly=1", rm ? 1 : 0, pm ? 1 : 0);
}

static void DumpFeatureMethodNames(void) {
    Class c = FeaturesClass(); if (!c) { PLog(@"FEATURE_CLASS missing"); return; }
    unsigned count = 0; Method *methods = class_copyMethodList(c, &count);
    for (unsigned i = 0; i < count; i++) {
        NSString *n = NSStringFromSelector(method_getName(methods[i])); NSString *l = n.lowercaseString;
        if ([l containsString:@"glass"] || [l containsString:@"redesign"] || [l containsString:@"chrome"] || [l containsString:@"avatar"] || [l containsString:@"badge"] || [l containsString:@"composer"] || [l containsString:@"xchat"] || [l containsString:@"grok"]) PLog(@"FEATURE_METHOD selector=%@ types=%s", n, method_getTypeEncoding(methods[i]) ?: "?");
    }
    free(methods);
}

static void Snapshot(NSString *reason) {
    NSString *companion = GlassXCompanion();
    NSString *app = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
    PLog(@"SNAPSHOT_BEGIN reason=%@ app=%@ build=%@ companion=%@ expectedGlassX=%d", reason, app, build, companion, [companion isEqualToString:@"GlassX.dylib"] ? 1 : 0);
    LogGlobalState(reason);
    LogSubgates(reason);
    DumpFeatureMethodNames();
    PLog(@"INTERPRETATION global-gate-is-baseline-forced-by-GlassX; any secondary flag/getter becoming 1 is what this probe is measuring");
    PLog(@"SNAPSHOT_END reason=%@", reason);
}

__attribute__((constructor)) static void Init(void) {
    @autoreleasepool {
        PLog(@"NEW_SESSION version=%@ mode=POST_GLASSX_NATIVE_SUBGATE_OBSERVER writes=0", kVersion);
        NSArray<NSNumber *> *delays = @[@0.10,@0.30,@0.70,@1.20,@2.0,@3.5,@5.0,@8.0,@12.0,@20.0,@30.0,@60.0];
        for (NSNumber *d in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                InstallFeatureHooks();
                Snapshot([NSString stringWithFormat:@"auto-%.2fs", d.doubleValue]);
            });
        }
    }
}
