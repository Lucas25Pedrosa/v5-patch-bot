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

static NSString *IQFIconsSectionHeader(id section) {
    NSString *header = nil;
    @try {
        header = [section valueForKey:@"header"];
    } @catch (__unused NSException *exception) {
        header = nil;
    }
    return [header isKindOfClass:NSString.class] ? header : nil;
}

static NSArray *IQFIconsSectionRows(id section) {
    NSArray *rows = nil;
    @try {
        rows = [section valueForKey:@"rows"];
    } @catch (__unused NSException *exception) {
        rows = nil;
    }
    return [rows isKindOfClass:NSArray.class] ? rows : nil;
}

static NSString *IQFIconsRowTitle(id row) {
    NSString *title = nil;
    @try {
        title = [row valueForKey:@"title"];
    } @catch (__unused NSException *exception) {
        title = nil;
    }
    return [title isKindOfClass:NSString.class] ? title : nil;
}

static NSString *IQFIconsRowDetail(id row) {
    NSString *detail = nil;
    @try {
        detail = [row valueForKey:@"detail"];
    } @catch (__unused NSException *exception) {
        detail = nil;
    }
    return [detail isKindOfClass:NSString.class] ? detail : nil;
}

static BOOL IQFIconsIsToolsHeader(NSString *header) {
    if (![header isKindOfClass:NSString.class]) return NO;
    NSString *normalized = header.lowercaseString;
    return [normalized isEqualToString:@"tools"] ||
           [normalized isEqualToString:@"ferramentas"] ||
           [normalized isEqualToString:@"herramientas"];
}

static BOOL IQFIconsIsCreditsHeader(NSString *header) {
    if (![header isKindOfClass:NSString.class]) return NO;
    NSString *normalized = header.lowercaseString;
    return [normalized isEqualToString:@"developer"] ||
           [normalized isEqualToString:@"desenvolvedor"] ||
           [normalized isEqualToString:@"desarrollador"] ||
           [normalized isEqualToString:@"about"] ||
           [normalized isEqualToString:@"sobre"];
}

static id IQFIconsFindSection(NSArray *sections, BOOL (^predicate)(NSString *header)) {
    for (id section in sections) {
        NSString *header = IQFIconsSectionHeader(section);
        if (predicate(header)) return section;
    }
    return nil;
}

static BOOL IQFIconsContainsChangeIconRow(NSArray *sections) {
    for (id section in sections) {
        for (id row in IQFIconsSectionRows(section)) {
            NSString *title = IQFIconsRowTitle(row);
            if ([title isEqualToString:@"Change Icon"] || [title isEqualToString:@"Alterar ícone"]) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL IQFIconsContainsContributorRow(NSArray *sections) {
    for (id section in sections) {
        for (id row in IQFIconsSectionRows(section)) {
            NSString *title = IQFIconsRowTitle(row);
            NSString *detail = IQFIconsRowDetail(row);
            if ([title isEqualToString:@"Lucas"] && [detail isEqualToString:@"Contributor"]) {
                return YES;
            }
        }
    }
    return NO;
}

static id IQFIconsCreateNativeValueRow(UIViewController *controller,
                                       NSString *title,
                                       NSString *icon,
                                       NSString *detail,
                                       void (^tapBlock)(void)) {
    SEL selector = NSSelectorFromString(@"valueRowWithTitle:icon:detail:tap:");
    if (controller == nil || ![controller respondsToSelector:selector]) return nil;

    typedef id (*IQFIconsNativeRowBuilder)(id, SEL, id, id, id, id);
    IQFIconsNativeRowBuilder builder = (IQFIconsNativeRowBuilder)(void *)objc_msgSend;
    return builder(controller, selector, title, icon, detail, [tapBlock copy]);
}

static id IQFIconsCreateChangeIconRow(UIViewController *controller) {
    __weak UIViewController *weakController = controller;
    void (^tapBlock)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = weakController;
            if (presenter == nil || presenter.presentedViewController != nil) return;
            IQFIconsPresentIconPickerFromViewController(presenter);
        });
    };

    return IQFIconsCreateNativeValueRow(controller, @"Change Icon", @"app", @"", tapBlock);
}

static id IQFIconsCreateContributorRow(UIViewController *controller) {
    void (^tapBlock)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *url = [NSURL URLWithString:@"https://t.me/lucaspedrosa"];
            if (url == nil) return;
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        });
    };

    return IQFIconsCreateNativeValueRow(controller,
                                        @"Lucas",
                                        @"person.crop.circle",
                                        @"Contributor",
                                        tapBlock);
}

static BOOL IQFIconsAppendNativeRow(id section, id row) {
    Class rowClass = NSClassFromString(@"IQFRow");
    NSArray *rows = IQFIconsSectionRows(section);
    if (section == nil || row == nil || rowClass == Nil || ![row isKindOfClass:rowClass] || rows == nil) {
        return NO;
    }

    NSMutableArray *updatedRows = [rows mutableCopy];
    [updatedRows addObject:row];
    @try {
        [section setValue:[updatedRows copy] forKey:@"rows"];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static void IQFIconsInstallRows(UIViewController *controller) {
    if (controller == nil || objc_getAssociatedObject(controller, IQFIconsRowInstalledKey) != nil) return;

    NSArray *sections = nil;
    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        sections = nil;
    }
    if (![sections isKindOfClass:NSArray.class] || sections.count == 0) return;

    BOOL hasChangeIcon = IQFIconsContainsChangeIconRow(sections);
    BOOL hasContributor = IQFIconsContainsContributorRow(sections);
    BOOL changed = NO;

    if (!hasChangeIcon) {
        id toolsSection = IQFIconsFindSection(sections, ^BOOL(NSString *header) {
            return IQFIconsIsToolsHeader(header);
        });
        if (toolsSection != nil) {
            id changeIconRow = IQFIconsCreateChangeIconRow(controller);
            if (IQFIconsAppendNativeRow(toolsSection, changeIconRow)) {
                hasChangeIcon = YES;
                changed = YES;
                NSLog(@"[iQFaceIcons] Change Icon row added");
            }
        }
    }

    if (!hasContributor) {
        id creditsSection = IQFIconsFindSection(sections, ^BOOL(NSString *header) {
            return IQFIconsIsCreditsHeader(header);
        });
        if (creditsSection != nil) {
            id contributorRow = IQFIconsCreateContributorRow(controller);
            if (IQFIconsAppendNativeRow(creditsSection, contributorRow)) {
                hasContributor = YES;
                changed = YES;
                NSLog(@"[iQFaceIcons] Lucas Contributor credit added");
            }
        } else {
            NSLog(@"[iQFaceIcons] credits section not found; leaving contributor credit untouched");
        }
    }

    if (changed && [controller isKindOfClass:UITableViewController.class]) {
        [((UITableViewController *)controller).tableView reloadData];
    }

    if (hasChangeIcon && hasContributor) {
        objc_setAssociatedObject(controller, IQFIconsRowInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void IQFIconsViewDidAppear(UIViewController *self, SEL command, BOOL animated) {
    if (IQFIconsOriginalViewDidAppear != NULL) {
        IQFIconsOriginalViewDidAppear(self, command, animated);
    }
    IQFIconsInstallRows(self);
}

static void IQFIconsTryInstallHook(void) {
    if (IQFIconsHookInstalled) return;

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
