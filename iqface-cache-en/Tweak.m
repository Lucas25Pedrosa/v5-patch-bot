#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// iQFaceCache English 0.1.0
// Standalone add-on for the English iQFace UI.
// Does not modify iQFace, iQFaceEnhancer, iQFaceIcons, or the Portuguese iQFaceCache source.
// Adds one native IQFRow to the Tools section of IQFSettingsViewController.
// Cleaning is restricted to the two cache directories validated on Facebook 577.1.0.

static void (*IQFCCacheENOriginalViewDidAppear)(UIViewController *, SEL, BOOL) = NULL;
static BOOL IQFCCacheENHookInstalled = NO;
static NSInteger IQFCCacheENHookAttempts = 0;
static const void *IQFCCacheENRowInstalledKey = &IQFCCacheENRowInstalledKey;

static BOOL IQFCCacheENClassImplementsSelector(Class cls, SEL selector) {
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

static BOOL IQFCCacheENIsToolsHeader(NSString *header) {
    if (![header isKindOfClass:NSString.class]) return NO;
    NSString *normalized = header.lowercaseString;
    return [normalized isEqualToString:@"tools"] ||
           [normalized isEqualToString:@"ferramentas"] ||
           [normalized isEqualToString:@"herramientas"];
}

static NSString *IQFCCacheENRowTitle(id row) {
    NSString *title = nil;
    @try {
        title = [row valueForKey:@"title"];
    } @catch (__unused NSException *exception) {
        title = nil;
    }
    return [title isKindOfClass:NSString.class] ? title : nil;
}

static BOOL IQFCCacheENIsOwnRowTitle(NSString *title) {
    return [title isEqualToString:@"Clear cache"] || [title isEqualToString:@"Limpar cache"];
}

static BOOL IQFCCacheENIsIconRowTitle(NSString *title) {
    return [title isEqualToString:@"Change Icon"] || [title isEqualToString:@"Alterar ícone"];
}

static BOOL IQFCCacheENAlreadyContainsRow(NSArray *sections) {
    for (id section in sections) {
        NSArray *rows = nil;
        @try {
            rows = [section valueForKey:@"rows"];
        } @catch (__unused NSException *exception) {
            rows = nil;
        }
        if (![rows isKindOfClass:NSArray.class]) continue;
        for (id row in rows) {
            if (IQFCCacheENIsOwnRowTitle(IQFCCacheENRowTitle(row))) return YES;
        }
    }
    return NO;
}

static id IQFCCacheENFindToolsSection(NSArray *sections) {
    for (id section in sections) {
        NSString *header = nil;
        @try {
            header = [section valueForKey:@"header"];
        } @catch (__unused NSException *exception) {
            header = nil;
        }
        if (IQFCCacheENIsToolsHeader(header)) return section;
    }
    return nil;
}

static NSArray<NSString *> *IQFCCacheENTargetPaths(void) {
    NSString *cacheRoot = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    return @[
        [cacheRoot stringByAppendingPathComponent:@"cask"],
        [cacheRoot stringByAppendingPathComponent:@"com.facebook.Facebook.MosaicIGImageDiskCache"]
    ];
}

static BOOL IQFCCacheENIsAllowedTargetPath(NSString *path) {
    NSString *cacheRoot = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"] stringByStandardizingPath];
    NSString *standardPath = [path stringByStandardizingPath];
    NSString *expectedPrefix = [cacheRoot stringByAppendingString:@"/"];
    if (![standardPath hasPrefix:expectedPrefix]) return NO;

    NSString *name = standardPath.lastPathComponent;
    return [name isEqualToString:@"cask"] ||
           [name isEqualToString:@"com.facebook.Facebook.MosaicIGImageDiskCache"];
}

static unsigned long long IQFCCacheENDirectorySize(NSString *path) {
    if (!IQFCCacheENIsAllowedTargetPath(path)) return 0;

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

static unsigned long long IQFCCacheENTotalSize(void) {
    unsigned long long total = 0;
    for (NSString *path in IQFCCacheENTargetPaths()) {
        total += IQFCCacheENDirectorySize(path);
    }
    return total;
}

static NSString *IQFCCacheENHumanBytes(unsigned long long bytes) {
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
    if (unit == 0) return [NSString stringWithFormat:@"%.0f %@", value, units[unit]];
    return [NSString stringWithFormat:@"%.1f %@", value, units[unit]];
}

static NSUInteger IQFCCacheENClearContentsOfDirectory(NSString *path, NSMutableArray<NSString *> *errors) {
    if (!IQFCCacheENIsAllowedTargetPath(path)) {
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

static void IQFCCacheENPresentResult(UIViewController *controller,
                                     unsigned long long freed,
                                     NSUInteger errorCount) {
    if (controller == nil || controller.presentedViewController != nil) return;

    NSString *message = [NSString stringWithFormat:@"%@ freed", IQFCCacheENHumanBytes(freed)];
    if (errorCount > 0) {
        message = [message stringByAppendingString:@"\n\nSome files were in use."];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"✓ Cache cleared"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void IQFCCacheENPerformCleaning(UIViewController *controller) {
    __weak UIViewController *weakController = controller;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long before = IQFCCacheENTotalSize();
        NSMutableArray<NSString *> *errors = [NSMutableArray array];
        NSUInteger removed = 0;

        for (NSString *path in IQFCCacheENTargetPaths()) {
            removed += IQFCCacheENClearContentsOfDirectory(path, errors);
        }

        unsigned long long after = IQFCCacheENTotalSize();
        unsigned long long freed = before > after ? before - after : 0;
        NSLog(@"[iQFaceCacheEN] before=%llu after=%llu freed=%llu removed=%lu errors=%lu",
              before, after, freed, (unsigned long)removed, (unsigned long)errors.count);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *presenter = weakController;
            if (presenter == nil || presenter.view.window == nil) return;
            IQFCCacheENPresentResult(presenter, freed, errors.count);
        });
    });
}

static void IQFCCacheENPresentConfirmation(UIViewController *controller) {
    if (controller == nil || controller.presentedViewController != nil) return;

    unsigned long long bytes = IQFCCacheENTotalSize();
    NSString *message = [NSString stringWithFormat:@"Approximately %@ of temporary files will be removed.",
                         IQFCCacheENHumanBytes(bytes)];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    __weak UIViewController *weakController = controller;
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        UIViewController *presenter = weakController;
        if (presenter != nil) IQFCCacheENPerformCleaning(presenter);
    }]];

    [controller presentViewController:alert animated:YES completion:nil];
}

static id IQFCCacheENCreateNativeRow(UIViewController *controller) {
    SEL selector = NSSelectorFromString(@"valueRowWithTitle:icon:detail:tap:");
    if (controller == nil || ![controller respondsToSelector:selector]) return nil;

    __weak UIViewController *weakController = controller;
    void (^tapBlock)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = weakController;
            if (presenter == nil || presenter.presentedViewController != nil) return;
            IQFCCacheENPresentConfirmation(presenter);
        });
    };

    typedef id (*IQFCCacheENNativeRowBuilder)(id, SEL, id, id, id, id);
    IQFCCacheENNativeRowBuilder builder = (IQFCCacheENNativeRowBuilder)(void *)objc_msgSend;
    return builder(controller, selector, @"Clear cache", @"trash", @"", [tapBlock copy]);
}

static void IQFCCacheENInstallRow(UIViewController *controller) {
    if (controller == nil || objc_getAssociatedObject(controller, IQFCCacheENRowInstalledKey) != nil) return;

    NSArray *sections = nil;
    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        sections = nil;
    }
    if (![sections isKindOfClass:NSArray.class] || sections.count == 0) return;

    if (IQFCCacheENAlreadyContainsRow(sections)) {
        objc_setAssociatedObject(controller, IQFCCacheENRowInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    id toolsSection = IQFCCacheENFindToolsSection(sections);
    if (toolsSection == nil) {
        NSLog(@"[iQFaceCacheEN] Tools section not found; settings left untouched");
        return;
    }

    NSArray *rows = nil;
    @try {
        rows = [toolsSection valueForKey:@"rows"];
    } @catch (__unused NSException *exception) {
        rows = nil;
    }
    if (![rows isKindOfClass:NSArray.class]) return;

    id nativeRow = IQFCCacheENCreateNativeRow(controller);
    Class rowClass = NSClassFromString(@"IQFRow");
    if (nativeRow == nil || rowClass == Nil || ![nativeRow isKindOfClass:rowClass]) {
        NSLog(@"[iQFaceCacheEN] native IQFRow builder unavailable");
        return;
    }

    NSMutableArray *updatedRows = [rows mutableCopy];
    NSUInteger insertionIndex = updatedRows.count;
    for (NSUInteger i = 0; i < updatedRows.count; i++) {
        if (IQFCCacheENIsIconRowTitle(IQFCCacheENRowTitle(updatedRows[i]))) {
            insertionIndex = i + 1;
            break;
        }
    }
    [updatedRows insertObject:nativeRow atIndex:MIN(insertionIndex, updatedRows.count)];

    @try {
        [toolsSection setValue:[updatedRows copy] forKey:@"rows"];
        if ([controller isKindOfClass:UITableViewController.class]) {
            [((UITableViewController *)controller).tableView reloadData];
        }
        objc_setAssociatedObject(controller, IQFCCacheENRowInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[iQFaceCacheEN] Clear cache row added");
    } @catch (__unused NSException *exception) {
        NSLog(@"[iQFaceCacheEN] could not add row; settings left untouched");
    }
}

static void IQFCCacheENViewDidAppear(UIViewController *self, SEL command, BOOL animated) {
    if (IQFCCacheENOriginalViewDidAppear != NULL) {
        IQFCCacheENOriginalViewDidAppear(self, command, animated);
    }
    IQFCCacheENInstallRow(self);
}

static void IQFCCacheENTryInstallHook(void) {
    if (IQFCCacheENHookInstalled) return;

    IQFCCacheENHookAttempts += 1;
    Class target = NSClassFromString(@"IQFSettingsViewController");
    if (target != Nil) {
        SEL selector = @selector(viewDidAppear:);
        Method inheritedOrOwn = class_getInstanceMethod(target, selector);
        if (inheritedOrOwn != NULL) {
            IQFCCacheENOriginalViewDidAppear = (void (*)(UIViewController *, SEL, BOOL))method_getImplementation(inheritedOrOwn);
            const char *types = method_getTypeEncoding(inheritedOrOwn);

            if (IQFCCacheENClassImplementsSelector(target, selector)) {
                method_setImplementation(inheritedOrOwn, (IMP)&IQFCCacheENViewDidAppear);
                IQFCCacheENHookInstalled = YES;
            } else if (class_addMethod(target, selector, (IMP)&IQFCCacheENViewDidAppear, types)) {
                IQFCCacheENHookInstalled = YES;
            }
        }
    }

    if (!IQFCCacheENHookInstalled && IQFCCacheENHookAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            IQFCCacheENTryInstallHook();
        });
    }
}

__attribute__((constructor))
static void IQFCCacheENInitialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            IQFCCacheENTryInstallHook();
        });
    }
}
