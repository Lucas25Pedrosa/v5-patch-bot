#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// iQFaceCache 0.2.0-beta1
// Native add-on for the iQFace settings UI.
// Adds native rows to the Tools section of IQFSettingsViewController.
// Cleaning remains restricted to the two validated Facebook cache directories.
//
// Beta behavior:
//   - automatic options remain Nunca / Diariamente / Semanalmente / Mensalmente
//   - every enabled option uses a 1-hour interval for easier testing
//   - automatic cleaning shows a confirmation alert after it runs
//
// Production behavior will restore 24 h / 7 d / 30 d and remove the automatic alert.

static void (*IQFCCacheOriginalViewDidAppear)(UIViewController *, SEL, BOOL) = NULL;
static BOOL IQFCCacheHookInstalled = NO;
static NSInteger IQFCCacheHookAttempts = 0;
static const void *IQFCCacheRowsInstalledKey = &IQFCCacheRowsInstalledKey;
static BOOL IQFCCacheCleaningInProgress = NO;
static NSTimer *IQFCCacheAutoTimer = nil;
static id IQFCCacheDidBecomeActiveObserver = nil;

static NSString * const IQFCCacheAutoModeKey = @"iQFaceCache.AutoMode";
static NSString * const IQFCCacheLastAutomaticCleaningKey = @"iQFaceCache.LastAutomaticCleaning";

typedef NS_ENUM(NSInteger, IQFCCacheAutoMode) {
    IQFCCacheAutoModeNever = 0,
    IQFCCacheAutoModeDaily = 1,
    IQFCCacheAutoModeWeekly = 2,
    IQFCCacheAutoModeMonthly = 3,
};

static BOOL IQFCCacheUsesPortuguese(void) {
    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString;
    return [language hasPrefix:@"pt"];
}

static NSString *IQFCCacheText(NSString *portuguese, NSString *english) {
    return IQFCCacheUsesPortuguese() ? portuguese : english;
}

static BOOL IQFCCacheClassImplementsSelector(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

static BOOL IQFCCacheIsToolsHeader(NSString *header) {
    if (![header isKindOfClass:NSString.class]) return NO;
    NSString *normalized = header.lowercaseString;
    return [normalized isEqualToString:@"tools"] ||
           [normalized isEqualToString:@"ferramentas"] ||
           [normalized isEqualToString:@"herramientas"];
}

static NSString *IQFCCacheRowTitle(id row) {
    NSString *title = nil;
    @try {
        title = [row valueForKey:@"title"];
    } @catch (__unused NSException *exception) {
        title = nil;
    }
    return [title isKindOfClass:NSString.class] ? title : nil;
}

static BOOL IQFCCacheIsManualRowTitle(NSString *title) {
    return [title isEqualToString:@"Limpar cache"] ||
           [title isEqualToString:@"Clear cache"];
}

static BOOL IQFCCacheIsAutomaticRowTitle(NSString *title) {
    return [title isEqualToString:@"Limpar cache automaticamente"] ||
           [title isEqualToString:@"Clear cache automatically"];
}

static BOOL IQFCCacheIsIconRowTitle(NSString *title) {
    return [title isEqualToString:@"Alterar ícone"] ||
           [title isEqualToString:@"Change Icon"];
}

static id IQFCCacheFindToolsSection(NSArray *sections) {
    for (id section in sections) {
        NSString *header = nil;
        @try {
            header = [section valueForKey:@"header"];
        } @catch (__unused NSException *exception) {
            header = nil;
        }
        if (IQFCCacheIsToolsHeader(header)) return section;
    }
    return nil;
}

static NSArray<NSString *> *IQFCCacheTargetPaths(void) {
    NSString *cacheRoot = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    return @[
        [cacheRoot stringByAppendingPathComponent:@"cask"],
        [cacheRoot stringByAppendingPathComponent:@"com.facebook.Facebook.MosaicIGImageDiskCache"]
    ];
}

static BOOL IQFCCacheIsAllowedTargetPath(NSString *path) {
    NSString *cacheRoot = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"] stringByStandardizingPath];
    NSString *standardPath = [path stringByStandardizingPath];
    NSString *expectedPrefix = [cacheRoot stringByAppendingString:@"/"];
    if (![standardPath hasPrefix:expectedPrefix]) return NO;

    NSString *name = standardPath.lastPathComponent;
    return [name isEqualToString:@"cask"] ||
           [name isEqualToString:@"com.facebook.Facebook.MosaicIGImageDiskCache"];
}

static unsigned long long IQFCCacheDirectorySize(NSString *path) {
    if (!IQFCCacheIsAllowedTargetPath(path)) return 0;

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory]) return 0;

    if (!isDirectory) {
        NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];
        return [attributes[NSFileSize] unsignedLongLongValue];
    }

    unsigned long long total = 0;
    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:path];
    for (NSString *relativePath in enumerator) {
        @autoreleasepool {
            NSString *fullPath = [path stringByAppendingPathComponent:relativePath];
            NSDictionary *attributes = [fm attributesOfItemAtPath:fullPath error:nil];
            if ([attributes[NSFileType] isEqual:NSFileTypeRegular]) {
                total += [attributes[NSFileSize] unsignedLongLongValue];
            }
        }
    }
    return total;
}

static unsigned long long IQFCCacheTotalSize(void) {
    unsigned long long total = 0;
    for (NSString *path in IQFCCacheTargetPaths()) {
        total += IQFCCacheDirectorySize(path);
    }
    return total;
}

static NSString *IQFCCacheHumanBytes(unsigned long long bytes) {
    NSByteCountFormatter *formatter = [NSByteCountFormatter new];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    formatter.includesUnit = YES;
    formatter.includesCount = YES;
    formatter.includesActualByteCount = NO;
    formatter.zeroPadsFractionDigits = NO;
    return [formatter stringFromByteCount:(long long)bytes];
}

static NSUInteger IQFCCacheClearContentsOfDirectory(NSString *path, NSMutableArray<NSString *> *errors) {
    if (!IQFCCacheIsAllowedTargetPath(path)) {
        [errors addObject:@"Blocked non-whitelisted path"];
        return 0;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) return 0;

    NSError *listError = nil;
    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:path error:&listError];
    if (![children isKindOfClass:NSArray.class]) {
        if (listError != nil) [errors addObject:listError.localizedDescription ?: @"List error"];
        return 0;
    }

    NSUInteger removed = 0;
    for (NSString *child in children) {
        NSString *childPath = [path stringByAppendingPathComponent:child];
        NSError *removeError = nil;
        if ([fm removeItemAtPath:childPath error:&removeError]) {
            removed += 1;
        } else if (removeError != nil) {
            [errors addObject:removeError.localizedDescription ?: @"Remove error"];
        }
    }
    return removed;
}

static UIWindow *IQFCCacheKeyWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
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
    return application.keyWindow;
#pragma clang diagnostic pop
}

static UIViewController *IQFCCacheTopViewController(void) {
    UIViewController *controller = IQFCCacheKeyWindow().rootViewController;
    while (controller != nil) {
        if (controller.presentedViewController != nil) {
            controller = controller.presentedViewController;
            continue;
        }
        if ([controller isKindOfClass:UINavigationController.class]) {
            UIViewController *next = ((UINavigationController *)controller).visibleViewController;
            if (next != nil && next != controller) {
                controller = next;
                continue;
            }
        }
        if ([controller isKindOfClass:UITabBarController.class]) {
            UIViewController *next = ((UITabBarController *)controller).selectedViewController;
            if (next != nil && next != controller) {
                controller = next;
                continue;
            }
        }
        break;
    }
    return controller;
}

static IQFCCacheAutoMode IQFCCacheAutomaticMode(void) {
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:IQFCCacheAutoModeKey];
    if (value < IQFCCacheAutoModeNever || value > IQFCCacheAutoModeMonthly) {
        return IQFCCacheAutoModeNever;
    }
    return (IQFCCacheAutoMode)value;
}

static NSString *IQFCCacheAutomaticModeName(IQFCCacheAutoMode mode) {
    switch (mode) {
        case IQFCCacheAutoModeDaily:
            return IQFCCacheText(@"Diariamente", @"Daily");
        case IQFCCacheAutoModeWeekly:
            return IQFCCacheText(@"Semanalmente", @"Weekly");
        case IQFCCacheAutoModeMonthly:
            return IQFCCacheText(@"Mensalmente", @"Monthly");
        case IQFCCacheAutoModeNever:
        default:
            return IQFCCacheText(@"Nunca", @"Never");
    }
}

static NSTimeInterval IQFCCacheAutomaticInterval(void) {
    // Beta: every enabled option is intentionally shortened to one hour.
    return IQFCCacheAutomaticMode() == IQFCCacheAutoModeNever ? 0.0 : 3600.0;
}

static void IQFCCacheMarkAutomaticCleaningNow(void) {
    [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970
                                            forKey:IQFCCacheLastAutomaticCleaningKey];
}

static void IQFCCachePresentManualResult(UIViewController *controller,
                                         unsigned long long freed,
                                         NSUInteger errorCount) {
    if (controller == nil || controller.presentedViewController != nil) return;

    NSString *title = IQFCCacheText(@"✓ Cache limpo", @"✓ Cache cleared");
    NSString *message = [NSString stringWithFormat:IQFCCacheText(@"%@ liberados", @"%@ freed"),
                         IQFCCacheHumanBytes(freed)];
    if (errorCount > 0) {
        message = [message stringByAppendingString:IQFCCacheText(@"\n\nAlguns arquivos estavam em uso.",
                                                                  @"\n\nSome files were in use.")];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void IQFCCachePresentAutomaticBetaResult(unsigned long long freed,
                                                NSUInteger errorCount) {
    UIViewController *controller = IQFCCacheTopViewController();
    if (controller == nil || controller.view.window == nil ||
        [controller isKindOfClass:UIAlertController.class] ||
        controller.presentedViewController != nil) {
        return;
    }

    NSString *title = IQFCCacheText(@"Limpeza automática — Beta", @"Automatic cleaning — Beta");
    NSString *message = [NSString stringWithFormat:
                         IQFCCacheText(@"A limpeza automática foi realizada.\n\n%@ liberados",
                                       @"Automatic cleaning completed.\n\n%@ freed"),
                         IQFCCacheHumanBytes(freed)];
    if (errorCount > 0) {
        message = [message stringByAppendingString:
                   IQFCCacheText(@"\n\nAlguns arquivos estavam em uso.",
                                 @"\n\nSome files were in use.")];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void IQFCCachePerformCleaning(UIViewController *controller, BOOL automatic) {
    if (IQFCCacheCleaningInProgress) return;
    IQFCCacheCleaningInProgress = YES;

    __weak UIViewController *weakController = controller;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long before = IQFCCacheTotalSize();
        NSMutableArray<NSString *> *errors = [NSMutableArray array];

        for (NSString *path in IQFCCacheTargetPaths()) {
            IQFCCacheClearContentsOfDirectory(path, errors);
        }

        unsigned long long after = IQFCCacheTotalSize();
        unsigned long long freed = before > after ? before - after : 0;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (automatic) {
                IQFCCacheMarkAutomaticCleaningNow();
                IQFCCachePresentAutomaticBetaResult(freed, errors.count);
            } else {
                UIViewController *presenter = weakController;
                if (presenter != nil && presenter.view.window != nil) {
                    IQFCCachePresentManualResult(presenter, freed, errors.count);
                }
            }
            IQFCCacheCleaningInProgress = NO;
        });
    });
}

static void IQFCCacheCheckAutomaticCleaning(void) {
    IQFCCacheAutoMode mode = IQFCCacheAutomaticMode();
    NSTimeInterval interval = IQFCCacheAutomaticInterval();
    if (mode == IQFCCacheAutoModeNever || interval <= 0.0 || IQFCCacheCleaningInProgress) return;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval last = [defaults doubleForKey:IQFCCacheLastAutomaticCleaningKey];

    if (last <= 0.0) {
        [defaults setDouble:now forKey:IQFCCacheLastAutomaticCleaningKey];
        return;
    }

    if ((now - last) >= interval) {
        IQFCCachePerformCleaning(nil, YES);
    }
}

static void IQFCCacheRestartAutomaticTimer(void) {
    [IQFCCacheAutoTimer invalidate];
    IQFCCacheAutoTimer = nil;

    if (IQFCCacheAutomaticMode() == IQFCCacheAutoModeNever) return;

    IQFCCacheAutoTimer = [NSTimer timerWithTimeInterval:60.0
                                                 target:NSBlockOperation.class
                                               selector:@selector(description)
                                               userInfo:nil
                                                repeats:YES];

    // Replace the dummy target timer with a block timer on iOS 10+.
    [IQFCCacheAutoTimer invalidate];
    IQFCCacheAutoTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
                                                         repeats:YES
                                                           block:^(__unused NSTimer *timer) {
        IQFCCacheCheckAutomaticCleaning();
    }];
    [[NSRunLoop mainRunLoop] addTimer:IQFCCacheAutoTimer forMode:NSRunLoopCommonModes];
    IQFCCacheCheckAutomaticCleaning();
}

static void IQFCCacheSetAutomaticMode(IQFCCacheAutoMode mode) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:mode forKey:IQFCCacheAutoModeKey];

    if (mode == IQFCCacheAutoModeNever) {
        [defaults removeObjectForKey:IQFCCacheLastAutomaticCleaningKey];
    } else {
        // Start the one-hour beta countdown when the user selects a mode.
        [defaults setDouble:NSDate.date.timeIntervalSince1970 forKey:IQFCCacheLastAutomaticCleaningKey];
    }

    IQFCCacheRestartAutomaticTimer();
}

static void IQFCCachePresentConfirmation(UIViewController *controller) {
    if (controller == nil || controller.presentedViewController != nil) return;

    unsigned long long bytes = IQFCCacheTotalSize();
    NSString *message = [NSString stringWithFormat:
                         IQFCCacheText(@"Serão removidos aproximadamente %@ de arquivos temporários.",
                                       @"Approximately %@ of temporary files will be removed."),
                         IQFCCacheHumanBytes(bytes)];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:IQFCCacheText(@"Cancelar", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    __weak UIViewController *weakController = controller;
    [alert addAction:[UIAlertAction actionWithTitle:IQFCCacheText(@"Limpar", @"Clear")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        UIViewController *presenter = weakController;
        if (presenter != nil) {
            IQFCCachePerformCleaning(presenter, NO);
        }
    }]];

    [controller presentViewController:alert animated:YES completion:nil];
}

static void IQFCCachePresentAutomaticPicker(UIViewController *controller) {
    if (controller == nil || controller.presentedViewController != nil) return;

    IQFCCacheAutoMode currentMode = IQFCCacheAutomaticMode();
    NSString *message = IQFCCacheText(
        @"Para facilitar o teste, qualquer opção automática ativa executa a limpeza a cada 1 hora neste beta.",
        @"For easier testing, any enabled automatic option runs every 1 hour in this beta."
    );

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
                                IQFCCacheText(@"Limpar cache automaticamente", @"Clear cache automatically")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSNumber *> *modes = @[
        @(IQFCCacheAutoModeNever),
        @(IQFCCacheAutoModeDaily),
        @(IQFCCacheAutoModeWeekly),
        @(IQFCCacheAutoModeMonthly)
    ];

    for (NSNumber *number in modes) {
        IQFCCacheAutoMode mode = (IQFCCacheAutoMode)number.integerValue;
        NSString *name = IQFCCacheAutomaticModeName(mode);
        NSString *title = mode == currentMode ? [@"✓ " stringByAppendingString:name] : name;
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
            IQFCCacheSetAutomaticMode(mode);
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:IQFCCacheText(@"Cancelar", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover != nil) {
        popover.sourceView = controller.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds),
                                        CGRectGetMidY(controller.view.bounds),
                                        1.0,
                                        1.0);
        popover.permittedArrowDirections = 0;
    }

    [controller presentViewController:alert animated:YES completion:nil];
}

static id IQFCCacheCreateManualRow(UIViewController *controller) {
    SEL selector = NSSelectorFromString(@"valueRowWithTitle:icon:detail:tap:");
    if (controller == nil || ![controller respondsToSelector:selector]) return nil;

    __weak UIViewController *weakController = controller;
    void (^tapBlock)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = weakController;
            if (presenter == nil || presenter.presentedViewController != nil) return;
            IQFCCachePresentConfirmation(presenter);
        });
    };

    typedef id (*IQFCCacheNativeRowBuilder)(id, SEL, id, id, id, id);
    IQFCCacheNativeRowBuilder builder = (IQFCCacheNativeRowBuilder)(void *)objc_msgSend;
    return builder(controller,
                   selector,
                   IQFCCacheText(@"Limpar cache", @"Clear cache"),
                   @"trash",
                   @"",
                   [tapBlock copy]);
}

static id IQFCCacheCreateAutomaticRow(UIViewController *controller) {
    SEL selector = NSSelectorFromString(@"valueRowWithTitle:icon:detail:tap:");
    if (controller == nil || ![controller respondsToSelector:selector]) return nil;

    __weak UIViewController *weakController = controller;
    void (^tapBlock)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = weakController;
            if (presenter == nil || presenter.presentedViewController != nil) return;
            IQFCCachePresentAutomaticPicker(presenter);
        });
    };

    typedef id (*IQFCCacheNativeRowBuilder)(id, SEL, id, id, id, id);
    IQFCCacheNativeRowBuilder builder = (IQFCCacheNativeRowBuilder)(void *)objc_msgSend;
    return builder(controller,
                   selector,
                   IQFCCacheText(@"Limpar cache automaticamente", @"Clear cache automatically"),
                   @"clock.arrow.circlepath",
                   IQFCCacheAutomaticModeName(IQFCCacheAutomaticMode()),
                   [tapBlock copy]);
}

static void IQFCCacheInstallRows(UIViewController *controller) {
    if (controller == nil || objc_getAssociatedObject(controller, IQFCCacheRowsInstalledKey) != nil) return;

    NSArray *sections = nil;
    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        sections = nil;
    }

    if (![sections isKindOfClass:NSArray.class] || sections.count == 0) return;

    id toolsSection = IQFCCacheFindToolsSection(sections);
    if (toolsSection == nil) return;

    NSArray *rows = nil;
    @try {
        rows = [toolsSection valueForKey:@"rows"];
    } @catch (__unused NSException *exception) {
        rows = nil;
    }
    if (![rows isKindOfClass:NSArray.class]) return;

    BOOL hasManual = NO;
    BOOL hasAutomatic = NO;
    for (id row in rows) {
        NSString *title = IQFCCacheRowTitle(row);
        if (IQFCCacheIsManualRowTitle(title)) hasManual = YES;
        if (IQFCCacheIsAutomaticRowTitle(title)) hasAutomatic = YES;
    }

    NSMutableArray *updatedRows = [rows mutableCopy];
    NSUInteger insertionIndex = updatedRows.count;
    for (NSUInteger i = 0; i < updatedRows.count; i++) {
        if (IQFCCacheIsIconRowTitle(IQFCCacheRowTitle(updatedRows[i]))) {
            insertionIndex = i + 1;
            break;
        }
    }

    Class rowClass = NSClassFromString(@"IQFRow");
    if (rowClass == Nil) return;

    if (!hasManual) {
        id manualRow = IQFCCacheCreateManualRow(controller);
        if (manualRow == nil || ![manualRow isKindOfClass:rowClass]) return;
        [updatedRows insertObject:manualRow atIndex:MIN(insertionIndex, updatedRows.count)];
        insertionIndex += 1;
    } else {
        for (NSUInteger i = 0; i < updatedRows.count; i++) {
            if (IQFCCacheIsManualRowTitle(IQFCCacheRowTitle(updatedRows[i]))) {
                insertionIndex = i + 1;
                break;
            }
        }
    }

    if (!hasAutomatic) {
        id automaticRow = IQFCCacheCreateAutomaticRow(controller);
        if (automaticRow == nil || ![automaticRow isKindOfClass:rowClass]) return;
        [updatedRows insertObject:automaticRow atIndex:MIN(insertionIndex, updatedRows.count)];
    }

    @try {
        [toolsSection setValue:[updatedRows copy] forKey:@"rows"];
        if ([controller isKindOfClass:UITableViewController.class]) {
            [((UITableViewController *)controller).tableView reloadData];
        }
        objc_setAssociatedObject(controller, IQFCCacheRowsInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (__unused NSException *exception) {
        return;
    }
}

static void IQFCCacheViewDidAppear(UIViewController *self, SEL command, BOOL animated) {
    if (IQFCCacheOriginalViewDidAppear != NULL) {
        IQFCCacheOriginalViewDidAppear(self, command, animated);
    }
    IQFCCacheInstallRows(self);
}

static void IQFCCacheTryInstallHook(void) {
    if (IQFCCacheHookInstalled) return;

    IQFCCacheHookAttempts += 1;
    Class target = NSClassFromString(@"IQFSettingsViewController");
    if (target != Nil) {
        SEL selector = @selector(viewDidAppear:);
        Method inheritedOrOwn = class_getInstanceMethod(target, selector);
        if (inheritedOrOwn != NULL) {
            IQFCCacheOriginalViewDidAppear = (void (*)(UIViewController *, SEL, BOOL))method_getImplementation(inheritedOrOwn);
            const char *types = method_getTypeEncoding(inheritedOrOwn);

            if (IQFCCacheClassImplementsSelector(target, selector)) {
                method_setImplementation(inheritedOrOwn, (IMP)&IQFCCacheViewDidAppear);
                IQFCCacheHookInstalled = YES;
            } else if (class_addMethod(target, selector, (IMP)&IQFCCacheViewDidAppear, types)) {
                IQFCCacheHookInstalled = YES;
            }
        }
    }

    if (!IQFCCacheHookInstalled && IQFCCacheHookAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            IQFCCacheTryInstallHook();
        });
    }
}

static void IQFCCacheApplicationDidBecomeActive(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IQFCCacheCheckAutomaticCleaning();
        IQFCCacheRestartAutomaticTimer();
    });
}

__attribute__((constructor))
static void IQFCCacheInitialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            IQFCCacheTryInstallHook();
            IQFCCacheRestartAutomaticTimer();
        });

        IQFCCacheDidBecomeActiveObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
            IQFCCacheApplicationDidBecomeActive();
        }];
    }
}
