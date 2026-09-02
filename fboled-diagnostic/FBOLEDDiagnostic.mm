#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

// FBOLED Diagnostic 0.1
// Target verified against Facebook 577.0.0 / FBSharedFramework.
// This build is DIAGNOSTIC ONLY: it never changes a Facebook color.

static NSString * const kFBOLEDVersion = @"0.1.0";
static const NSInteger kMaxInstallAttempts = 20;
static const NSTimeInterval kRetryDelaySeconds = 0.50;

typedef void (*MSHookFunction_t)(void *symbol, void *replace, void **result);
typedef UIColor *(*FDSUsageColorFn)(int usageColor);
typedef UIColor *(*FDSUsageColorThemeFn)(int usageColor, void *theme);
typedef bool (*FDSIsDarkModeFn)(void);

static FDSUsageColorFn gOrigUsageColor = nullptr;
static FDSUsageColorThemeFn gOrigUsageColorWithTheme = nullptr;
static FDSIsDarkModeFn gIsDarkMode = nullptr;
static MSHookFunction_t gMSHookFunction = nullptr;

static dispatch_queue_t gLogQueue;
static NSMutableSet<NSString *> *gSeen;
static NSString *gLogPath;
static BOOL gHooksInstalled = NO;
static NSInteger gInstallAttempt = 0;

static NSString *FBOLEDTimestamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    @synchronized (formatter) {
        return [formatter stringFromDate:[NSDate date]];
    }
}

static void FBOLEDAppendLine(NSString *line) {
    if (!line || !gLogPath) return;
    dispatch_async(gLogQueue, ^{
        @autoreleasepool {
            NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
            if (![[NSFileManager defaultManager] fileExistsAtPath:gLogPath]) {
                [data writeToFile:gLogPath atomically:YES];
                return;
            }
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
            if (!handle) return;
            @try {
                [handle seekToEndOfFile];
                [handle writeData:data];
                [handle synchronizeFile];
            } @catch (__unused NSException *e) {
            }
            [handle closeFile];
        }
    });
}

static NSString *FBOLEDHexForResolvedColor(UIColor *input,
                                           CGFloat *outR,
                                           CGFloat *outG,
                                           CGFloat *outB,
                                           CGFloat *outA) {
    if (!input) return @"<nil>";

    UIColor *color = input;
    if (@available(iOS 13.0, *)) {
        UITraitCollection *dark = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark];
        color = [input resolvedColorWithTraitCollection:dark];
    }

    CGFloat r = 0, g = 0, b = 0, a = 0;
    BOOL ok = [color getRed:&r green:&g blue:&b alpha:&a];
    if (!ok) {
        CGFloat white = 0;
        if ([color getWhite:&white alpha:&a]) {
            r = g = b = white;
            ok = YES;
        }
    }

    if (!ok) return @"<unresolved>";
    if (outR) *outR = r;
    if (outG) *outG = g;
    if (outB) *outB = b;
    if (outA) *outA = a;

    int R = (int)(MAX(0.0, MIN(1.0, r)) * 255.0 + 0.5);
    int G = (int)(MAX(0.0, MIN(1.0, g)) * 255.0 + 0.5);
    int B = (int)(MAX(0.0, MIN(1.0, b)) * 255.0 + 0.5);
    int A = (int)(MAX(0.0, MIN(1.0, a)) * 255.0 + 0.5);
    return [NSString stringWithFormat:@"#%02X%02X%02X%02X", R, G, B, A];
}

static BOOL FBOLEDIsDarkMode(void) {
    if (gIsDarkMode) {
        @try {
            return gIsDarkMode() ? YES : NO;
        } @catch (__unused NSException *e) {
        }
    }
    if (@available(iOS 13.0, *)) {
        return UIScreen.mainScreen.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return YES;
}

static void FBOLEDRecordColor(const char *source, int usageColor, UIColor *color, void *theme) {
    if (!FBOLEDIsDarkMode()) return;

    CGFloat r = 0, g = 0, b = 0, a = 0;
    NSString *hex = FBOLEDHexForResolvedColor(color, &r, &g, &b, &a);
    NSString *sourceString = source ? [NSString stringWithUTF8String:source] : @"unknown";
    NSString *uniqueKey = [NSString stringWithFormat:@"%@|%d|%@|%p", sourceString, usageColor, hex, theme];

    @synchronized (gSeen) {
        if ([gSeen containsObject:uniqueKey]) return;
        [gSeen addObject:uniqueKey];
    }

    BOOL darkSurfaceCandidate = (a >= 0.90 && r <= 0.40 && g <= 0.40 && b <= 0.40);
    NSString *className = color ? NSStringFromClass(color.class) : @"<nil>";

    NSString *line = [NSString stringWithFormat:
                      @"%@,%@,%d,%@,%.6f,%.6f,%.6f,%.6f,%d,%p,%@",
                      FBOLEDTimestamp(), sourceString, usageColor, hex,
                      r, g, b, a, darkSurfaceCandidate ? 1 : 0, theme, className];
    FBOLEDAppendLine(line);
}

static UIColor *FBOLEDUsageColorHook(int usageColor) {
    UIColor *result = gOrigUsageColor ? gOrigUsageColor(usageColor) : nil;
    FBOLEDRecordColor("UsageColor", usageColor, result, nullptr);
    return result;
}

static UIColor *FBOLEDUsageColorWithThemeHook(int usageColor, void *theme) {
    UIColor *result = gOrigUsageColorWithTheme ? gOrigUsageColorWithTheme(usageColor, theme) : nil;
    FBOLEDRecordColor("UsageColorWithTheme", usageColor, result, theme);
    return result;
}

static void *FBOLEDFindSymbol(const char *name) {
    if (!name) return nullptr;
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol) return symbol;

    NSString *frameworkPath = [[NSBundle mainBundle] pathForResource:@"FBSharedFramework"
                                                               ofType:nil
                                                          inDirectory:@"Frameworks/FBSharedFramework.framework"];
    if (frameworkPath.length > 0) {
        void *handle = dlopen(frameworkPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
        if (handle) symbol = dlsym(handle, name);
    }
    return symbol;
}

static void FBOLEDInstallHooks(void);

static void FBOLEDScheduleRetry(void) {
    if (gHooksInstalled || gInstallAttempt >= kMaxInstallAttempts) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetryDelaySeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        FBOLEDInstallHooks();
    });
}

static void FBOLEDInstallHooks(void) {
    if (gHooksInstalled) return;
    gInstallAttempt++;

    if (!gMSHookFunction) {
        gMSHookFunction = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
    }

    void *usage = FBOLEDFindSymbol("_ZN3FDS10UsageColorENS_10UsageColorE");
    void *usageTheme = FBOLEDFindSymbol("_ZN3FDS10UsageColorENS_10UsageColorEP8FDSTheme");
    gIsDarkMode = (FDSIsDarkModeFn)FBOLEDFindSymbol("_ZN3FDS26IsDarkModeCurrentlyEnabledEv");

    if (!gMSHookFunction || !usage || !usageTheme) {
        FBOLEDAppendLine([NSString stringWithFormat:
                         @"# %@ install attempt=%ld hookEngine=%d usage=%d usageTheme=%d darkModeFn=%d",
                         FBOLEDTimestamp(), (long)gInstallAttempt,
                         gMSHookFunction != nullptr, usage != nullptr, usageTheme != nullptr,
                         gIsDarkMode != nullptr]);
        FBOLEDScheduleRetry();
        return;
    }

    gMSHookFunction(usage, (void *)&FBOLEDUsageColorHook, (void **)&gOrigUsageColor);
    gMSHookFunction(usageTheme, (void *)&FBOLEDUsageColorWithThemeHook, (void **)&gOrigUsageColorWithTheme);
    gHooksInstalled = YES;

    FBOLEDAppendLine([NSString stringWithFormat:
                     @"# %@ hooks installed successfully; Facebook 577 FDS diagnostic active",
                     FBOLEDTimestamp()]);
}

__attribute__((constructor)) static void FBOLEDInit(void) {
    @autoreleasepool {
        gLogQueue = dispatch_queue_create("com.fboled.diagnostic.log", DISPATCH_QUEUE_SERIAL);
        gSeen = [NSMutableSet set];

        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *directory = [documents stringByAppendingPathComponent:@"FBOLED"];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        gLogPath = [directory stringByAppendingPathComponent:@"FBOLED_Diagnostic.csv"];

        if (![[NSFileManager defaultManager] fileExistsAtPath:gLogPath]) {
            NSString *header = @"timestamp,source,usage_color,rgba_hex,r,g,b,a,dark_surface_candidate,theme_ptr,color_class\n";
            [header writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }

        FBOLEDAppendLine([NSString stringWithFormat:
                         @"# %@ START FBOLED Diagnostic %@ bundle=%@ appVersion=%@ build=%@",
                         FBOLEDTimestamp(), kFBOLEDVersion,
                         NSBundle.mainBundle.bundleIdentifier ?: @"?",
                         [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
                         [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"]]);

        FBOLEDInstallHooks();
    }
}
