#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdarg.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

static const char *kSPPVersion = "SwiftgramPostboxProbe 0.1";
static const uintptr_t kTelegramCoreCrashOffset = 0x908638;
static const char *kExpectedTelegramCoreUUID = "d8a0c19b-0918-336a-a542-9e30416542ec";

// Swiftgram 13.0 (319), TelegramCoreFramework UUID D8A0C19B-0918-336A-A542-9E30416542EC.
// On disk TelegramCoreFramework + 0x908638 starts with these bytes. The crash log
// from iOS 27.2 reports EXC_BREAKPOINT/SIGTRAP exactly at this function entry.
static const uint8_t kExpectedTargetBytes[32] = {
    0xfd, 0x7b, 0xbf, 0xa9, 0xfd, 0x03, 0x00, 0x91,
    0xbe, 0x07, 0x00, 0x94, 0xda, 0x07, 0x00, 0x94,
    0x84, 0x0a, 0x40, 0xfa, 0xc1, 0x00, 0x00, 0x54,
    0xac, 0x07, 0x00, 0x94, 0x84, 0x0a, 0x40, 0xfa
};

static NSString *gLogPath;
static NSString *gPreviousLogPath;
static NSString *gRecoveredReport;
static NSObject *gLogLock;
static dispatch_source_t gTimer;
static uintptr_t gTelegramCoreBase = 0;
static uintptr_t gTargetAddress = 0;
static NSString *gTelegramCoreUUID;
static NSData *gLastTargetBytes;
static BOOL gTargetWasEverPatched = NO;
static uint64_t gSampleCount = 0;
static NSUncaughtExceptionHandler *gPreviousExceptionHandler = NULL;

static NSString *SPPStamp(void) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSISO8601DateFormatter new];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    @synchronized (formatter) {
        return [formatter stringFromDate:[NSDate date]];
    }
}

static void SPPLog(const char *format, ...) {
    char message[4096];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);

    @autoreleasepool {
        NSString *line = [NSString stringWithFormat:@"[SPP] %@ %s\n", SPPStamp(), message];
        NSLog(@"%@", [line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);

        if (!gLogPath.length) return;
        @synchronized (gLogLock) {
            int fd = open(gLogPath.fileSystemRepresentation, O_CREAT | O_WRONLY | O_APPEND, 0644);
            if (fd >= 0) {
                NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
                if (data.length > 0) {
                    (void)write(fd, data.bytes, data.length);
                    (void)fsync(fd);
                }
                close(fd);
            }
        }
    }
}

static NSString *SPPHex(const uint8_t *bytes, size_t length) {
    if (!bytes || length == 0) return @"";
    NSMutableString *result = [NSMutableString stringWithCapacity:length * 2];
    for (size_t i = 0; i < length; i++) {
        [result appendFormat:@"%02x", bytes[i]];
    }
    return result;
}

static NSString *SPPUUIDForHeader(const struct mach_header *rawHeader) {
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

static BOOL SPPIsRelevantImagePath(const char *path) {
    if (!path) return NO;
    const char *needles[] = {
        "TelegramCoreFramework",
        "PostboxFramework",
        "SwiftSignalKitFramework",
        "iQTele.dylib",
        "iQSwiftEnhancer.dylib",
        "iQTeleLocation.dylib",
        "iqKeepDeleted.dylib",
        "sideloadFixerLol.dylib",
        "SwiftgramCrack.dylib",
        "zxPluginsInject.dylib",
        "CydiaSubstrate.framework"
    };
    for (size_t i = 0; i < sizeof(needles) / sizeof(needles[0]); i++) {
        if (strstr(path, needles[i])) return YES;
    }
    return NO;
}

static NSString *SPPDescribeAddress(uintptr_t address) {
    if (!address) return @"0x0";
    Dl_info info = {0};
    if (dladdr((const void *)address, &info) && info.dli_fname) {
        NSString *image = [[NSString stringWithUTF8String:info.dli_fname] lastPathComponent] ?: @"?";
        NSString *symbol = info.dli_sname ? [NSString stringWithUTF8String:info.dli_sname] : @"<no-symbol>";
        uintptr_t imageBase = (uintptr_t)info.dli_fbase;
        return [NSString stringWithFormat:@"0x%llx image=%@ imageOffset=0x%llx symbol=%@",
                (unsigned long long)address,
                image,
                (unsigned long long)(address - imageBase),
                symbol ?: @"<no-symbol>"];
    }
    return [NSString stringWithFormat:@"0x%llx image=<unknown>", (unsigned long long)address];
}

static NSString *SPPDecodePatch(const uint8_t bytes[32], uintptr_t pc) {
    uint32_t insn0 = 0;
    uint32_t insn1 = 0;
    memcpy(&insn0, bytes, sizeof(insn0));
    memcpy(&insn1, bytes + 4, sizeof(insn1));

    if ((insn0 & 0xffe0001fU) == 0xd4200000U) {
        uint32_t imm16 = (insn0 >> 5) & 0xffffU;
        return [NSString stringWithFormat:@"BRK immediate=0x%x at exact TelegramCore crash entry", imm16];
    }

    uint32_t branchClass = insn0 & 0xfc000000U;
    if (branchClass == 0x14000000U || branchClass == 0x94000000U) {
        int64_t imm26 = (int64_t)(insn0 & 0x03ffffffU);
        if (imm26 & 0x02000000LL) imm26 |= ~0x03ffffffLL;
        uintptr_t destination = (uintptr_t)((int64_t)pc + (imm26 << 2));
        NSString *kind = (branchClass == 0x94000000U) ? @"BL" : @"B";
        return [NSString stringWithFormat:@"%@ trampoline -> %@", kind, SPPDescribeAddress(destination)];
    }

    // Common arm64 hook trampoline: ldr x16, #literal ; br x16 ; <pointer>.
    if ((insn0 & 0xff00001fU) == 0x58000010U && insn1 == 0xd61f0200U) {
        int64_t imm19 = (int64_t)((insn0 >> 5) & 0x7ffffU);
        if (imm19 & 0x40000LL) imm19 |= ~0x7ffffLL;
        uintptr_t literalAddress = (uintptr_t)((int64_t)pc + (imm19 << 2));
        uintptr_t destination = 0;
        memcpy(&destination, (const void *)literalAddress, sizeof(destination));
        return [NSString stringWithFormat:@"LDR/BR x16 trampoline literal=0x%llx -> %@",
                (unsigned long long)literalAddress,
                SPPDescribeAddress(destination)];
    }

    return [NSString stringWithFormat:@"unknown code mutation firstInsn=0x%08x secondInsn=0x%08x", insn0, insn1];
}

static void SPPSetDiagnosis(NSString *diagnosis, BOOL copyToClipboard) {
    if (!diagnosis.length) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:diagnosis forKey:@"SwiftgramPostboxProbeLastDiagnosis"];
    [defaults synchronize];
    SPPLog("DIAGNOSIS %s", diagnosis.UTF8String);

    if (copyToClipboard) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIPasteboard.generalPasteboard.string = diagnosis;
        });
    }
}

static void SPPScanImages(void) {
    uint32_t count = _dyld_image_count();
    SPPLog("IMAGE_SCAN count=%u", count);

    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!SPPIsRelevantImagePath(path)) continue;

        const struct mach_header *header = _dyld_get_image_header(i);
        NSString *uuid = SPPUUIDForHeader(header);
        uintptr_t base = (uintptr_t)header;
        SPPLog("IMAGE name=%s base=0x%llx uuid=%s path=%s",
               path ? strrchr(path, '/') ? strrchr(path, '/') + 1 : path : "?",
               (unsigned long long)base,
               uuid.UTF8String,
               path ?: "?");

        if (path && strstr(path, "/TelegramCoreFramework.framework/TelegramCoreFramework")) {
            gTelegramCoreBase = base;
            gTelegramCoreUUID = uuid;
            gTargetAddress = base + kTelegramCoreCrashOffset;
        }
    }
}

static void SPPCheckTarget(BOOL forceLog) {
    if (!gTargetAddress) {
        SPPScanImages();
        if (!gTargetAddress) {
            if (forceLog) SPPLog("TARGET TelegramCoreFramework not found yet");
            return;
        }
    }

    uint8_t current[32] = {0};
    memcpy(current, (const void *)gTargetAddress, sizeof(current));
    NSData *currentData = [NSData dataWithBytes:current length:sizeof(current)];
    BOOL changedSinceLastSample = !gLastTargetBytes || ![gLastTargetBytes isEqualToData:currentData];
    BOOL exactBuild = [gTelegramCoreUUID.lowercaseString isEqualToString:[NSString stringWithUTF8String:kExpectedTelegramCoreUUID]];
    BOOL matchesDisk = exactBuild && memcmp(current, kExpectedTargetBytes, sizeof(current)) == 0;

    if (!exactBuild) {
        if (forceLog || changedSinceLastSample) {
            SPPLog("TARGET_BUILD_MISMATCH base=0x%llx address=0x%llx uuid=%s expectedUUID=%s bytes=%s",
                   (unsigned long long)gTelegramCoreBase,
                   (unsigned long long)gTargetAddress,
                   gTelegramCoreUUID.UTF8String,
                   kExpectedTelegramCoreUUID,
                   SPPHex(current, sizeof(current)).UTF8String);
        }
        SPPSetDiagnosis(@"UNKNOWN_TELEGRAMCORE_BUILD: probe cannot compare the crash function safely", NO);
    } else if (matchesDisk) {
        if (forceLog || changedSinceLastSample) {
            SPPLog("TARGET_ORIGINAL TelegramCore+0x%llx address=0x%llx bytes=%s",
                   (unsigned long long)kTelegramCoreCrashOffset,
                   (unsigned long long)gTargetAddress,
                   SPPHex(current, sizeof(current)).UTF8String);
        }
        if (!gTargetWasEverPatched) {
            [NSUserDefaults.standardUserDefaults setObject:@"TARGET_ORIGINAL_SO_FAR" forKey:@"SwiftgramPostboxProbeLastDiagnosis"];
        }
    } else {
        NSString *decoded = SPPDecodePatch(current, gTargetAddress);
        if (forceLog || changedSinceLastSample || !gTargetWasEverPatched) {
            SPPLog("TARGET_PATCHED TelegramCore+0x%llx address=0x%llx bytes=%s decode=%s",
                   (unsigned long long)kTelegramCoreCrashOffset,
                   (unsigned long long)gTargetAddress,
                   SPPHex(current, sizeof(current)).UTF8String,
                   decoded.UTF8String);
        }
        gTargetWasEverPatched = YES;
        NSString *diagnosis = [NSString stringWithFormat:@"DIRECT_RUNTIME_PATCH_DETECTED at TelegramCore+0x908638: %@", decoded];
        SPPSetDiagnosis(diagnosis, YES);
    }

    gLastTargetBytes = currentData;
}

static NSString *SPPOSBuild(void) {
    size_t size = 0;
    if (sysctlbyname("kern.osversion", NULL, &size, NULL, 0) != 0 || size == 0) return @"?";
    char *buffer = calloc(1, size + 1);
    if (!buffer) return @"?";
    NSString *result = @"?";
    if (sysctlbyname("kern.osversion", buffer, &size, NULL, 0) == 0) {
        result = [NSString stringWithUTF8String:buffer] ?: @"?";
    }
    free(buffer);
    return result;
}

static NSString *SPPDeviceModel(void) {
    struct utsname info;
    memset(&info, 0, sizeof(info));
    if (uname(&info) != 0) return @"?";
    return [NSString stringWithUTF8String:info.machine] ?: @"?";
}

static void SPPUncaughtException(NSException *exception) {
    SPPLog("UNCAUGHT_OBJC_EXCEPTION name=%s reason=%s stack=%s",
           exception.name.UTF8String,
           (exception.reason ?: @"<none>").UTF8String,
           [[exception.callStackSymbols componentsJoinedByString:@" | "] UTF8String]);
    SPPSetDiagnosis([NSString stringWithFormat:@"UNCAUGHT_OBJC_EXCEPTION: %@ — %@", exception.name, exception.reason ?: @"<no reason>"], YES);

    if (gPreviousExceptionHandler && gPreviousExceptionHandler != SPPUncaughtException) {
        gPreviousExceptionHandler(exception);
    }
}

static UIViewController *SPPTopViewController(void) {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateUnattached) continue;
            for (UIWindow *candidate in windowScene.windows) {
                if (candidate.isKeyWindow) {
                    window = candidate;
                    break;
                }
                if (!window && !candidate.hidden) window = candidate;
            }
            if (window.isKeyWindow) break;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!window) window = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop

    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    if ([controller isKindOfClass:UINavigationController.class]) {
        controller = ((UINavigationController *)controller).visibleViewController ?: controller;
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        controller = ((UITabBarController *)controller).selectedViewController ?: controller;
    }
    return controller;
}

static void SPPPresentRecoveredReport(void) {
    if (!gRecoveredReport.length) return;
    UIPasteboard.generalPasteboard.string = gRecoveredReport;
    UIViewController *controller = SPPTopViewController();
    if (!controller || controller.presentedViewController) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Swiftgram Probe"
                                                                   message:@"The previous diagnostic session did not end normally. Its probe log was copied to the clipboard. Paste/send it for analysis."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void SPPInstallLifecycleLogging(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        SPPLog("LIFECYCLE didBecomeActive state=%ld", (long)UIApplication.sharedApplication.applicationState);
        SPPCheckTarget(YES);
    }];
    [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        SPPLog("LIFECYCLE willResignActive");
        SPPCheckTarget(YES);
    }];
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        SPPLog("LIFECYCLE didEnterBackground");
        SPPCheckTarget(YES);
    }];
    [center addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        SPPLog("LIFECYCLE memoryWarning");
        SPPCheckTarget(YES);
    }];
    [center addObserverForName:UIApplicationWillTerminateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        SPPLog("LIFECYCLE willTerminate clean=true");
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SwiftgramPostboxProbeActiveSession"];
        [NSUserDefaults.standardUserDefaults synchronize];
    }];
}

static void SPPStartMonitor(void) {
    dispatch_queue_t queue = dispatch_queue_create("com.lucaspedrosa.swiftgram-postbox-probe", DISPATCH_QUEUE_SERIAL);
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    if (!gTimer) return;

    dispatch_source_set_timer(gTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(50 * NSEC_PER_MSEC),
                              (uint64_t)(10 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(gTimer, ^{
        @autoreleasepool {
            gSampleCount++;
            SPPCheckTarget(NO);
            if ((gSampleCount % 40) == 0) {
                NSString *diagnosis = [NSUserDefaults.standardUserDefaults stringForKey:@"SwiftgramPostboxProbeLastDiagnosis"] ?: @"?";
                SPPLog("HEARTBEAT samples=%llu target=%s appState=%ld",
                       (unsigned long long)gSampleCount,
                       diagnosis.UTF8String,
                       (long)UIApplication.sharedApplication.applicationState);
            }
        }
    });
    dispatch_resume(gTimer);
}

__attribute__((constructor))
static void SPPInit(void) {
    @autoreleasepool {
        NSString *bundleId = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *exe = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
        if (![bundleId isEqualToString:@"app.swiftgram.ios"] && ![exe isEqualToString:@"Swiftgram"]) return;

        gLogLock = [NSObject new];
        NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        (void)[NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
        gLogPath = [documents stringByAppendingPathComponent:@"SwiftgramPostboxProbe.log"];
        gPreviousLogPath = [documents stringByAppendingPathComponent:@"SwiftgramPostboxProbe.previous.log"];

        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *previousSession = [defaults stringForKey:@"SwiftgramPostboxProbeActiveSession"];
        if (previousSession.length && [NSFileManager.defaultManager fileExistsAtPath:gLogPath]) {
            gRecoveredReport = [NSString stringWithContentsOfFile:gLogPath encoding:NSUTF8StringEncoding error:nil];
            if (gRecoveredReport.length) {
                [gRecoveredReport writeToFile:gPreviousLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }

        [@"" writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSString *session = NSUUID.UUID.UUIDString;
        [defaults setObject:session forKey:@"SwiftgramPostboxProbeActiveSession"];
        [defaults setObject:@"STARTING" forKey:@"SwiftgramPostboxProbeLastDiagnosis"];
        [defaults synchronize];

        NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
        NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
        NSString *build = [info[@"CFBundleVersion"] description] ?: @"?";
        SPPLog("PROBE_START version=%s session=%s", kSPPVersion, session.UTF8String);
        SPPLog("APP bundle=%s exe=%s version=%s build=%s", bundleId.UTF8String, exe.UTF8String, version.UTF8String, build.UTF8String);
        SPPLog("DEVICE model=%s iOS=%s build=%s", SPPDeviceModel().UTF8String, UIDevice.currentDevice.systemVersion.UTF8String, SPPOSBuild().UTF8String);
        SPPLog("CRASH_SIGNATURE expected=EXC_BREAKPOINT/SIGTRAP queue=org.telegram.postbox.Postbox TelegramCore+0x%llx", (unsigned long long)kTelegramCoreCrashOffset);

        SPPScanImages();
        SPPCheckTarget(YES);

        gPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(SPPUncaughtException);
        SPPInstallLifecycleLogging();
        SPPStartMonitor();

        if (gRecoveredReport.length) {
            SPPLog("RECOVERY previousSession=%s previousLogBytes=%llu previousLog=%s",
                   previousSession.UTF8String,
                   (unsigned long long)[gRecoveredReport lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                   gPreviousLogPath.UTF8String);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                SPPPresentRecoveredReport();
            });
        }
    }
}
