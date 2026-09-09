#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// FBCacheCleaner 0.2.0-beta1
// Conservative cleaner based on FBCacheDiagnostic results from Facebook 577.1.0.
// It ONLY clears the contents of these validated cache directories:
//   Library/Caches/cask
//   Library/Caches/com.facebook.Facebook.MosaicIGImageDiskCache
// It never touches Documents, Application Support, Cookies, Preferences, or Keychain.
//
// Beta automatic-cleaning test interval:
//   Any enabled automatic mode -> 1 hour
//
// The production build will restore 24 h / 7 d / 30 d and disable automatic alerts.

static const void *kFBCCGestureKey = &kFBCCGestureKey;
static NSString * const kFBCCAutoModeKey = @"FBCacheCleaner.AutoMode";
static NSString * const kFBCCLastAutoCleanKey = @"FBCacheCleaner.LastAutoClean";

typedef NS_ENUM(NSInteger, FBCCAutoMode) {
    FBCCAutoModeNever = 0,
    FBCCAutoModeDaily = 1,
    FBCCAutoModeWeekly = 2,
    FBCCAutoModeMonthly = 3,
};

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
        if (listError) {
            [errors addObject:[NSString stringWithFormat:@"%@ — %@", path.lastPathComponent, listError.localizedDescription]];
        }
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

static NSTimeInterval FBCCIntervalForMode(FBCCAutoMode mode) {
    switch (mode) {
        case FBCCAutoModeDaily:
        case FBCCAutoModeWeekly:
        case FBCCAutoModeMonthly:
            return 3600.0;
        case FBCCAutoModeNever:
        default:
            return 0.0;
    }
}

static NSString *FBCCModeName(FBCCAutoMode mode) {
    switch (mode) {
        case FBCCAutoModeDaily:   return @"Diariamente";
        case FBCCAutoModeWeekly:  return @"Semanalmente";
        case FBCCAutoModeMonthly: return @"Mensalmente";
        case FBCCAutoModeNever:
        default:                  return @"Nunca";
    }
}

static NSString *FBCCTestIntervalName(FBCCAutoMode mode) {
    switch (mode) {
        case FBCCAutoModeDaily:
        case FBCCAutoModeWeekly:
        case FBCCAutoModeMonthly:
            return @"1 hora";
        case FBCCAutoModeNever:
        default:
            return @"desativado";
    }
}

@interface FBCacheCleanerController : NSObject
@property (nonatomic, strong) NSTimer *autoTimer;
@property (nonatomic, assign) BOOL cleaningInProgress;
@end

@implementation FBCacheCleanerController

- (FBCCAutoMode)automaticMode {
    NSInteger value = [[NSUserDefaults standardUserDefaults] integerForKey:kFBCCAutoModeKey];
    if (value < FBCCAutoModeNever || value > FBCCAutoModeMonthly) return FBCCAutoModeNever;
    return (FBCCAutoMode)value;
}

- (void)setAutomaticMode:(FBCCAutoMode)mode {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:mode forKey:kFBCCAutoModeKey];

    if (mode == FBCCAutoModeNever) {
        [defaults removeObjectForKey:kFBCCLastAutoCleanKey];
    } else {
        // Start the beta countdown from the moment the option is selected.
        [defaults setDouble:[[NSDate date] timeIntervalSince1970] forKey:kFBCCLastAutoCleanKey];
    }

    [self startAutomaticTimerIfNeeded];
}

- (NSTimeInterval)lastAutomaticCleaningTime {
    return [[NSUserDefaults standardUserDefaults] doubleForKey:kFBCCLastAutoCleanKey];
}

- (void)markAutomaticCleaningNow {
    [[NSUserDefaults standardUserDefaults] setDouble:[[NSDate date] timeIntervalSince1970]
                                             forKey:kFBCCLastAutoCleanKey];
}

- (void)showManualResultWithBefore:(unsigned long long)before
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

- (void)showAutomaticBetaResultWithBefore:(unsigned long long)before
                                     after:(unsigned long long)after
                                   removed:(NSUInteger)removed
                                    errors:(NSArray<NSString *> *)errors {
    unsigned long long freed = before > after ? before - after : 0;
    NSString *message;

    if (errors.count == 0) {
        message = [NSString stringWithFormat:@"A limpeza automática foi realizada.\n\nLiberado: %@\nRestante: %@",
                   FBCCHumanBytes(freed), FBCCHumanBytes(after)];
    } else {
        message = [NSString stringWithFormat:@"A limpeza automática foi executada com %lu falha(s).\n\nLiberado: %@\nRestante: %@\nItens removidos: %lu",
                   (unsigned long)errors.count, FBCCHumanBytes(freed), FBCCHumanBytes(after), (unsigned long)removed];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = FBCCTopViewController();
        if (!vc) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Limpeza automática — Beta"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

- (void)performCleaningAutomatic:(BOOL)automatic {
    if (self.cleaningInProgress) return;
    self.cleaningInProgress = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long before = FBCCTotalTargetSize();
        NSMutableArray<NSString *> *errors = [NSMutableArray array];
        NSUInteger removed = 0;

        for (NSString *path in FBCCTargetPaths()) {
            removed += FBCCClearContentsOfDirectory(path, errors);
        }

        unsigned long long after = FBCCTotalTargetSize();

        dispatch_async(dispatch_get_main_queue(), ^{
            if (automatic) {
                [self markAutomaticCleaningNow];
                [self showAutomaticBetaResultWithBefore:before after:after removed:removed errors:errors];
            } else {
                [self showManualResultWithBefore:before after:after removed:removed errors:errors];
            }
            self.cleaningInProgress = NO;
        });
    });
}

- (void)checkAutomaticCleaning {
    FBCCAutoMode mode = [self automaticMode];
    NSTimeInterval interval = FBCCIntervalForMode(mode);
    if (interval <= 0.0 || self.cleaningInProgress) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval last = [self lastAutomaticCleaningTime];

    if (last <= 0.0) {
        [self markAutomaticCleaningNow];
        return;
    }

    if ((now - last) >= interval) {
        [self performCleaningAutomatic:YES];
    }
}

- (void)automaticTimerFired:(NSTimer *)timer {
    (void)timer;
    [self checkAutomaticCleaning];
}

- (void)startAutomaticTimerIfNeeded {
    [self.autoTimer invalidate];
    self.autoTimer = nil;

    if ([self automaticMode] == FBCCAutoModeNever) return;

    NSTimer *timer = [NSTimer timerWithTimeInterval:5.0
                                             target:self
                                           selector:@selector(automaticTimerFired:)
                                           userInfo:nil
                                            repeats:YES];
    self.autoTimer = timer;
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];

    [self checkAutomaticCleaning];
}

- (NSString *)actionTitleForMode:(FBCCAutoMode)mode selected:(FBCCAutoMode)selected {
    NSString *base;
    if (mode == FBCCAutoModeNever) {
        base = @"Nunca";
    } else {
        base = [NSString stringWithFormat:@"%@ — %@ no beta", FBCCModeName(mode), FBCCTestIntervalName(mode)];
    }
    return mode == selected ? [NSString stringWithFormat:@"✓ %@", base] : base;
}

- (void)showAutomaticSettings {
    UIViewController *vc = FBCCTopViewController();
    if (!vc) return;

    FBCCAutoMode selected = [self automaticMode];
    NSString *message = @"Para facilitar o teste, qualquer opção automática ativa executa a limpeza a cada 1 hora neste beta.\n\nNa versão final: 24 horas, 7 dias e 30 dias.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Limpar cache automaticamente"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    NSArray<NSNumber *> *modes = @[@(FBCCAutoModeNever), @(FBCCAutoModeDaily), @(FBCCAutoModeWeekly), @(FBCCAutoModeMonthly)];
    for (NSNumber *number in modes) {
        FBCCAutoMode mode = (FBCCAutoMode)number.integerValue;
        NSString *title = [self actionTitleForMode:mode selected:selected];
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(__unused UIAlertAction *action) {
            [weakSelf setAutomaticMode:mode];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover) {
        popover.sourceView = vc.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(vc.view.bounds), CGRectGetMidY(vc.view.bounds), 1.0, 1.0);
        popover.permittedArrowDirections = 0;
    }

    [vc presentViewController:alert animated:YES completion:nil];
}

- (void)showCleaner {
    unsigned long long cask = FBCCDirectorySize(FBCCTargetPaths()[0]);
    unsigned long long mosaic = FBCCDirectorySize(FBCCTargetPaths()[1]);
    unsigned long long total = cask + mosaic;
    FBCCAutoMode mode = [self automaticMode];

    NSString *autoText = mode == FBCCAutoModeNever
        ? @"Nunca"
        : [NSString stringWithFormat:@"%@ (%@ no beta)", FBCCModeName(mode), FBCCTestIntervalName(mode)];

    NSString *message = [NSString stringWithFormat:
                         @"Cache seguro detectado: %@\n\n"
                          "cask: %@\n"
                          "Mosaic Image Cache: %@\n\n"
                          "Limpeza automática: %@\n\n"
                          "Serão apagados SOMENTE os conteúdos dessas duas pastas.",
                         FBCCHumanBytes(total), FBCCHumanBytes(cask), FBCCHumanBytes(mosaic), autoText];

    UIViewController *vc = FBCCTopViewController();
    if (!vc) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"FBCacheCleaner Beta"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Limpar cache agora"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(__unused UIAlertAction *action) {
        [weakSelf performCleaningAutomatic:NO];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Limpeza automática (Beta)"
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        [weakSelf showAutomaticSettings];
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
    });
}

- (void)applicationBecameActive {
    [self attachGestureIfNeeded];
    [self startAutomaticTimerIfNeeded];
}

@end

static FBCacheCleanerController *gFBCCController;

static void FBCCAppBecameActive(NSNotification *note) {
    (void)note;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [gFBCCController applicationBecameActive];
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
                                                      usingBlock:^(NSNotification *note) {
            FBCCAppBecameActive(note);
        }];
    }
}
