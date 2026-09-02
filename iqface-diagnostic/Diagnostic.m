#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <signal.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <time.h>
#import <unistd.h>

static char IQDLogPath[PATH_MAX] = {0};
static BOOL IQDPanelPresented = NO;

static void IQDAppendBytes(const char *bytes, size_t length) {
    if (IQDLogPath[0] == '\0' || bytes == NULL || length == 0) {
        return;
    }

    int descriptor = open(IQDLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (descriptor < 0) {
        return;
    }

    size_t written = 0;
    while (written < length) {
        ssize_t result = write(descriptor, bytes + written, length - written);
        if (result <= 0) {
            break;
        }
        written += (size_t)result;
    }
    fsync(descriptor);
    close(descriptor);
}

static void IQDLog(const char *format, ...) {
    if (format == NULL) {
        return;
    }

    char message[3072] = {0};
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(message, sizeof(message), format, arguments);
    va_end(arguments);

    struct timeval value;
    gettimeofday(&value, NULL);
    struct tm localTime;
    localtime_r(&value.tv_sec, &localTime);

    char timestamp[64] = {0};
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", &localTime);

    char line[3328] = {0};
    int length = snprintf(line,
                          sizeof(line),
                          "[%s.%03d] %s\n",
                          timestamp,
                          (int)(value.tv_usec / 1000),
                          message);
    if (length > 0) {
        IQDAppendBytes(line, (size_t)MIN(length, (int)sizeof(line) - 1));
    }
}

static void IQDPrepareLog(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                               NSUserDomainMask,
                                                               YES).firstObject;
    if (documents.length == 0) {
        documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    }

    NSString *directory = [documents stringByAppendingPathComponent:@"iQFaceDiagnostic"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];

    NSString *path = [directory stringByAppendingPathComponent:@"iQFaceDiagnostic.log"];
    strlcpy(IQDLogPath, path.fileSystemRepresentation, sizeof(IQDLogPath));
}

static void IQDSignalHandler(int signalNumber) {
    const char *message = "[FATAL] sinal desconhecido recebido\n";
    size_t length = strlen(message);

    switch (signalNumber) {
        case SIGABRT:
            message = "[FATAL] SIGABRT recebido\n";
            length = sizeof("[FATAL] SIGABRT recebido\n") - 1;
            break;
        case SIGSEGV:
            message = "[FATAL] SIGSEGV recebido\n";
            length = sizeof("[FATAL] SIGSEGV recebido\n") - 1;
            break;
        case SIGBUS:
            message = "[FATAL] SIGBUS recebido\n";
            length = sizeof("[FATAL] SIGBUS recebido\n") - 1;
            break;
        case SIGILL:
            message = "[FATAL] SIGILL recebido\n";
            length = sizeof("[FATAL] SIGILL recebido\n") - 1;
            break;
        case SIGTRAP:
            message = "[FATAL] SIGTRAP recebido\n";
            length = sizeof("[FATAL] SIGTRAP recebido\n") - 1;
            break;
    }

    IQDAppendBytes(message, length);
    _exit(128 + signalNumber);
}

static void IQDInstallSignalHandlers(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = IQDSignalHandler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;

    sigaction(SIGABRT, &action, NULL);
    sigaction(SIGSEGV, &action, NULL);
    sigaction(SIGBUS, &action, NULL);
    sigaction(SIGILL, &action, NULL);
    sigaction(SIGTRAP, &action, NULL);
}

static void IQDExceptionHandler(NSException *exception) {
    IQDLog("EXCEPTION name=%s reason=%s",
           exception.name.UTF8String ?: "(null)",
           exception.reason.UTF8String ?: "(null)");
    for (NSString *entry in exception.callStackSymbols) {
        IQDLog("STACK %s", entry.UTF8String ?: "(null)");
    }
}

static void *IQDFindSymbol(const char *name) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol != NULL) {
        return symbol;
    }

    char underscored[128] = {0};
    if (strlen(name) + 2 < sizeof(underscored)) {
        underscored[0] = '_';
        strlcpy(underscored + 1, name, sizeof(underscored) - 1);
        symbol = dlsym(RTLD_DEFAULT, underscored);
    }
    return symbol;
}

static void IQDLogFile(NSString *label, NSString *relativePath) {
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:relativePath];
    BOOL isDirectory = NO;
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory];
    IQDLog("FILE %s exists=%s directory=%s path=%s",
           label.UTF8String,
           exists ? "yes" : "no",
           isDirectory ? "yes" : "no",
           path.UTF8String);
}

static void IQDLogImages(void) {
    BOOL foundIQFace = NO;
    BOOL foundSubstrate = NO;
    BOOL foundZX = NO;
    BOOL foundEnhancer = NO;
    uint32_t count = _dyld_image_count();

    for (uint32_t index = 0; index < count; index++) {
        const char *name = _dyld_get_image_name(index);
        if (name == NULL) {
            continue;
        }

        if (strstr(name, "iQFace.dylib") != NULL) {
            foundIQFace = YES;
            IQDLog("IMAGE iQFace=%s", name);
        }
        if (strstr(name, "CydiaSubstrate") != NULL || strstr(name, "libellekit") != NULL) {
            foundSubstrate = YES;
            IQDLog("IMAGE substrate=%s", name);
        }
        if (strstr(name, "zxPluginsInject.dylib") != NULL) {
            foundZX = YES;
            IQDLog("IMAGE zx=%s", name);
        }
        if (strstr(name, "iQFaceEnhancer.dylib") != NULL) {
            foundEnhancer = YES;
            IQDLog("IMAGE enhancer=%s", name);
        }
    }

    IQDLog("IMAGE SUMMARY count=%u iqface=%s substrate=%s zx=%s enhancer=%s",
           count,
           foundIQFace ? "yes" : "no",
           foundSubstrate ? "yes" : "no",
           foundZX ? "yes" : "no",
           foundEnhancer ? "yes" : "no");
}

static void IQDLogSymbols(void) {
    const char *symbols[] = {
        "IQFLoc",
        "IQFPresentSettings",
        "IQFSettingsVisible",
        "MSHookFunction"
    };

    for (NSUInteger index = 0; index < sizeof(symbols) / sizeof(symbols[0]); index++) {
        void *address = IQDFindSymbol(symbols[index]);
        IQDLog("SYMBOL %s=%s address=%p",
               symbols[index],
               address != NULL ? "yes" : "no",
               address);
    }
}

static UIWindow *IQDKeyWindow(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow) {
            return window;
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static UIViewController *IQDTopController(UIViewController *controller) {
    if (controller == nil) {
        return nil;
    }
    if (controller.presentedViewController != nil) {
        return IQDTopController(controller.presentedViewController);
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return IQDTopController(((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return IQDTopController(((UITabBarController *)controller).selectedViewController);
    }
    return controller;
}

static NSString *IQDLogContents(void) {
    NSString *path = [NSString stringWithUTF8String:IQDLogPath];
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
}

static void IQDShareLog(UIViewController *controller) {
    NSString *path = [NSString stringWithUTF8String:IQDLogPath];
    NSURL *URL = [NSURL fileURLWithPath:path];
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[URL]
        applicationActivities:nil];
    UIPopoverPresentationController *popover = activity.popoverPresentationController;
    if (popover != nil) {
        popover.sourceView = controller.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds),
                                        CGRectGetMidY(controller.view.bounds),
                                        1.0,
                                        1.0);
    }
    [controller presentViewController:activity animated:YES completion:nil];
}

static void IQDPresentPanel(void) {
    if (IQDPanelPresented || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        return;
    }

    UIViewController *controller = IQDTopController(IQDKeyWindow().rootViewController);
    if (controller == nil || [controller isKindOfClass:UIAlertController.class]) {
        IQDLog("PANEL postponed: no suitable controller");
        return;
    }

    IQDPanelPresented = YES;
    IQDLog("PANEL presenting");
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"iQFace Diagnostic"
                         message:@"O diagnóstico foi salvo. Copie ou compartilhe o arquivo para análise."
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Copiar log"
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = IQDLogContents();
        IQDLog("PANEL log copied");
    }]];
    [alert addAction:[UIAlertAction
        actionWithTitle:@"Compartilhar arquivo"
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
        IQDLog("PANEL share requested");
        dispatch_async(dispatch_get_main_queue(), ^{
            IQDShareLog(controller);
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Fechar"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [controller presentViewController:alert
                             animated:YES
                           completion:^{
        IQDLog("PANEL presented");
    }];
}

static void IQDApplicationDidBecomeActive(NSNotification *notification) {
    (void)notification;
    IQDLog("APPLICATION didBecomeActive");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IQDLogImages();
        IQDLogSymbols();
        IQDPresentPanel();
    });
}

__attribute__((constructor))
static void IQDInitialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        IQDPrepareLog();
        IQDInstallSignalHandlers();
        NSSetUncaughtExceptionHandler(&IQDExceptionHandler);

        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
        IQDLog("START iQFace Diagnostic 0.1.0");
        IQDLog("PROCESS pid=%d mainThread=%s", getpid(), NSThread.isMainThread ? "yes" : "no");
        IQDLog("APP bundle=%s version=%s build=%s",
               bundleIdentifier.UTF8String,
               version.UTF8String ?: "(null)",
               build.UTF8String ?: "(null)");
        IQDLog("SYSTEM version=%s home=%s log=%s",
               UIDevice.currentDevice.systemVersion.UTF8String,
               NSHomeDirectory().UTF8String,
               IQDLogPath);

        IQDLogFile(@"iQFace", @"Frameworks/iQFace.dylib");
        IQDLogFile(@"CydiaSubstrate", @"Frameworks/CydiaSubstrate.framework/CydiaSubstrate");
        IQDLogFile(@"zxPluginsInject", @"Frameworks/zxPluginsInject.dylib");
        IQDLogFile(@"iQFaceEnhancer", @"Frameworks/iQFaceEnhancer.dylib");
        IQDLogImages();
        IQDLogSymbols();

        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *notification) {
            IQDApplicationDidBecomeActive(notification);
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            IQDLog("MAIN QUEUE reached state=%ld", (long)UIApplication.sharedApplication.applicationState);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                IQDLog("MAIN QUEUE six-second checkpoint");
                IQDLogImages();
                IQDLogSymbols();
                IQDPresentPanel();
            });
        });
    }
}
