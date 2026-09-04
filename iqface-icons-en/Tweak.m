#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

extern void IQFIconsPresentIconPickerFromViewController(UIViewController *presenter);

static void (*IQFIconsOriginalViewDidAppear)(UIViewController *, SEL, BOOL) = NULL;
static BOOL IQFIconsHookInstalled = NO;
static NSInteger IQFIconsHookAttempts = 0;
static const void *IQFIconsRowInstalledKey = &IQFIconsRowInstalledKey;

static BOOL IQFIconsClassImplementsSelector(Class cls, SEL selector) {
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

static BOOL IQFIconsIsToolsHeader(NSString *header) {
    if (![header isKindOfClass:NSString.class]) {
        return NO;
    }
    NSString *normalized = header.lowercaseString;
    return [normalized isEqualToString:@"tools"] ||
           [normalized isEqualToString:@"ferramentas"] ||
           [normalized isEqualToString:@"herramientas"];
}

static BOOL IQFIconsAlreadyContainsRow(NSArray *sections) {
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
            NSString *title = nil;
            @try {
                title = [row valueForKey:@"title"];
            } @catch (__unused NSException *exception) {
                title = nil;
            }
            if ([title isEqualToString:@"Change Icon"] || [title isEqualToString:@"Alterar ícone"]) {
                return YES;
            }
        }
    }
    return NO;
}

static id IQFIconsFindToolsSection(NSArray *sections) {
    for (id section in sections) {
        NSString *header = nil;
        @try {
            header = [section valueForKey:@"header"];
        } @catch (__unused NSException *exception) {
            header = nil;
        }
        if (IQFIconsIsToolsHeader(header)) {
            return section;
        }
    }
    return nil;
}

static id IQFIconsCreateNativeRow(UIViewController *controller) {
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
            IQFIconsPresentIconPickerFromViewController(presenter);
        });
    };

    typedef id (*IQFIconsNativeRowBuilder)(id, SEL, id, id, id, id);
    IQFIconsNativeRowBuilder builder = (IQFIconsNativeRowBuilder)(void *)objc_msgSend;
    return builder(controller, selector, @"Change Icon", @"app", @"", [tapBlock copy]);
}

static void IQFIconsInstallRow(UIViewController *controller) {
    if (controller == nil || objc_getAssociatedObject(controller, IQFIconsRowInstalledKey) != nil) {
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

    if (IQFIconsAlreadyContainsRow(sections)) {
        objc_setAssociatedObject(controller, IQFIconsRowInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    id toolsSection = IQFIconsFindToolsSection(sections);
    if (toolsSection == nil) {
        NSLog(@"[iQFaceIcons] Tools section not found; leaving settings untouched");
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

    id nativeRow = IQFIconsCreateNativeRow(controller);
    Class rowClass = NSClassFromString(@"IQFRow");
    if (nativeRow == nil || rowClass == Nil || ![nativeRow isKindOfClass:rowClass]) {
        NSLog(@"[iQFaceIcons] native IQFRow builder unavailable");
        return;
    }

    NSMutableArray *updatedRows = [rows mutableCopy];
    [updatedRows addObject:nativeRow];

    @try {
        [toolsSection setValue:[updatedRows copy] forKey:@"rows"];
        if ([controller isKindOfClass:UITableViewController.class]) {
            [((UITableViewController *)controller).tableView reloadData];
        }
        objc_setAssociatedObject(controller, IQFIconsRowInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[iQFaceIcons] Change Icon row added");
    } @catch (__unused NSException *exception) {
        NSLog(@"[iQFaceIcons] could not add row; leaving settings untouched");
    }
}

static void IQFIconsViewDidAppear(UIViewController *self, SEL command, BOOL animated) {
    if (IQFIconsOriginalViewDidAppear != NULL) {
        IQFIconsOriginalViewDidAppear(self, command, animated);
    }
    IQFIconsInstallRow(self);
}

static void IQFIconsTryInstallHook(void) {
    if (IQFIconsHookInstalled) {
        return;
    }

    IQFIconsHookAttempts += 1;
    Class target = NSClassFromString(@"IQFSettingsViewController");
    if (target != Nil) {
        SEL selector = @selector(viewDidAppear:);
        Method inheritedOrOwn = class_getInstanceMethod(target, selector);
        if (inheritedOrOwn != NULL) {
            IQFIconsOriginalViewDidAppear = (void (*)(UIViewController *, SEL, BOOL))method_getImplementation(inheritedOrOwn);
            const char *types = method_getTypeEncoding(inheritedOrOwn);

            if (IQFIconsClassImplementsSelector(target, selector)) {
                method_setImplementation(inheritedOrOwn, (IMP)&IQFIconsViewDidAppear);
                IQFIconsHookInstalled = YES;
            } else if (class_addMethod(target, selector, (IMP)&IQFIconsViewDidAppear, types)) {
                IQFIconsHookInstalled = YES;
            }
        }
    }

    if (!IQFIconsHookInstalled && IQFIconsHookAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            IQFIconsTryInstallHook();
        });
    }
}

__attribute__((constructor))
static void IQFIconsInitialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            IQFIconsTryInstallHook();
        });
    }
}
