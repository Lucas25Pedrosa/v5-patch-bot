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
static uintptr_t gTelegramCoreBase = 0;
static uintptr_t gPostboxBase = 0;
static uintptr_t gIQTeleBase = 0;
static NSData *gLastSnapshot;
static dispatch_source_t gTimer;
static NSUncaughtExceptionHandler *gPreviousExceptionHandler = NULL;

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
    NSString *line = [NSString stringWithFormat:@"[SSP] %@ %@\n", Stamp(), message];
    NSLog(@"%@", [line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);
    @synchronized (gLock) {
        int fd = open(gLogPath.fileSystemRepresentation, O_CREAT | O_WRONLY | O_APPEND, 0644);
        if (fd >= 0) {
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (data.length) { (void)write(fd, data.bytes, data.length); (void)fsync(fd); }
            close(fd);
        }
    }
}

static NSString *Hex(const void *address, size_t length) {
    if (!address || !length) return @"";
    const uint8_t *p = address;
    NSMutableString *s = [NSMutableString stringWithCapacity:length * 2];
    for (size_t i = 0; i < length; i++) [s appendFormat:@"%02x", p[i]];
    return s;
}

static void ScanImages(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        uintptr_t base = (uintptr_t)_dyld_get_image_header(i);
        if (strstr(path, "TelegramCoreFramework.framework/TelegramCoreFramework")) gTelegramCoreBase = base;
        else if (strstr(path, "PostboxFramework.framework/PostboxFramework")) gPostboxBase = base;
        else if (strstr(path, "/iQTele.dylib")) gIQTeleBase = base;
    }
    Log([NSString stringWithFormat:@"IMAGES telegramCore=0x%llx postbox=0x%llx iQTele=0x%llx",
         (unsigned long long)gTelegramCoreBase,
         (unsigned long long)gPostboxBase,
         (unsigned long long)gIQTeleBase]);
}

static void Snapshot(BOOL force) {
    if (!gTelegramCoreBase || !gIQTeleBase) ScanImages();
    if (!gTelegramCoreBase || !gIQTeleBase) return;

    const void *target = (const void *)(gTelegramCoreBase + 0x908638);
    const void *messageStub = (const void *)(gIQTeleBase + 0x3C658);
    const void *peerStub = (const void *)(gIQTeleBase + 0x3C67C);
    const void *engineStub = (const void *)(gIQTeleBase + 0x3C6A0);

    NSMutableData *snapshot = [NSMutableData data];
    [snapshot appendBytes:target length:16];
    [snapshot appendBytes:messageStub length:16];
    [snapshot appendBytes:peerStub length:16];
    [snapshot appendBytes:engineStub length:16];

    if (force || !gLastSnapshot || ![gLastSnapshot isEqualToData:snapshot]) {
        Log([NSString stringWithFormat:@"SNAP tc908638=%@ message=%@ peer=%@ enginePeer=%@",
             Hex(target,16), Hex(messageStub,16), Hex(peerStub,16), Hex(engineStub,16)]);
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
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void PresentRecovered(void) {
    if (!gRecovered.length) return;
    UIPasteboard.generalPasteboard.string = gRecovered;
    UIViewController *vc = TopController();
    if (!vc || vc.presentedViewController) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Swiftgram Send Probe"
                                                               message:@"A sessão anterior terminou de forma anormal. O log foi copiado. Envie o log e o novo arquivo .ips."
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
        gLogPath = [documents stringByAppendingPathComponent:@"SwiftgramSendProbe.log"];
        gPreviousPath = [documents stringByAppendingPathComponent:@"SwiftgramSendProbe.previous.log"];

        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        NSString *active = [d stringForKey:@"SwiftgramSendProbeActive"];
        if (active.length && [NSFileManager.defaultManager fileExistsAtPath:gLogPath]) {
            gRecovered = [NSString stringWithContentsOfFile:gLogPath encoding:NSUTF8StringEncoding error:nil];
            if (gRecovered.length) [gRecovered writeToFile:gPreviousPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        [@"" writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [d setObject:NSUUID.UUID.UUIDString forKey:@"SwiftgramSendProbeActive"];
        [d synchronize];

        Log([NSString stringWithFormat:@"INIT v0.1 app=%@ build=%@ os=%@",
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
            [d removeObjectForKey:@"SwiftgramSendProbeActive"];
            [d synchronize];
        }];

        dispatch_queue_t q = dispatch_queue_create("com.lucaspedrosa.swiftgram-send-probe", DISPATCH_QUEUE_SERIAL);
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gTimer, ^{ @autoreleasepool { Snapshot(NO); } });
        dispatch_resume(gTimer);
    }
}
