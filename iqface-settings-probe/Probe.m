#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern void IQFSPPresentIconPickerFromViewController(UIViewController *presenter);

static void (*IQFSPOriginalViewDidLoad)(UIViewController *, SEL) = NULL;
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

static BOOL IQFSPIsMainSettingsController(UIViewController *controller, NSArray *sections) {
    NSString *title = controller.navigationItem.title ?: controller.title ?: @"";
    if ([title rangeOfString:@"iQFace" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }

    for (id section in sections) {
        NSString *header = nil;
        @try {
            header = [section valueForKey:@"header"];
        } @catch (__unused NSException *exception) {
            header = nil;
        }
        if ([header isEqualToString:@"Features"] ||
            [header isEqualToString:@"Recursos"] ||
            [header isEqualToString:@"Feed"] ||
            [header isEqualToString:@"Confirmations"] ||
            [header isEqualToString:@"Confirmações"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL IQFSPAlreadyContainsIconRow(NSArray *sections) {
    for (id section in sections) {
        NSArray *rows = nil;
        @try {
            rows = [section valueForKey:@"rows"];
        } @catch (__unused NSException *exception) {
            rows = nil;
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
    if (![sections isKindOfClass:NSArray.class] || sections.count == 0 || !IQFSPIsMainSettingsController(controller, sections)) {
        return;
    }

    if (IQFSPAlreadyContainsIconRow(sections)) {
        objc_setAssociatedObject(controller, IQFSPRowInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    Class rowClass = NSClassFromString(@"IQFRow");
    Class sectionClass = NSClassFromString(@"IQFSection");
    if (rowClass == Nil || sectionClass == Nil) {
        return;
    }

    id row = [rowClass new];
    id section = [sectionClass new];
    if (row == nil || section == nil) {
        return;
    }

    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString;
    BOOL portuguese = [language hasPrefix:@"pt"];
    NSString *rowTitle = portuguese ? @"Alterar ícone" : @"Change Icon";

    @try {
        [row setValue:rowTitle forKey:@"title"];
        [row setValue:@YES forKey:@"isNav"];

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
        [row setValue:tapBlock forKey:@"tap"];
        [section setValue:@[row] forKey:@"rows"];
    } @catch (__unused NSException *exception) {
        return;
    }

    NSMutableArray *updatedSections = [sections mutableCopy];
    [updatedSections insertObject:section atIndex:0];

    @try {
        [controller setValue:[updatedSections copy] forKey:@"sections"];
        if ([controller isKindOfClass:UITableViewController.class]) {
            [((UITableViewController *)controller).tableView reloadData];
        }
        objc_setAssociatedObject(controller, IQFSPRowInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[iQFaceSettingsProbe] native Change Icon row inserted");
    } @catch (__unused NSException *exception) {
    }
}

static void IQFSPViewDidLoad(UIViewController *self, SEL command) {
    if (IQFSPOriginalViewDidLoad != NULL) {
        IQFSPOriginalViewDidLoad(self, command);
    }

    IQFSPInstallIconRow(self);
    if (objc_getAssociatedObject(self, IQFSPRowInstalledKey) == nil) {
        __weak UIViewController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            IQFSPInstallIconRow(weakSelf);
        });
    }
}

static void IQFSPTryInstallHook(void) {
    if (IQFSPHookInstalled) {
        return;
    }

    IQFSPHookAttempts += 1;
    Class target = NSClassFromString(@"IQFSettingsViewController");
    if (target != Nil) {
        SEL selector = @selector(viewDidLoad);
        Method inheritedOrOwn = class_getInstanceMethod(target, selector);
        if (inheritedOrOwn != NULL) {
            IQFSPOriginalViewDidLoad = (void (*)(UIViewController *, SEL))method_getImplementation(inheritedOrOwn);
            const char *types = method_getTypeEncoding(inheritedOrOwn);

            if (IQFSPClassImplementsSelector(target, selector)) {
                method_setImplementation(inheritedOrOwn, (IMP)&IQFSPViewDidLoad);
                IQFSPHookInstalled = YES;
            } else if (class_addMethod(target, selector, (IMP)&IQFSPViewDidLoad, types)) {
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
