#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// FBCacheCleaner 0.1.0
// Conservative cleaner based on FBCacheDiagnostic results from Facebook 577.1.0.
// It ONLY clears the contents of these validated cache directories:
//   Library/Caches/cask
//   Library/Caches/com.facebook.Facebook.MosaicIGImageDiskCache
// It never touches Documents, Application Support, Cookies, Preferences, or Keychain.

static const void *kFBCCGestureKey = &kFBCCGestureKey;

static NSString *FBCCHumanBytes(unsigned long long bytes) {
    static NSArray<NSString *> *units;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        units = @[@"B", @"KB", @"MB", @"GB", @"TB"];
    });

    double value = (double)bytes;
    NSUInteger unit = 0;
    while (value >= 1024.0 && unit + 1 < units.count) {
        value /= 1024.0;
        unit++;
    }
    return [NSString stringWithFormat:(unit == 0 ? @"%.0f %@" : @"%.2f %@"), value, units[unit]];
}

static unsigned long long FBCCDirectorySize(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory]) return 0;

    if (!isDirectory) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        return [attrs[NSFileSize] unsignedLongLongValue];
    }

    unsigned long long total = 0;
    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:path];
    for (NSString *relative in enumerator) {
        @autoreleasepool {
            NSString *fullPath = [path stringByAppendingPathComponent:relative];
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            if ([attrs[NSFileType] isEqual:NSFileTypeRegular]) {
                total += [attrs[NSFileSize] unsignedLongLongValue];
            }
        }
    }
    return total;
}

static NSArray<NSString *> *FBCCTargetPaths(void) {
    NSString *home = NSHomeDirectory();
    return @[
        [home stringByAppendingPathComponent:@"Library/Caches/cask"],
        [home stringByAppendingPathComponent:@"Library/Caches/com.facebook.Facebook.MosaicIGImageDiskCache"]
    ];
}

static unsigned long long FBCCTotalTargetSize(void) {
    unsigned long long total = 0;
    for (NSString *path in FBCCTargetPaths()) {
        total += FBCCDirectorySize(path);
    }
    return total;
}

static NSUInteger FBCCClearContentsOfDirectory(NSString *path, NSMutableArray<NSString *> *errors) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) return 0;

    NSError *listError = nil;
    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:path error:&listError];
    if (!children) {
        if (listError) [errors addObject:[NSString stringWithFormat:@"%@ — %@", path.lastPathComponent, listError.localizedDescription]];
        return 0;
    }

    NSUInteger removed = 0;
    for (NSString *child in children) {
        NSString *childPath = [path stringByAppendingPathComponent:child];
        NSError *removeError = nil;
        if ([fm removeItemAtPath:childPath error:&removeError]) {
            removed++;
        } else if (removeError) {
            [errors addObject:[NSString stringWithFormat:@"%@/%@ — %@", path.lastPathComponent, child, removeError.localizedDescription]];
        }
    }
    return removed;
}

static UIWindow *FBCCKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) return window;
            }
            for (UIWindow *window in windowScene.windows) {
                if (!window.hidden && window.alpha > 0.0) return window;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow;
#pragma clang diagnostic pop
}

static UIViewController *FBCCTopViewController(void) {
    UIViewController *vc = FBCCKeyWindow().rootViewController;
    while (vc) {
        if (vc.presentedViewController) {
            vc = vc.presentedViewController;
            continue;
        }
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UIViewController *next = ((UINavigationController *)vc).visibleViewController;
            if (next && next != vc) { vc = next; continue; }
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UIViewController *next = ((UITabBarController *)vc).selectedViewController;
            if (next && next != vc) { vc = next; continue; }
        }
        break;
    }
    return vc;
}

@interface FBCacheCleanerController : NSObject
@end

@implementation FBCacheCleanerController

- (void)showResultWithBefore:(unsigned long long)before
                       after:(unsigned long long)after
                     removed:(NSUInteger)removed
                      errors:(NSArray<NSString *> *)errors {
    unsigned long long freed = before > after ? before - after : 0;
    NSString *message;
    if (errors.count == 0) {
        message = [NSString stringWithFormat:@"Liberado: %@\nRestante nos caches-alvo: %@\n\nNenhum dado de login, preferências, Documents ou Application Support foi removido.\n\nRecomendado: feche e abra o Facebook após a limpeza.",
                   FBCCHumanBytes(freed), FBCCHumanBytes(after)];
    } else {
        message = [NSString stringWithFormat:@"Liberado: %@\nRestante: %@\nItens removidos: %lu\nFalhas: %lu\n\nAlguns arquivos estavam em uso. Nenhuma área fora dos dois caches-alvo foi tocada.",
                   FBCCHumanBytes(freed), FBCCHumanBytes(after), (unsigned long)removed, (unsigned long)errors.count];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = FBCCTopViewController();
        if (!vc) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"FBCacheCleaner"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

- (void)performCleaning {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long before = FBCCTotalTargetSize();
        NSMutableArray<NSString *> *errors = [NSMutableArray array];
        NSUInteger removed = 0;

        for (NSString *path in FBCCTargetPaths()) {
            removed += FBCCClearContentsOfDirectory(path, errors);
        }

        unsigned long long after = FBCCTotalTargetSize();
        NSLog(@"[FBCacheCleaner] before=%llu after=%llu freed=%llu removed=%lu errors=%lu",
              before, after, (before > after ? before - after : 0), (unsigned long)removed, (unsigned long)errors.count);
        [self showResultWithBefore:before after:after removed:removed errors:errors];
    });
}

- (void)showCleaner {
    unsigned long long cask = FBCCDirectorySize(FBCCTargetPaths()[0]);
    unsigned long long mosaic = FBCCDirectorySize(FBCCTargetPaths()[1]);
    unsigned long long total = cask + mosaic;

    NSString *message = [NSString stringWithFormat:
                         @"Cache seguro detectado: %@\n\n"
                          "cask: %@\n"
                          "Mosaic Image Cache: %@\n\n"
                          "Serão apagados SOMENTE os conteúdos dessas duas pastas.\n\n"
                          "Documents, Application Support, Cookies, Preferences e Keychain permanecem intactos.",
                         FBCCHumanBytes(total), FBCCHumanBytes(cask), FBCCHumanBytes(mosaic)];

    UIViewController *vc = FBCCTopViewController();
    if (!vc) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Limpar cache do Facebook"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Limpar cache"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(__unused UIAlertAction *action) {
        [weakSelf performCleaning];
    }]];
    [vc presentViewController:alert animated:YES completion:nil];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    [self showCleaner];
}

- (void)attachGestureIfNeeded {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = FBCCKeyWindow();
        if (!window) return;
        if (objc_getAssociatedObject(window, kFBCCGestureKey)) return;

        UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        gesture.minimumPressDuration = 1.0;
        gesture.numberOfTouchesRequired = 3;
        gesture.cancelsTouchesInView = NO;
        [window addGestureRecognizer:gesture];
        objc_setAssociatedObject(window, kFBCCGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[FBCacheCleaner] 0.1.0 ready — three-finger long press enabled");
    });
}

@end

static FBCacheCleanerController *gFBCCController;

static void FBCCAppBecameActive(NSNotification *note) {
    (void)note;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [gFBCCController attachGestureIfNeeded];
    });
}

__attribute__((constructor))
static void FBCacheCleanerInit(void) {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (![bundleID isEqualToString:@"com.facebook.Facebook"]) return;

        gFBCCController = [FBCacheCleanerController new];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:FBCCAppBecameActive];
        NSLog(@"[FBCacheCleaner] 0.1.0 loaded");
    }
}
