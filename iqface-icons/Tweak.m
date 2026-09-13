#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// iQFaceIcons 1.1.0
// iQFace 1.1-only settings integration using IQFSetting + IQFTweakSettings.
// Keeps the existing icon picker unchanged and replaces only the old IQFRow bridge.

static NSArray *(*IQFIconsOriginalTweakSections)(id, SEL) = NULL;
static BOOL IQFIconsHookInstalled = NO;
static NSInteger IQFIconsHookAttempts = 0;

static NSString *IQFIconsSettingTitle(id setting) {
    if (setting == nil) {
        return nil;
    }

    SEL selector = NSSelectorFromString(@"title");
    if (![setting respondsToSelector:selector]) {
        return nil;
    }

    typedef id (*IQFIconsObjectGetter)(id, SEL);
    IQFIconsObjectGetter getter = (IQFIconsObjectGetter)(void *)objc_msgSend;
    id value = getter(setting, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static BOOL IQFIconsIsOwnTitle(NSString *title) {
    return [title isEqualToString:@"Alterar ícone"] ||
           [title isEqualToString:@"Change Icon"];
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

static BOOL IQFIconsSectionsAlreadyContainSetting(NSArray *sections) {
    for (id rawSection in sections) {
        if (![rawSection isKindOfClass:NSDictionary.class]) {
            continue;
        }

        NSArray *rows = [rawSection[@"rows"] isKindOfClass:NSArray.class]
            ? rawSection[@"rows"]
            : @[];

        for (id row in rows) {
            if (IQFIconsIsOwnTitle(IQFIconsSettingTitle(row))) {
                return YES;
            }
        }
    }
    return NO;
}

static id IQFIconsCreateNavigationSetting(void) {
    Class settingClass = NSClassFromString(@"IQFSetting");
    Class pickerClass = NSClassFromString(@"IQFIconsPickerController");
    SEL selector = NSSelectorFromString(@"navigationCellWithTitle:subtitle:icon:viewController:");

    if (settingClass == Nil || pickerClass == Nil ||
        ![settingClass respondsToSelector:selector]) {
        return nil;
    }

    UIViewController *picker = [pickerClass new];
    if (![picker isKindOfClass:UIViewController.class]) {
        return nil;
    }

    typedef id (*IQFIconsNavigationFactory)(id, SEL, id, id, id, id);
    IQFIconsNavigationFactory factory = (IQFIconsNavigationFactory)(void *)objc_msgSend;
    return factory(settingClass,
                   selector,
                   @"Alterar ícone",
                   nil,
                   @"app",
                   picker);
}

static NSArray *IQFIconsSectionsWithControl(NSArray *sections) {
    if (![sections isKindOfClass:NSArray.class] || sections.count == 0) {
        return sections;
    }

    if (IQFIconsSectionsAlreadyContainSetting(sections)) {
        return sections;
    }

    id iconSetting = IQFIconsCreateNavigationSetting();
    if (iconSetting == nil) {
        return sections;
    }

    NSMutableArray *updatedSections = [sections mutableCopy];
    NSInteger toolsIndex = NSNotFound;

    for (NSUInteger i = 0; i < updatedSections.count; i++) {
        id rawSection = updatedSections[i];
        if (![rawSection isKindOfClass:NSDictionary.class]) {
            continue;
        }

        NSString *header = [rawSection[@"header"] isKindOfClass:NSString.class]
            ? rawSection[@"header"]
            : nil;
        if (IQFIconsIsToolsHeader(header)) {
            toolsIndex = (NSInteger)i;
            break;
        }
    }

    if (toolsIndex != NSNotFound) {
        NSDictionary *existingSection = updatedSections[(NSUInteger)toolsIndex];
        NSMutableDictionary *updatedSection = [existingSection mutableCopy];
        NSArray *existingRows = [existingSection[@"rows"] isKindOfClass:NSArray.class]
            ? existingSection[@"rows"]
            : @[];
        NSMutableArray *updatedRows = [existingRows mutableCopy];
        [updatedRows addObject:iconSetting];
        updatedSection[@"rows"] = [updatedRows copy];
        updatedSections[(NSUInteger)toolsIndex] = [updatedSection copy];
        return [updatedSections copy];
    }

    NSDictionary *toolsSection = @{
        @"header": @"FERRAMENTAS",
        @"rows": @[iconSetting]
    };

    NSUInteger insertionIndex = updatedSections.count;
    for (NSUInteger i = 0; i < updatedSections.count; i++) {
        id rawSection = updatedSections[i];
        if (![rawSection isKindOfClass:NSDictionary.class]) {
            continue;
        }

        NSString *header = [rawSection[@"header"] isKindOfClass:NSString.class]
            ? rawSection[@"header"]
            : nil;
        if ([header caseInsensitiveCompare:@"DEV"] == NSOrderedSame ||
            [header caseInsensitiveCompare:@"ABOUT"] == NSOrderedSame) {
            insertionIndex = i;
            break;
        }
    }

    [updatedSections insertObject:toolsSection atIndex:MIN(insertionIndex, updatedSections.count)];
    return [updatedSections copy];
}

static NSArray *IQFIconsTweakSections(id self, SEL command) {
    NSArray *sections = IQFIconsOriginalTweakSections != NULL
        ? IQFIconsOriginalTweakSections(self, command)
        : nil;
    return IQFIconsSectionsWithControl(sections);
}

static void IQFIconsTryInstallHook(void) {
    if (IQFIconsHookInstalled) {
        return;
    }

    IQFIconsHookAttempts += 1;

    Class target = NSClassFromString(@"IQFTweakSettings");
    SEL selector = NSSelectorFromString(@"sections");
    Method method = target != Nil ? class_getClassMethod(target, selector) : NULL;

    if (method != NULL) {
        IQFIconsOriginalTweakSections = (NSArray *(*)(id, SEL))method_getImplementation(method);
        method_setImplementation(method, (IMP)&IQFIconsTweakSections);
        IQFIconsHookInstalled = YES;
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
