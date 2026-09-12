#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// iQFaceCache 0.2.1
// iQFace 1.1-only settings integration using IQFSetting + IQFTweakSettings.
// Injects settings into +[IQFTweakSettings sections] before the controller is built.
// No IQFRow/IQFSection compatibility layer is kept.
// Manual cleaning keeps confirmation/result UI; automatic cleaning is silent.

static NSString *const IQFCCacheAutoFrequencyKey = @"iQFaceCacheAutoFrequency";
static NSString *const IQFCCacheLastAutomaticRunKey = @"iQFaceCacheLastAutomaticRun";

static NSArray *(*IQFCCacheOriginalTweakSections)(id, SEL) = NULL;
static BOOL IQFCCacheHookInstalled = NO;
static NSInteger IQFCCacheHookAttempts = 0;
static BOOL IQFCCacheAutomaticRunInProgress = NO;
static id IQFCCacheActiveObserver = nil;

static BOOL IQFCCacheUsesPortuguese(void) {
    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString;
    return [language hasPrefix:@"pt"];
}

static NSString *IQFCCacheText(NSString *portuguese, NSString *english) {
    return IQFCCacheUsesPortuguese() ? portuguese : english;
}

#pragma mark - Cache paths and cleaning

static NSArray<NSString *> *IQFCCacheTargetPaths(void) {
    NSString *cacheRoot = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    return @[
        [cacheRoot stringByAppendingPathComponent:@"cask"],
        [cacheRoot stringByAppendingPathComponent:@"com.facebook.Facebook.MosaicIGImageDiskCache"]
    ];
}

static BOOL IQFCCacheIsAllowedTargetPath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0) {
        return NO;
    }

    NSString *cacheRoot = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"] stringByStandardizingPath];
    NSString *standardPath = [path stringByStandardizingPath];
    NSString *expectedPrefix = [cacheRoot stringByAppendingString:@"/"];
    if (![standardPath hasPrefix:expectedPrefix]) {
        return NO;
    }

    NSString *name = standardPath.lastPathComponent;
    return [name isEqualToString:@"cask"] ||
           [name isEqualToString:@"com.facebook.Facebook.MosaicIGImageDiskCache"];
}

static unsigned long long IQFCCacheDirectorySize(NSString *path) {
    if (!IQFCCacheIsAllowedTargetPath(path)) {
        return 0;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory]) {
        return 0;
    }

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
        if (errors != nil) {
            [errors addObject:@"Blocked non-whitelisted path"];
        }
        return 0;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) {
        return 0;
    }

    NSError *listError = nil;
    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:path error:&listError];
    if (![children isKindOfClass:NSArray.class]) {
        if (errors != nil && listError != nil) {
            [errors addObject:listError.localizedDescription ?: @"List error"];
        }
        return 0;
    }

    NSUInteger removed = 0;
    for (NSString *child in children) {
        NSString *childPath = [path stringByAppendingPathComponent:child];
        NSError *removeError = nil;
        if ([fm removeItemAtPath:childPath error:&removeError]) {
            removed += 1;
        } else if (errors != nil && removeError != nil) {
            [errors addObject:removeError.localizedDescription ?: @"Remove error"];
        }
    }
    return removed;
}

#pragma mark - iQFace prefs bridge

static Class IQFCCachePrefsClass(void) {
    return NSClassFromString(@"IQFPrefs");
}

static NSInteger IQFCCachePreferenceInteger(NSString *key, NSInteger defaultValue) {
    Class prefs = IQFCCachePrefsClass();
    SEL selector = NSSelectorFromString(@"integerForKey:defaultValue:");
    if (prefs == Nil || ![prefs respondsToSelector:selector]) {
        return defaultValue;
    }

    typedef NSInteger (*IQFCCacheIntegerGetter)(id, SEL, id, NSInteger);
    IQFCCacheIntegerGetter getter = (IQFCCacheIntegerGetter)(void *)objc_msgSend;
    return getter(prefs, selector, key, defaultValue);
}

static void IQFCCacheSetPreferenceInteger(NSInteger value, NSString *key) {
    Class prefs = IQFCCachePrefsClass();
    SEL selector = NSSelectorFromString(@"setInteger:forKey:");
    if (prefs == Nil || ![prefs respondsToSelector:selector]) {
        return;
    }

    typedef void (*IQFCCacheIntegerSetter)(id, SEL, NSInteger, id);
    IQFCCacheIntegerSetter setter = (IQFCCacheIntegerSetter)(void *)objc_msgSend;
    setter(prefs, selector, value, key);
}

#pragma mark - Manual cleaning UI

static void IQFCCachePresentResult(UIViewController *controller,
                                   unsigned long long freed,
                                   NSUInteger errorCount) {
    if (controller == nil || controller.presentedViewController != nil) {
        return;
    }

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

static void IQFCCachePerformManualCleaning(UIViewController *controller) {
    __weak UIViewController *weakController = controller;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long before = IQFCCacheTotalSize();
        NSMutableArray<NSString *> *errors = [NSMutableArray array];

        for (NSString *path in IQFCCacheTargetPaths()) {
            IQFCCacheClearContentsOfDirectory(path, errors);
        }

        unsigned long long after = IQFCCacheTotalSize();
        unsigned long long freed = before > after ? before - after : 0;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *presenter = weakController;
            if (presenter == nil || presenter.view.window == nil) {
                return;
            }
            IQFCCachePresentResult(presenter, freed, errors.count);
        });
    });
}

static void IQFCCachePresentConfirmation(UIViewController *controller) {
    if (controller == nil || controller.presentedViewController != nil) {
        return;
    }

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
            IQFCCachePerformManualCleaning(presenter);
        }
    }]];

    [controller presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Silent automatic cleaning

static NSDate *IQFCCacheNextAutomaticDate(NSDate *lastRun, NSInteger frequency) {
    if (lastRun == nil || frequency <= 0) {
        return nil;
    }

    NSDateComponents *components = [NSDateComponents new];
    switch (frequency) {
        case 1:
            components.day = 1;
            break;
        case 2:
            components.day = 7;
            break;
        case 3:
            components.month = 1;
            break;
        default:
            return nil;
    }

    return [[NSCalendar currentCalendar] dateByAddingComponents:components
                                                         toDate:lastRun
                                                        options:0];
}

static void IQFCCacheMaybeRunAutomaticCleaning(void) {
    if (IQFCCacheAutomaticRunInProgress || IQFCCachePrefsClass() == Nil) {
        return;
    }

    NSInteger frequency = IQFCCachePreferenceInteger(IQFCCacheAutoFrequencyKey, 0);
    if (frequency < 1 || frequency > 3) {
        return;
    }

    NSInteger lastTimestamp = IQFCCachePreferenceInteger(IQFCCacheLastAutomaticRunKey, 0);
    NSDate *now = [NSDate date];
    BOOL shouldRun = lastTimestamp <= 0;

    if (!shouldRun) {
        NSDate *lastRun = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)lastTimestamp];
        NSDate *nextRun = IQFCCacheNextAutomaticDate(lastRun, frequency);
        shouldRun = nextRun == nil || [now compare:nextRun] != NSOrderedAscending;
    }

    if (!shouldRun) {
        return;
    }

    IQFCCacheAutomaticRunInProgress = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSString *path in IQFCCacheTargetPaths()) {
            IQFCCacheClearContentsOfDirectory(path, nil);
        }

        NSInteger completedAt = (NSInteger)[NSDate date].timeIntervalSince1970;
        dispatch_async(dispatch_get_main_queue(), ^{
            IQFCCacheSetPreferenceInteger(completedAt, IQFCCacheLastAutomaticRunKey);
            IQFCCacheAutomaticRunInProgress = NO;
        });
    });
}

static void IQFCCacheStartAutomaticScheduler(void) {
    if (IQFCCacheActiveObserver != nil) {
        return;
    }

    IQFCCacheActiveObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
        IQFCCacheMaybeRunAutomaticCleaning();
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IQFCCacheMaybeRunAutomaticCleaning();
    });
}

#pragma mark - iQFace 1.1 settings integration

static NSString *IQFCCacheSettingTitle(id setting) {
    if (setting == nil) {
        return nil;
    }

    SEL selector = NSSelectorFromString(@"title");
    if (![setting respondsToSelector:selector]) {
        return nil;
    }

    typedef id (*IQFCCacheObjectGetter)(id, SEL);
    IQFCCacheObjectGetter getter = (IQFCCacheObjectGetter)(void *)objc_msgSend;
    id value = getter(setting, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static BOOL IQFCCacheIsManualTitle(NSString *title) {
    return [title isEqualToString:@"Limpar cache"] || [title isEqualToString:@"Clear cache"];
}

static BOOL IQFCCacheIsAutomaticTitle(NSString *title) {
    return [title isEqualToString:@"Limpar cache automaticamente"] ||
           [title isEqualToString:@"Clear cache automatically"];
}

static BOOL IQFCCacheIsToolsHeader(NSString *header) {
    if (![header isKindOfClass:NSString.class]) {
        return NO;
    }

    NSString *normalized = header.lowercaseString;
    return [normalized isEqualToString:@"tools"] ||
           [normalized isEqualToString:@"ferramentas"] ||
           [normalized isEqualToString:@"herramientas"];
}

static UIViewController *IQFCCacheTopViewControllerFrom(UIViewController *controller) {
    UIViewController *current = controller;

    while (current != nil) {
        UIViewController *next = nil;

        if (current.presentedViewController != nil) {
            next = current.presentedViewController;
        } else if ([current isKindOfClass:UINavigationController.class]) {
            next = ((UINavigationController *)current).visibleViewController;
        } else if ([current isKindOfClass:UITabBarController.class]) {
            next = ((UITabBarController *)current).selectedViewController;
        } else if (current.children.count == 1) {
            next = current.children.firstObject;
        }

        if (next == nil || next == current) {
            break;
        }
        current = next;
    }

    return current;
}

static UIViewController *IQFCCacheCurrentPresenter(void) {
    UIApplication *application = UIApplication.sharedApplication;
    UIWindow *window = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *candidate in windowScene.windows) {
                if (candidate.isKeyWindow) {
                    window = candidate;
                    break;
                }
            }

            if (window == nil) {
                for (UIWindow *candidate in windowScene.windows) {
                    if (!candidate.hidden && candidate.alpha > 0.0) {
                        window = candidate;
                        break;
                    }
                }
            }

            if (window != nil) {
                break;
            }
        }
    }

    if (window == nil) {
        for (UIWindow *candidate in application.windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
    }

    return IQFCCacheTopViewControllerFrom(window.rootViewController);
}

static id IQFCCacheCreateManualSetting(void) {
    Class settingClass = NSClassFromString(@"IQFSetting");
    SEL selector = NSSelectorFromString(@"buttonCellWithTitle:subtitle:icon:action:");
    if (settingClass == Nil || ![settingClass respondsToSelector:selector]) {
        return nil;
    }

    void (^action)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = IQFCCacheCurrentPresenter();
            if (presenter != nil && presenter.presentedViewController == nil) {
                IQFCCachePresentConfirmation(presenter);
            }
        });
    };

    typedef id (*IQFCCacheButtonFactory)(id, SEL, id, id, id, id);
    IQFCCacheButtonFactory factory = (IQFCCacheButtonFactory)(void *)objc_msgSend;
    return factory(settingClass,
                   selector,
                   IQFCCacheText(@"Limpar cache", @"Clear cache"),
                   nil,
                   @"trash",
                   [action copy]);
}

static id IQFCCacheCreateAutomaticSetting(void) {
    Class settingClass = NSClassFromString(@"IQFSetting");
    SEL selector = NSSelectorFromString(@"optionsCellWithTitle:subtitle:icon:defaultsKey:defaultValue:options:");
    if (settingClass == Nil || ![settingClass respondsToSelector:selector]) {
        return nil;
    }

    NSArray<NSString *> *options = IQFCCacheUsesPortuguese()
        ? @[@"Desativado", @"Diariamente", @"Semanalmente", @"Mensalmente"]
        : @[@"Disabled", @"Daily", @"Weekly", @"Monthly"];

    typedef id (*IQFCCacheOptionsFactory)(id, SEL, id, id, id, id, NSInteger, id);
    IQFCCacheOptionsFactory factory = (IQFCCacheOptionsFactory)(void *)objc_msgSend;
    return factory(settingClass,
                   selector,
                   IQFCCacheText(@"Limpar cache automaticamente", @"Clear cache automatically"),
                   nil,
                   @"clock.arrow.circlepath",
                   IQFCCacheAutoFrequencyKey,
                   0,
                   options);
}

static NSArray *IQFCCacheSectionsWithControls(NSArray *sections) {
    if (![sections isKindOfClass:NSArray.class] || sections.count == 0) {
        return sections;
    }

    NSInteger toolsIndex = NSNotFound;
    BOOL hasManual = NO;
    BOOL hasAutomatic = NO;

    for (NSUInteger sectionIndex = 0; sectionIndex < sections.count; sectionIndex++) {
        id rawSection = sections[sectionIndex];
        if (![rawSection isKindOfClass:NSDictionary.class]) {
            continue;
        }

        NSDictionary *section = (NSDictionary *)rawSection;
        NSString *header = [section[@"header"] isKindOfClass:NSString.class] ? section[@"header"] : nil;
        if (!IQFCCacheIsToolsHeader(header)) {
            continue;
        }

        toolsIndex = (NSInteger)sectionIndex;
        NSArray *rows = [section[@"rows"] isKindOfClass:NSArray.class] ? section[@"rows"] : @[];
        for (id row in rows) {
            NSString *title = IQFCCacheSettingTitle(row);
            hasManual = hasManual || IQFCCacheIsManualTitle(title);
            hasAutomatic = hasAutomatic || IQFCCacheIsAutomaticTitle(title);
        }
        break;
    }

    if (hasManual && hasAutomatic) {
        return sections;
    }

    id manualSetting = hasManual ? nil : IQFCCacheCreateManualSetting();
    id automaticSetting = hasAutomatic ? nil : IQFCCacheCreateAutomaticSetting();

    if ((!hasManual && manualSetting == nil) || (!hasAutomatic && automaticSetting == nil)) {
        return sections;
    }

    NSMutableArray *updatedSections = [sections mutableCopy];

    if (toolsIndex != NSNotFound) {
        NSDictionary *existingSection = updatedSections[(NSUInteger)toolsIndex];
        NSMutableDictionary *updatedSection = [existingSection mutableCopy];
        NSArray *existingRows = [existingSection[@"rows"] isKindOfClass:NSArray.class]
            ? existingSection[@"rows"]
            : @[];
        NSMutableArray *updatedRows = [existingRows mutableCopy];

        if (manualSetting != nil) {
            [updatedRows addObject:manualSetting];
        }
        if (automaticSetting != nil) {
            [updatedRows addObject:automaticSetting];
        }

        updatedSection[@"rows"] = [updatedRows copy];
        updatedSections[(NSUInteger)toolsIndex] = [updatedSection copy];
        return [updatedSections copy];
    }

    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:2];
    if (manualSetting != nil) {
        [rows addObject:manualSetting];
    }
    if (automaticSetting != nil) {
        [rows addObject:automaticSetting];
    }

    NSDictionary *toolsSection = @{
        @"header": IQFCCacheText(@"FERRAMENTAS", @"TOOLS"),
        @"rows": [rows copy]
    };

    NSUInteger insertionIndex = updatedSections.count;
    for (NSUInteger i = 0; i < updatedSections.count; i++) {
        id rawSection = updatedSections[i];
        if (![rawSection isKindOfClass:NSDictionary.class]) {
            continue;
        }

        NSString *header = [rawSection[@"header"] isKindOfClass:NSString.class] ? rawSection[@"header"] : nil;
        if ([header caseInsensitiveCompare:@"DEV"] == NSOrderedSame ||
            [header caseInsensitiveCompare:@"ABOUT"] == NSOrderedSame) {
            insertionIndex = i;
            break;
        }
    }

    [updatedSections insertObject:toolsSection atIndex:MIN(insertionIndex, updatedSections.count)];
    return [updatedSections copy];
}

static NSArray *IQFCCacheTweakSections(id self, SEL command) {
    NSArray *sections = IQFCCacheOriginalTweakSections != NULL
        ? IQFCCacheOriginalTweakSections(self, command)
        : nil;

    return IQFCCacheSectionsWithControls(sections);
}

static void IQFCCacheTryInstallHook(void) {
    if (IQFCCacheHookInstalled) {
        return;
    }

    IQFCCacheHookAttempts += 1;

    Class target = NSClassFromString(@"IQFTweakSettings");
    SEL selector = NSSelectorFromString(@"sections");
    Method method = target != Nil ? class_getClassMethod(target, selector) : NULL;

    if (method != NULL) {
        IQFCCacheOriginalTweakSections = (NSArray *(*)(id, SEL))method_getImplementation(method);
        method_setImplementation(method, (IMP)&IQFCCacheTweakSections);
        IQFCCacheHookInstalled = YES;
    }

    if (!IQFCCacheHookInstalled && IQFCCacheHookAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            IQFCCacheTryInstallHook();
        });
    }
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
            IQFCCacheStartAutomaticScheduler();
        });
    }
}
