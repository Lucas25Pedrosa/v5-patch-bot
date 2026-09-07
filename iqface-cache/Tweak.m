#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// iQFaceCache 0.1.0
// Standalone add-on. Does not modify iQFace, iQFaceEnhancer or iQFaceIcons.
// Adds one native IQFRow to the Tools section of IQFSettingsViewController.
// Cleaning is restricted to the two cache directories validated on Facebook 577.1.0.

static void (*IQFCCacheOriginalViewDidAppear)(UIViewController *, SEL, BOOL) = NULL;
static BOOL IQFCCacheHookInstalled = NO;
static NSInteger IQFCCacheHookAttempts = 0;
static const void *IQFCCacheRowInstalledKey = &IQFCCacheRowInstalledKey;

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
    if (![header isKindOfClass:NSString.class]) {
        return NO;
    }
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

static BOOL IQFCCacheIsOwnRowTitle(NSString *title) {
    return [title isEqualToString:@"Limpar cache"] || [title isEqualToString:@"Clear cache"];
}

static BOOL IQFCCacheIsIconRowTitle(NSString *title) {
    return [title isEqualToString:@"Alterar ícone"] || [title isEqualToString:@"Change Icon"];
}

static BOOL IQFCCacheAlreadyContainsRow(NSArray *sections) {
    for (id section in sections) {
        NSArray *rows = nil;
        @try {
            rows = [section valueForKey:@"rows"];
        } @catch (__unused NSException *exception) {
            rows = nil;
        }
        if (![rows isKindOfClass:NSArray.class]) {
            continue;
        }
        for (id row in rows) {
            if (IQFCCacheIsOwnRowTitle(IQFCCacheRowTitle(row))) {
                return YES;
            }
        }
    }
    return NO;
}

static id IQFCCacheFindToolsSection(NSArray *sections) {
    for (id section in sections) {
        NSString *header = nil;
        @try {
            header = [section valueForKey:@"header"];
        } @catch (__unused NSException *exception) {
            header = nil;
        }
        if (IQFCCacheIsToolsHeader(header)) {
            return section;
        }
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
        [errors addObject:@"Blocked non-whitelisted path"];
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
        if (listError != nil) {
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
        } else if (removeError != nil) {
            [errors addObject:removeError.localizedDescription ?: @"Remove error"];
        }
    }
    return removed;
}

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

static void IQFCCachePerformCleaning(UIViewController *controller) {
    __weak UIViewController *weakController = controller;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long before = IQFCCacheTotalSize();
        NSMutableArray<NSString *> *errors = [NSMutableArray array];
        NSUInteger removed = 0;

        for (NSString *path in IQFCCacheTargetPaths()) {
            removed += IQFCCacheClearContentsOfDirectory(path, errors);
        }

        unsigned long long after = IQFCCacheTotalSize();
        unsigned long long freed = before > after ? before - after : 0;
        NSLog(@"[iQFaceCache] before=%llu after=%llu freed=%llu removed=%lu errors=%lu",
              before, after, freed, (unsigned long)removed, (unsigned long)errors.count);

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
            IQFCCachePerformCleaning(presenter);
        }
    }]];

    [controller presentViewController:alert animated:YES completion:nil];
}

static id IQFCCacheCreateNativeRow(UIViewController *controller) {
    SEL selector = NSSelectorFromString(@"valueRowWithTitle:icon:detail:tap:");
    if (controller == nil || ![controller respondsToSelector:selector]) {
        return nil;
    }

    __weak UIViewController *weakController = controller;
    void (^tapBlock)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = weakController;
            if (presenter == nil || presenter.presentedViewController != nil) {
                return;
            }
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

static void IQFCCacheInstallRow(UIViewController *controller) {
    if (controller == nil || objc_getAssociatedObject(controller, IQFCCacheRowInstalledKey) != nil) {
        return;
    }

    NSArray *sections = nil;
    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        sections = nil;
    }

    if (![sections isKindOfClass:NSArray.class] || sections.count == 0) {
        return;
    }

    if (IQFCCacheAlreadyContainsRow(sections)) {
        objc_setAssociatedObject(controller, IQFCCacheRowInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    id toolsSection = IQFCCacheFindToolsSection(sections);
    if (toolsSection == nil) {
        NSLog(@"[iQFaceCache] seção Ferramentas não encontrada; tela mantida intacta");
        return;
    }

    NSArray *rows = nil;
    @try {
        rows = [toolsSection valueForKey:@"rows"];
    } @catch (__unused NSException *exception) {
        rows = nil;
    }
    if (![rows isKindOfClass:NSArray.class]) {
        return;
    }

    id nativeRow = IQFCCacheCreateNativeRow(controller);
    Class rowClass = NSClassFromString(@"IQFRow");
    if (nativeRow == nil || rowClass == Nil || ![nativeRow isKindOfClass:rowClass]) {
        NSLog(@"[iQFaceCache] construtor nativo de IQFRow indisponível");
        return;
    }

    NSMutableArray *updatedRows = [rows mutableCopy];
    NSUInteger insertionIndex = updatedRows.count;
    for (NSUInteger i = 0; i < updatedRows.count; i++) {
        if (IQFCCacheIsIconRowTitle(IQFCCacheRowTitle(updatedRows[i]))) {
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
        objc_setAssociatedObject(controller, IQFCCacheRowInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[iQFaceCache] linha Limpar cache adicionada");
    } @catch (__unused NSException *exception) {
        NSLog(@"[iQFaceCache] não foi possível adicionar a linha; tela mantida intacta");
    }
}

static void IQFCCacheViewDidAppear(UIViewController *self, SEL command, BOOL animated) {
    if (IQFCCacheOriginalViewDidAppear != NULL) {
        IQFCCacheOriginalViewDidAppear(self, command, animated);
    }
    IQFCCacheInstallRow(self);
}

static void IQFCCacheTryInstallHook(void) {
    if (IQFCCacheHookInstalled) {
        return;
    }

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
        });
    }
}
