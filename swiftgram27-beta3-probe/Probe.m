#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <fcntl.h>
#import <unistd.h>

static NSString *gLogPath;
static NSString *gPreviousPath;
static NSString *gRecovered;
static NSObject *gLock;
static dispatch_source_t gTimer;
static NSData *gLastSnapshot;
static uintptr_t gTelegramCoreBase = 0;
static uintptr_t gIQTeleBase = 0;
static NSString *gTelegramCoreUUID;
static NSString *gIQTeleUUID;
static NSUncaughtExceptionHandler *gPreviousExceptionHandler = NULL;
static BOOL gSawBrk22 = NO;

static const uintptr_t kTelegramCoreGetterOffset = 0x908638;
static const uintptr_t kIQTelePeerHookCallOffset = 0x3C52C;
static const uintptr_t kIQTelePeerReplacementOffset = 0x3C67C;

static const uint8_t kTelegramCoreDirectFalse[8] = {
    0x00, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6
};
static const uint8_t kIQTeleHookNop[4] = {0x1f, 0x20, 0x03, 0xd5};
static const uint8_t kBrk22[4] = {0x40, 0x04, 0x20, 0xd4};

static NSString *Stamp(void) {
    static NSISO8601DateFormatter *f;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        f = [NSISO8601DateFormatter new];
        f.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    @synchronized (f) { return [f stringFromDate:[NSDate date]]; }
}

static void Log(NSString *message) {
    if (!message.length || !gLogPath.length) return;
    NSString *line = [NSString stringWithFormat:@"[B3P] %@ %@\n", Stamp(), message];
    NSLog(@"%@", [line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);
    @synchronized (gLock) {
        int fd = open(gLogPath.fileSystemRepresentation, O_CREAT | O_WRONLY | O_APPEND, 0644);
        if (fd >= 0) {
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (data.length) {
                (void)write(fd, data.bytes, data.length);
                (void)fsync(fd);
            }
            close(fd);
        }
    }
}

static NSString *Hex(const void *address, size_t length) {
    if (!address || !length) return @"";
    const uint8_t *p = (const uint8_t *)address;
    NSMutableString *s = [NSMutableString stringWithCapacity:length * 2];
    for (size_t i = 0; i < length; i++) [s appendFormat:@"%02x", p[i]];
    return s;
}

static NSString *UUIDForHeader(const struct mach_header *rawHeader) {
    if (!rawHeader || rawHeader->magic != MH_MAGIC_64) return @"<unsupported>";
    const struct mach_header_64 *header = (const struct mach_header_64 *)rawHeader;
    const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) break;
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuidCommand = (const struct uuid_command *)command;
            const uint8_t *u = uuidCommand->uuid;
            return [NSString stringWithFormat:
                    @"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                    u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
                    u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]];
        }
        cursor += command->cmdsize;
    }
    return @"<none>";
}

static void ScanImages(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        const struct mach_header *header = _dyld_get_image_header(i);
        uintptr_t base = (uintptr_t)header;
        if (strstr(path, "TelegramCoreFramework.framework/TelegramCoreFramework")) {
            gTelegramCoreBase = base;
            gTelegramCoreUUID = UUIDForHeader(header);
        } else if (strstr(path, "/iQTele.dylib")) {
            gIQTeleBase = base;
            gIQTeleUUID = UUIDForHeader(header);
        }
    }
    Log([NSString stringWithFormat:@"IMAGES telegramCore=0x%llx uuid=%@ iQTele=0x%llx uuid=%@",
         (unsigned long long)gTelegramCoreBase,
         gTelegramCoreUUID ?: @"?",
         (unsigned long long)gIQTeleBase,
         gIQTeleUUID ?: @"?"]);
}

static void Snapshot(BOOL force) {
    if (!gTelegramCoreBase || !gIQTeleBase) ScanImages();
    if (!gTelegramCoreBase || !gIQTeleBase) return;

    const uint8_t *getter = (const uint8_t *)(gTelegramCoreBase + kTelegramCoreGetterOffset);
    const uint8_t *hookCall = (const uint8_t *)(gIQTeleBase + kIQTelePeerHookCallOffset);
    const uint8_t *replacement = (const uint8_t *)(gIQTeleBase + kIQTelePeerReplacementOffset);

    NSMutableData *snapshot = [NSMutableData data];
    [snapshot appendBytes:getter length:16];
    [snapshot appendBytes:hookCall length:16];
    [snapshot appendBytes:replacement length:16];

    BOOL changed = !gLastSnapshot || ![gLastSnapshot isEqualToData:snapshot];
    BOOL getterOK = memcmp(getter, kTelegramCoreDirectFalse, sizeof(kTelegramCoreDirectFalse)) == 0;
    BOOL hookOK = memcmp(hookCall, kIQTeleHookNop, sizeof(kIQTeleHookNop)) == 0;
    BOOL brk22 = memcmp(getter, kBrk22, sizeof(kBrk22)) == 0;

    if (brk22 && !gSawBrk22) {
        gSawBrk22 = YES;
        Log(@"ALERT BRK22_SEEN_AT_TELEGRAMCORE_PEER_GETTER");
        UIPasteboard.generalPasteboard.string = @"BRK22_SEEN_AT_TELEGRAMCORE_PEER_GETTER";
    }

    if (force || changed) {
        NSString *state = getterOK && hookOK ? @"BETA3_LAYOUT_OK" :
                          (!getterOK && !hookOK ? @"BETA3_BOTH_MISSING" :
                           (!getterOK ? @"BETA3_TELEGRAMCORE_PATCH_MISSING" : @"BETA3_IQTELE_HOOK_NOT_SUPPRESSED"));
        Log([NSString stringWithFormat:@"STATE %@ getter=%@ hookCall=%@ replacement=%@",
             state, Hex(getter, 16), Hex(hookCall, 16), Hex(replacement, 16)]);
    }

    gLastSnapshot = snapshot;
}

static void UncaughtException(NSException *exception) {
    Log([NSString stringWithFormat:@"UNCAUGHT name=%@ reason=%@ stack=%@",
         exception.name ?: @"?",
         exception.reason ?: @"?",
         [exception.callStackSymbols componentsJoinedByString:@" | "]]);
    if (gPreviousExceptionHandler && gPreviousExceptionHandler != UncaughtException) {
        gPreviousExceptionHandler(exception);
    }
}

static UIViewController *TopController(void) {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) { window = candidate; break; }
                if (!window && !candidate.hidden) window = candidate;
            }
            if (window.isKeyWindow) break;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!window) window = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void PresentRecovered(void) {
    if (!gRecovered.length) return;
    UIPasteboard.generalPasteboard.string = gRecovered;
    UIViewController *vc = TopController();
    if (!vc || vc.presentedViewController) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Swiftgram Beta 3 Probe"
                                                               message:@"A sessão anterior terminou sem encerramento limpo. O log anterior foi copiado. Envie-o junto do .ips caso tenha ocorrido crash."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

__attribute__((constructor))
static void Init(void) {
    @autoreleasepool {
        NSString *bundleId = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *exe = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
        if (![bundleId isEqualToString:@"app.swiftgram.ios"] && ![exe isEqualToString:@"Swiftgram"]) return;

        gLock = [NSObject new];
        NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        (void)[NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
        gLogPath = [documents stringByAppendingPathComponent:@"Swiftgram27Beta3Probe.log"];
        gPreviousPath = [documents stringByAppendingPathComponent:@"Swiftgram27Beta3Probe.previous.log"];

        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        NSString *active = [d stringForKey:@"Swiftgram27Beta3ProbeActive"];
        if (active.length && [NSFileManager.defaultManager fileExistsAtPath:gLogPath]) {
            gRecovered = [NSString stringWithContentsOfFile:gLogPath encoding:NSUTF8StringEncoding error:nil];
            if (gRecovered.length) [gRecovered writeToFile:gPreviousPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        [@"" writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [d setObject:NSUUID.UUID.UUIDString forKey:@"Swiftgram27Beta3ProbeActive"];
        [d synchronize];

        Log([NSString stringWithFormat:@"INIT Swiftgram27Beta3Probe 0.1 app=%@ build=%@ os=%@",
             [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
             [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?",
             UIDevice.currentDevice.systemVersion ?: @"?"]);
        ScanImages();
        Snapshot(YES);

        gPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(UncaughtException);

        NSNotificationCenter *c = NSNotificationCenter.defaultCenter;
        [c addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
            Log(@"LIFECYCLE didBecomeActive");
            Snapshot(YES);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ PresentRecovered(); });
        }];
        [c addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
            Log(@"LIFECYCLE willResignActive");
            Snapshot(YES);
        }];
        [c addObserverForName:UIApplicationWillTerminateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
            Log(@"LIFECYCLE willTerminate clean=true");
            [d removeObjectForKey:@"Swiftgram27Beta3ProbeActive"];
            [d synchronize];
        }];

        dispatch_queue_t q = dispatch_queue_create("com.lucaspedrosa.swiftgram27-beta3-probe", DISPATCH_QUEUE_SERIAL);
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gTimer, ^{ @autoreleasepool { Snapshot(NO); } });
        dispatch_resume(gTimer);
    }
}
