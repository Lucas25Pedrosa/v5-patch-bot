#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

// GoogleNewsLiquidGlassProbe 0.1
// Target validated against Google News 5.122 (5.122.1300)
// Bundle: com.google.GoogleDigitalEditions
// READ-ONLY: no return value is forced or changed.

typedef BOOL (*GNBoolIMP)(id, SEL);

static GNBoolIMP origM3CIsAvailable = NULL;
static GNBoolIMP origM3CComputeAvailable = NULL;
static GNBoolIMP origFlagAppSwitching = NULL;
static GNBoolIMP origFlagSwitcherUI = NULL;
static GNBoolIMP origFlagExperienceKit = NULL;

static volatile uint64_t seqNo = 0;
static volatile uint64_t callsM3CIsAvailable = 0;
static volatile uint64_t callsM3CComputeAvailable = 0;
static volatile uint64_t callsFlagAppSwitching = 0;
static volatile uint64_t callsFlagSwitcherUI = 0;
static volatile uint64_t callsFlagExperienceKit = 0;
static NSString *logPath = nil;

static uint64_t NextSeq(void) {
    return __sync_add_and_fetch(&seqNo, 1);
}

static NSString *ProbeLogPath(void) {
    if (logPath != nil) return logPath;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents.length == 0) documents = NSTemporaryDirectory();
    logPath = [documents stringByAppendingPathComponent:@"GoogleNewsLiquidGlassProbe.log"];
    return logPath;
}

static void LogLine(NSString *line) {
    @autoreleasepool {
        NSString *path = ProbeLogPath();
        NSString *record = [NSString stringWithFormat:@"[%.3f] #%llu %@\n",
                            CFAbsoluteTimeGetCurrent(), (unsigned long long)NextSeq(), line];
        NSData *data = [record dataUsingEncoding:NSUTF8StringEncoding];
        @synchronized([NSFileHandle class]) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            }
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        }
    }
}

static void LogReturn(NSString *method, BOOL value, uint64_t callNo, id receiver) {
    LogLine([NSString stringWithFormat:@"CALL method=%@ result=%@ raw=%d call=%llu self=%p",
             method, value ? @"YES" : @"NO", (int)value, (unsigned long long)callNo, receiver]);
}

static BOOL HookM3CIsAvailable(id self, SEL _cmd) {
    uint64_t n = __sync_add_and_fetch(&callsM3CIsAvailable, 1);
    BOOL value = origM3CIsAvailable ? origM3CIsAvailable(self, _cmd) : NO;
    if (n <= 200) LogReturn(@"+[M3CLiquidGlass isLiquidGlassAvailable]", value, n, self);
    else if (n == 201) LogLine(@"SUPPRESS method=+[M3CLiquidGlass isLiquidGlassAvailable] after=200");
    return value;
}

static BOOL HookM3CComputeAvailable(id self, SEL _cmd) {
    uint64_t n = __sync_add_and_fetch(&callsM3CComputeAvailable, 1);
    BOOL value = origM3CComputeAvailable ? origM3CComputeAvailable(self, _cmd) : NO;
    if (n <= 200) LogReturn(@"+[M3CLiquidGlass computeIsLiquidGlassAvailable]", value, n, self);
    else if (n == 201) LogLine(@"SUPPRESS method=+[M3CLiquidGlass computeIsLiquidGlassAvailable] after=200");
    return value;
}

static BOOL HookFlagAppSwitching(id self, SEL _cmd) {
    uint64_t n = __sync_add_and_fetch(&callsFlagAppSwitching, 1);
    BOOL value = origFlagAppSwitching ? origFlagAppSwitching(self, _cmd) : NO;
    if (n <= 200) LogReturn(@"-[ASWPhenotypeFlagsImpl AppSwitching__enable_app_switching_liquid_glass]", value, n, self);
    else if (n == 201) LogLine(@"SUPPRESS method=AppSwitching__enable_app_switching_liquid_glass after=200");
    return value;
}

static BOOL HookFlagSwitcherUI(id self, SEL _cmd) {
    uint64_t n = __sync_add_and_fetch(&callsFlagSwitcherUI, 1);
    BOOL value = origFlagSwitcherUI ? origFlagSwitcherUI(self, _cmd) : NO;
    if (n <= 200) LogReturn(@"-[ASWPhenotypeFlagsImpl AppSwitching__enable_switcher_ui_liquid_glass]", value, n, self);
    else if (n == 201) LogLine(@"SUPPRESS method=AppSwitching__enable_switcher_ui_liquid_glass after=200");
    return value;
}

static BOOL HookFlagExperienceKit(id self, SEL _cmd) {
    uint64_t n = __sync_add_and_fetch(&callsFlagExperienceKit, 1);
    BOOL value = origFlagExperienceKit ? origFlagExperienceKit(self, _cmd) : NO;
    if (n <= 200) LogReturn(@"-[ASWPhenotypeFlagsImpl ExperienceKit__enable_experiencekit_liquid_glass]", value, n, self);
    else if (n == 201) LogLine(@"SUPPRESS method=ExperienceKit__enable_experiencekit_liquid_glass after=200");
    return value;
}

static BOOL InstallClassHook(NSString *className, NSString *selectorName, IMP replacement, GNBoolIMP *original) {
    Class cls = NSClassFromString(className);
    if (!cls) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, selector);
    if (!method) return NO;
    IMP old = method_setImplementation(method, replacement);
    if (original) *original = (GNBoolIMP)old;
    return old != NULL;
}

static BOOL InstallInstanceHook(NSString *className, NSString *selectorName, IMP replacement, GNBoolIMP *original) {
    Class cls = NSClassFromString(className);
    if (!cls) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    IMP old = method_setImplementation(method, replacement);
    if (original) *original = (GNBoolIMP)old;
    return old != NULL;
}

__attribute__((constructor)) static void GoogleNewsLiquidGlassProbeInit(void) {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"(nil)";
        if (![bundle isEqualToString:@"com.google.GoogleDigitalEditions"]) return;

        [[NSFileManager defaultManager] removeItemAtPath:ProbeLogPath() error:nil];

        LogLine(@"========== GoogleNews Liquid Glass Probe 0.1 loaded ==========");
        LogLine([NSString stringWithFormat:@"TARGET bundle=%@ appVersion=%@ build=%@",
                 bundle,
                 [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
                 [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"]);

        id compatibility = [NSBundle.mainBundle objectForInfoDictionaryKey:@"UIDesignRequiresCompatibility"];
        LogLine([NSString stringWithFormat:@"ENV iOS=%@ UIGlassEffect=%@ UIDesignRequiresCompatibility=%@",
                 UIDevice.currentDevice.systemVersion,
                 NSClassFromString(@"UIGlassEffect") ? @"PRESENT" : @"ABSENT",
                 compatibility ?: @"<missing>"]);

        Class m3c = NSClassFromString(@"M3CLiquidGlass");
        Class flags = NSClassFromString(@"ASWPhenotypeFlagsImpl");
        LogLine([NSString stringWithFormat:@"CLASSES M3CLiquidGlass=%@ ASWPhenotypeFlagsImpl=%@",
                 m3c ? @"PRESENT" : @"ABSENT", flags ? @"PRESENT" : @"ABSENT"]);

        BOOL h1 = InstallClassHook(@"M3CLiquidGlass", @"isLiquidGlassAvailable",
                                   (IMP)HookM3CIsAvailable, &origM3CIsAvailable);
        BOOL h2 = InstallClassHook(@"M3CLiquidGlass", @"computeIsLiquidGlassAvailable",
                                   (IMP)HookM3CComputeAvailable, &origM3CComputeAvailable);
        BOOL h3 = InstallInstanceHook(@"ASWPhenotypeFlagsImpl", @"AppSwitching__enable_app_switching_liquid_glass",
                                      (IMP)HookFlagAppSwitching, &origFlagAppSwitching);
        BOOL h4 = InstallInstanceHook(@"ASWPhenotypeFlagsImpl", @"AppSwitching__enable_switcher_ui_liquid_glass",
                                      (IMP)HookFlagSwitcherUI, &origFlagSwitcherUI);
        BOOL h5 = InstallInstanceHook(@"ASWPhenotypeFlagsImpl", @"ExperienceKit__enable_experiencekit_liquid_glass",
                                      (IMP)HookFlagExperienceKit, &origFlagExperienceKit);

        LogLine([NSString stringWithFormat:@"HOOKS m3c.is=%@ m3c.compute=%@ flag.appSwitching=%@ flag.switcherUI=%@ flag.experienceKit=%@",
                 h1 ? @"OK" : @"FAIL", h2 ? @"OK" : @"FAIL", h3 ? @"OK" : @"FAIL",
                 h4 ? @"OK" : @"FAIL", h5 ? @"OK" : @"FAIL"]);
        LogLine(@"NOTE read-only: every hooked method returns the original value unchanged");
    }
}
