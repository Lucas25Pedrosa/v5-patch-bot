#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#include <stdint.h>
#include <string.h>

static NSString *const kProbeVersion = @"1.0";
static NSString *const kLogName = @"GlassXNativeStateProbe.log";

static IMP gOrigGate = NULL;
static IMP gOrigTabLoad = NULL;
static IMP gOrigRedesign = NULL;
static IMP gOrigPushChrome = NULL;
static BOOL gGateHooked = NO;
static BOOL gTabHooked = NO;
static BOOL gFeatureHooksInstalled = NO;
static NSUInteger gRedesignCalls = 0;
static NSUInteger gPushChromeCalls = 0;

static const uint8_t kKnownXServiceUUID[16] = {
    0xFD,0x66,0x1A,0xA4,0x70,0x47,0x3C,0x70,
    0x96,0x0A,0x64,0x99,0xC8,0x00,0xD7,0x28
};
static const uintptr_t kKnownGateByteOffset = 0x49840c0;

static NSString *LogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kLogName];
}

static void PLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void PLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", NSDate.date, body ?: @""];
    @synchronized(NSFileManager.defaultManager) {
        NSString *path = LogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
    }
    NSLog(@"[GlassXNativeStateProbe] %@", body ?: @"");
}

static NSString *UUIDString(const uint8_t uuid[16]) {
    return [NSString stringWithFormat:@"%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
            uuid[0],uuid[1],uuid[2],uuid[3],uuid[4],uuid[5],uuid[6],uuid[7],
            uuid[8],uuid[9],uuid[10],uuid[11],uuid[12],uuid[13],uuid[14],uuid[15]];
}

static BOOL HeaderUUID(const struct mach_header *header, uint8_t out[16]) {
    if (!header || header->magic != MH_MAGIC_64) return NO;
    const struct mach_header_64 *h = (const struct mach_header_64 *)header;
    const struct load_command *cmd = (const struct load_command *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        if (cmd->cmd == LC_UUID && cmd->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *u = (const struct uuid_command *)cmd;
            memcpy(out, u->uuid, 16);
            return YES;
        }
        cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
    }
    return NO;
}

static const struct mach_header *XServiceHeader(uint8_t uuid[16], BOOL *knownUUID) {
    if (knownUUID) *knownUUID = NO;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        const char *name = strrchr(path, '/');
        name = name ? name + 1 : path;
        if (strcmp(name, "XServiceLibraries") != 0) continue;
        const struct mach_header *header = _dyld_get_image_header(i);
        uint8_t found[16] = {0};
        if (HeaderUUID(header, found)) {
            if (uuid) memcpy(uuid, found, 16);
            if (knownUUID) *knownUUID = memcmp(found, kKnownXServiceUUID, 16) == 0;
        }
        return header;
    }
    return NULL;
}

static BOOL GlassXTweakLoaded(void) {
    BOOL hit = NO;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        NSString *name = [[NSString stringWithUTF8String:path] lastPathComponent];
        if ([name isEqualToString:@"GlassX.dylib"] ||
            [name isEqualToString:@"GlassXDE.dylib"] ||
            [name containsString:@"XLiquidGlass1238PreTabBar"] ||
            [name isEqualToString:@"XLiquidGlassNative.dylib"]) {
            PLog(@"CONTAMINATION image=%@", name);
            hit = YES;
        }
    }
    return hit;
}

static Class AppearanceClass(void) {
    Class c = NSClassFromString(@"XAppearance.Appearance");
    if (!c) c = NSClassFromString(@"_TtC11XAppearance10Appearance");
    return c;
}

static Class FeaturesClass(void) {
    Class c = NSClassFromString(@"T1TwitterSwift.LiquidGlassRedesignFeatures");
    if (!c) c = NSClassFromString(@"_TtC14T1TwitterSwift27LiquidGlassRedesignFeatures");
    if (c) return c;
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;
    __unsafe_unretained Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return Nil;
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        NSString *n = NSStringFromClass(classes[i]);
        if ([n containsString:@"LiquidGlassRedesignFeatures"]) { c = classes[i]; break; }
    }
    free(classes);
    return c;
}

static NSString *AddrInfo(const void *p) {
    if (!p) return @"nil";
    Dl_info d = {0};
    if (dladdr(p, &d) && d.dli_fbase) {
        NSString *image = d.dli_fname ? [[NSString stringWithUTF8String:d.dli_fname] lastPathComponent] : @"?";
        uintptr_t offset = (uintptr_t)p - (uintptr_t)d.dli_fbase;
        return [NSString stringWithFormat:@"%@+0x%llx", image, (unsigned long long)offset];
    }
    return [NSString stringWithFormat:@"%p", p];
}

static void DumpDefaults(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSArray<NSString *> *known = @[
        @"ios_liquid_glass_avatar_badge_enabled",
        @"ios_liquid_glass_push_chrome_snap_enabled",
        @"ios_liquid_glass_redesign_enabled",
        @"x_liquid_glass_redesign_enabled",
        @"ios_liquid_glass_redesign_quick_composer_enabled",
        @"ios_liquid_glass_xchat_conversation_header_enabled",
        @"ios_liquid_glass_grok_composer_enabled",
        @"T1LiquidGlassRedesignPersistedGate",
        @"XLiquidGlassEnabled"
    ];
    PLog(@"DEFAULTS_KNOWN_BEGIN");
    for (NSString *key in known) {
        id value = [d objectForKey:key];
        PLog(@"FLAG key=%@ value=%@ bool=%d", key, value ?: @"<nil>", [d boolForKey:key]);
    }
    PLog(@"DEFAULTS_KNOWN_END");

    NSDictionary *all = [d dictionaryRepresentation];
    NSArray *keys = [[all allKeys] sortedArrayUsingSelector:@selector(compare:)];
    PLog(@"DEFAULTS_DISCOVERY_BEGIN");
    for (NSString *key in keys) {
        NSString *lower = key.lowercaseString;
        if ([lower containsString:@"liquid_glass"] || [lower containsString:@"liquidglass"]) {
            PLog(@"DISCOVERED key=%@ value=%@", key, all[key]);
        }
    }
    PLog(@"DEFAULTS_DISCOVERY_END");
}

static void DumpAppearanceState(NSString *where) {
    Class c = AppearanceClass();
    if (!c) { PLog(@"APPEARANCE where=%@ class=missing", where); return; }
    NSArray<NSString *> *names = @[
        @"isLiquidGlassEnabled",
        @"isLiquidGlassChromeActive",
        @"isLiquidGlassForcedBySystem"
    ];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *name in names) {
        SEL s = NSSelectorFromString(name);
        Method m = class_getClassMethod(c, s);
        if (!m) { [parts addObject:[NSString stringWithFormat:@"%@=missing", name]]; continue; }
        IMP imp = method_getImplementation(m);
        BOOL value = ((BOOL(*)(id,SEL))imp)(c, s);
        [parts addObject:[NSString stringWithFormat:@"%@=%d@%@", name, value ? 1 : 0, AddrInfo((const void *)imp)]];
    }
    PLog(@"APPEARANCE where=%@ %@", where, [parts componentsJoinedByString:@" "]);
}

static void DumpGateByte(NSString *where) {
    uint8_t uuid[16] = {0};
    BOOL known = NO;
    const struct mach_header *header = XServiceHeader(uuid, &known);
    if (!header) { PLog(@"GATE_BYTE where=%@ xservice=missing", where); return; }
    NSString *uuidString = UUIDString(uuid);
    if (!known) {
        PLog(@"GATE_BYTE where=%@ uuid=%@ known=0 value=unread-safe", where, uuidString);
        return;
    }
    const volatile uint8_t *byte = (const volatile uint8_t *)((uintptr_t)header + kKnownGateByteOffset);
    PLog(@"GATE_BYTE where=%@ uuid=%@ known=1 offset=0x%llx value=%u",
         where, uuidString, (unsigned long long)kKnownGateByteOffset, (unsigned)*byte);
}

static void DumpFeatureMethods(void) {
    Class c = FeaturesClass();
    PLog(@"FEATURE_CLASS name=%@ present=%d", c ? NSStringFromClass(c) : @"<nil>", c ? 1 : 0);
    if (!c) return;
    unsigned count = 0;
    Method *methods = class_copyMethodList(c, &count);
    for (unsigned i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"glass"] || [lower containsString:@"redesign"] ||
            [lower containsString:@"chrome"] || [lower containsString:@"avatar"] ||
            [lower containsString:@"badge"]) {
            PLog(@"FEATURE_METHOD selector=%@ types=%s imp=%@", name,
                 method_getTypeEncoding(methods[i]) ?: "?",
                 AddrInfo((const void *)method_getImplementation(methods[i])));
        }
    }
    free(methods);
}

static BOOL RedesignHook(id self, SEL _cmd) {
    BOOL value = gOrigRedesign ? ((BOOL(*)(id,SEL))gOrigRedesign)(self, _cmd) : NO;
    gRedesignCalls++;
    if (gRedesignCalls <= 30) PLog(@"FEATURE_VALUE selector=isRedesignEnabled call=%lu value=%d objectClass=%@",
                                   (unsigned long)gRedesignCalls, value ? 1 : 0, NSStringFromClass([self class]));
    return value;
}

static BOOL PushChromeHook(id self, SEL _cmd) {
    BOOL value = gOrigPushChrome ? ((BOOL(*)(id,SEL))gOrigPushChrome)(self, _cmd) : NO;
    gPushChromeCalls++;
    if (gPushChromeCalls <= 30) PLog(@"FEATURE_VALUE selector=isPushChromeSnapEnabled call=%lu value=%d objectClass=%@",
                                    (unsigned long)gPushChromeCalls, value ? 1 : 0, NSStringFromClass([self class]));
    return value;
}

static void InstallFeatureHooks(void) {
    if (gFeatureHooksInstalled) return;
    Class c = FeaturesClass();
    if (!c) return;
    SEL redesign = NSSelectorFromString(@"isRedesignEnabled");
    Method rm = class_getInstanceMethod(c, redesign);
    if (rm) {
        IMP cur = class_getMethodImplementation(c, redesign);
        if (cur != (IMP)RedesignHook) {
            gOrigRedesign = cur;
            class_replaceMethod(c, redesign, (IMP)RedesignHook, method_getTypeEncoding(rm));
        }
    }
    SEL push = NSSelectorFromString(@"isPushChromeSnapEnabled");
    Method pm = class_getInstanceMethod(c, push);
    if (pm) {
        IMP cur = class_getMethodImplementation(c, push);
        if (cur != (IMP)PushChromeHook) {
            gOrigPushChrome = cur;
            class_replaceMethod(c, push, (IMP)PushChromeHook, method_getTypeEncoding(pm));
        }
    }
    gFeatureHooksInstalled = YES;
    PLog(@"FEATURE_HOOKS redesign=%d pushChrome=%d", rm ? 1 : 0, pm ? 1 : 0);
}

static void Capture(NSString *reason) {
    BOOL contaminated = GlassXTweakLoaded();
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
    PLog(@"CAPTURE_BEGIN reason=%@ app=%@ build=%@ iOS=%@ contaminated=%d",
         reason, version, build, UIDevice.currentDevice.systemVersion, contaminated ? 1 : 0);
    DumpDefaults();
    DumpAppearanceState(reason);
    DumpGateByte(reason);
    DumpFeatureMethods();
    PLog(@"VERDICT_HINT valid_native_test=%d note=%@", contaminated ? 0 : 1,
         contaminated ? @"Remove GlassX/GlassXDE and repeat; another tweak is forcing the gate." : @"Probe is passive: observed values come from X itself.");
    PLog(@"CAPTURE_END reason=%@", reason);
}

static void GateHook(id self, SEL _cmd, id account) {
    PLog(@"GATE_INSTALL_BEGIN accountClass=%@", account ? NSStringFromClass([account class]) : @"nil");
    DumpAppearanceState(@"before-installGateForAccount");
    DumpGateByte(@"before-installGateForAccount");
    if (gOrigGate) ((void(*)(id,SEL,id))gOrigGate)(self, _cmd, account);
    DumpAppearanceState(@"after-installGateForAccount");
    DumpGateByte(@"after-installGateForAccount");
    DumpDefaults();
    PLog(@"GATE_INSTALL_END");
}

static void TabLoadHook(id self, SEL _cmd) {
    DumpAppearanceState(@"before-tab-loadView");
    DumpGateByte(@"before-tab-loadView");
    if (gOrigTabLoad) ((void(*)(id,SEL))gOrigTabLoad)(self, _cmd);
    DumpAppearanceState(@"after-tab-loadView");
    DumpGateByte(@"after-tab-loadView");
}

static void InstallHooks(void) {
    if (!gGateHooked) {
        Class c = NSClassFromString(@"T1LiquidGlassGateInstaller");
        SEL s = NSSelectorFromString(@"installGateForAccount:");
        Method m = c ? class_getClassMethod(c, s) : NULL;
        if (m) {
            Class meta = object_getClass(c);
            IMP cur = class_getMethodImplementation(meta, s);
            if (cur != (IMP)GateHook) {
                gOrigGate = cur;
                class_replaceMethod(meta, s, (IMP)GateHook, method_getTypeEncoding(m));
            }
            gGateHooked = class_getMethodImplementation(meta, s) == (IMP)GateHook;
            PLog(@"HOOK gateInstaller=%d original=%@", gGateHooked ? 1 : 0, AddrInfo((const void *)gOrigGate));
        }
    }
    if (!gTabHooked) {
        Class c = NSClassFromString(@"T1TabBarViewController");
        SEL s = @selector(loadView);
        Method m = c ? class_getInstanceMethod(c, s) : NULL;
        if (m) {
            IMP cur = class_getMethodImplementation(c, s);
            if (cur != (IMP)TabLoadHook) {
                gOrigTabLoad = cur;
                class_replaceMethod(c, s, (IMP)TabLoadHook, method_getTypeEncoding(m));
            }
            gTabHooked = class_getMethodImplementation(c, s) == (IMP)TabLoadHook;
            PLog(@"HOOK tabLoad=%d original=%@", gTabHooked ? 1 : 0, AddrInfo((const void *)gOrigTabLoad));
        }
    }
    InstallFeatureHooks();
}

@interface GXNativeProbeVC : UITableViewController @end
@implementation GXNativeProbeVC
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"GlassX Native State Probe"; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return 4; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return @"PASSIVO: não altera flags nem gates. Para saber se o X ativou sozinho, teste sem GlassX/GlassXDE injetado.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSArray *titles = @[@"Capturar estado agora", @"Reinstalar hooks", @"Compartilhar log", @"Limpar log"];
    NSArray *details = @[@"Lê flags, XAppearance, gate byte e features.", @"Útil após login/troca de conta.", @"Compartilha GlassXNativeStateProbe.log.", @"Inicia uma sessão limpa."];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = titles[indexPath.row];
    cell.detailTextLabel.text = details[indexPath.row];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 0) Capture(@"manual");
    else if (indexPath.row == 1) InstallHooks();
    else if (indexPath.row == 2) {
        NSURL *url = [NSURL fileURLWithPath:LogPath()];
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        [self presentViewController:share animated:YES completion:nil];
    } else {
        [@"" writeToFile:LogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        PLog(@"NEW_SESSION version=%@ mode=PASSIVE_NATIVE_STATE", kProbeVersion);
    }
}
@end

static IMP gOrigSetup = NULL;
static IMP gOrigAppear = NULL;
static BOOL HasProbeEntry(NSArray *sections) {
    for (id entry in sections) if ([entry isKindOfClass:NSDictionary.class] && [entry[@"action"] isEqual:@"showGlassXNativeStateProbe"]) return YES;
    return NO;
}
static void InjectMenu(id controller) {
    NSArray *sections = nil;
    @try { sections = [controller valueForKey:@"sections"]; } @catch (__unused NSException *e) { return; }
    if (![sections isKindOfClass:NSArray.class] || HasProbeEntry(sections)) return;
    NSMutableArray *m = [sections mutableCopy];
    [m insertObject:@{@"title":@"GlassX Native State Probe", @"subtitle":@"Diagnóstico passivo dos gates do X 12.38", @"icon":@"flask", @"action":@"showGlassXNativeStateProbe"} atIndex:MIN((NSUInteger)2, m.count)];
    @try { [controller setValue:[m copy] forKey:@"sections"]; } @catch (__unused NSException *e) {}
}
static void SetupHook(id self, SEL _cmd) { if (gOrigSetup) ((void(*)(id,SEL))gOrigSetup)(self, _cmd); InjectMenu(self); }
static void AppearHook(id self, SEL _cmd, BOOL animated) { if (gOrigAppear) ((void(*)(id,SEL,BOOL))gOrigAppear)(self, _cmd, animated); InjectMenu(self); }
static void ShowProbe(id self, SEL _cmd) {
    (void)_cmd;
    GXNativeProbeVC *vc = [GXNativeProbeVC new];
    UINavigationController *nav = [self navigationController];
    if (nav) [nav pushViewController:vc animated:YES];
    else [self presentViewController:[[UINavigationController alloc] initWithRootViewController:vc] animated:YES completion:nil];
}
static void InstallNFBMenu(void) {
    Class c = NSClassFromString(@"ModernSettingsViewController");
    if (!c) return;
    SEL show = NSSelectorFromString(@"showGlassXNativeStateProbe");
    if (![c instancesRespondToSelector:show]) class_addMethod(c, show, (IMP)ShowProbe, "v@:");
    Method setup = class_getInstanceMethod(c, NSSelectorFromString(@"setupSections"));
    if (setup && class_getMethodImplementation(c, method_getName(setup)) != (IMP)SetupHook) {
        gOrigSetup = class_getMethodImplementation(c, method_getName(setup));
        class_replaceMethod(c, method_getName(setup), (IMP)SetupHook, method_getTypeEncoding(setup));
    }
    Method appear = class_getInstanceMethod(c, @selector(viewWillAppear:));
    if (appear && class_getMethodImplementation(c, @selector(viewWillAppear:)) != (IMP)AppearHook) {
        gOrigAppear = class_getMethodImplementation(c, @selector(viewWillAppear:));
        class_replaceMethod(c, @selector(viewWillAppear:), (IMP)AppearHook, method_getTypeEncoding(appear));
    }
}

@interface GXNativeProbeBootstrap : NSObject @end
@implementation GXNativeProbeBootstrap
+ (void)load {
    @autoreleasepool {
        PLog(@"NEW_SESSION version=%@ mode=PASSIVE_NATIVE_STATE", kProbeVersion);
        NSArray *delays = @[@0.0,@0.05,@0.15,@0.35,@0.70,@1.20,@2.50,@5.0];
        for (NSNumber *delay in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                InstallHooks();
                InstallNFBMenu();
                if (delay.doubleValue == 0.70 || delay.doubleValue == 2.50 || delay.doubleValue == 5.0) {
                    Capture([NSString stringWithFormat:@"auto-%.2f", delay.doubleValue]);
                }
            });
        }
    }
}
@end
