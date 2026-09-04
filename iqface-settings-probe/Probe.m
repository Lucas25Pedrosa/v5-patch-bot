#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

extern void IQFSPPresentIconPickerFromViewController(UIViewController *presenter);

static void (*IQFSPOriginalViewDidAppear)(UIViewController *, SEL, BOOL) = NULL;
static BOOL IQFSPHookInstalled = NO;
static NSInteger IQFSPHookAttempts = 0;
static const void *IQFSPRowInstalledKey = &IQFSPRowInstalledKey;

static BOOL IQFSPClassImplementsSelector(Class cls, SEL selector) {
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

static BOOL IQFSPIsToolsHeader(NSString *header) {
    if (![header isKindOfClass:NSString.class]) {
        return NO;
    }
    NSString *normalized = header.lowercaseString;
    return [normalized isEqualToString:@"tools"] ||
           [normalized isEqualToString:@"ferramentas"] ||
           [normalized isEqualToString:@"herramientas"];
}

static BOOL IQFSPAlreadyContainsIconRow(NSArray *sections) {
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
            if ([title isEqualToString:@"Alterar ícone"] || [title isEqualToString:@"Change Icon"]) {
                return YES;
            }
        }
    }
    return NO;
}

static id IQFSPFindToolsSection(NSArray *sections) {
    for (id section in sections) {
        NSString *header = nil;
        @try {
            header = [section valueForKey:@"header"];
        } @catch (__unused NSException *exception) {
            header = nil;
        }
        if (IQFSPIsToolsHeader(header)) {
            return section;
        }
    }
    return nil;
}

static id IQFSPCreateNativeIconRow(UIViewController *controller) {
    SEL selector = NSSelectorFromString(@"valueRowWithTitle:icon:detail:tap:");
    if (controller == nil || ![controller respondsToSelector:selector]) {
        return nil;
    }

    BOOL portuguese = [NSLocale.preferredLanguages.firstObject.lowercaseString hasPrefix:@"pt"];
    NSString *title = portuguese ? @"Alterar ícone" : @"Change Icon";

    __weak UIViewController *weakController = controller;
    void (^tapBlock)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = weakController;
            if (presenter == nil || presenter.presentedViewController != nil) {
                return;
            }
            IQFSPPresentIconPickerFromViewController(presenter);
        });
    };

    typedef id (*IQFSPNativeRowBuilder)(id, SEL, id, id, id, id);
    IQFSPNativeRowBuilder builder = (IQFSPNativeRowBuilder)(void *)objc_msgSend;
    return builder(controller, selector, title, @"app", @"", [tapBlock copy]);
}

static void IQFSPInstallIconRow(UIViewController *controller) {
    if (controller == nil || objc_getAssociatedObject(controller, IQFSPRowInstalledKey) != nil) {
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

    if (IQFSPAlreadyContainsIconRow(sections)) {
        objc_setAssociatedObject(controller, IQFSPRowInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    id toolsSection = IQFSPFindToolsSection(sections);
    if (toolsSection == nil) {
        NSLog(@"[iQFaceSettingsProbe] Tools section not found; leaving settings untouched");
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

    id nativeRow = IQFSPCreateNativeIconRow(controller);
    if (nativeRow == nil || ![nativeRow isKindOfClass:NSClassFromString(@"IQFRow")]) {
        NSLog(@"[iQFaceSettingsProbe] iQFace native row builder unavailable");
        return;
    }

    NSMutableArray *updatedRows = [rows mutableCopy];
    [updatedRows addObject:nativeRow];

    @try {
        [toolsSection setValue:[updatedRows copy] forKey:@"rows"];
        if ([controller isKindOfClass:UITableViewController.class]) {
            [((UITableViewController *)controller).tableView reloadData];
        }
        objc_setAssociatedObject(controller, IQFSPRowInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[iQFaceSettingsProbe] Change Icon row inserted through native iQFace builder");
    } @catch (__unused NSException *exception) {
        NSLog(@"[iQFaceSettingsProbe] Could not append native row; settings left untouched");
    }
}

static void IQFSPViewDidAppear(UIViewController *self, SEL command, BOOL animated) {
    if (IQFSPOriginalViewDidAppear != NULL) {
        IQFSPOriginalViewDidAppear(self, command, animated);
    }
    IQFSPInstallIconRow(self);
}

static void IQFSPTryInstallHook(void) {
    if (IQFSPHookInstalled) {
        return;
    }

    IQFSPHookAttempts += 1;
    Class target = NSClassFromString(@"IQFSettingsViewController");
    if (target != Nil) {
        SEL selector = @selector(viewDidAppear:);
        Method inheritedOrOwn = class_getInstanceMethod(target, selector);
        if (inheritedOrOwn != NULL) {
            IQFSPOriginalViewDidAppear = (void (*)(UIViewController *, SEL, BOOL))method_getImplementation(inheritedOrOwn);
            const char *types = method_getTypeEncoding(inheritedOrOwn);

            if (IQFSPClassImplementsSelector(target, selector)) {
                method_setImplementation(inheritedOrOwn, (IMP)&IQFSPViewDidAppear);
                IQFSPHookInstalled = YES;
            } else if (class_addMethod(target, selector, (IMP)&IQFSPViewDidAppear, types)) {
                IQFSPHookInstalled = YES;
            }
        }
    }

    if (!IQFSPHookInstalled && IQFSPHookAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            IQFSPTryInstallHook();
        });
    }
}

__attribute__((constructor))
static void IQFSPInitialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            IQFSPTryInstallHook();
        });
    }
}
