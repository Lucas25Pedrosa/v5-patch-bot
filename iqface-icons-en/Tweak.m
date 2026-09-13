#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// iQFaceIcons 1.1.0 English
// iQFace 1.1-only settings integration using IQFSetting + IQFTweakSettings.
// Keeps the existing English icon picker and contributor links unchanged in behavior.

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

static BOOL IQFIconsIsToolsHeader(NSString *header) {
    if (![header isKindOfClass:NSString.class]) {
        return NO;
    }

    NSString *normalized = header.lowercaseString;
    return [normalized isEqualToString:@"tools"] ||
           [normalized isEqualToString:@"ferramentas"] ||
           [normalized isEqualToString:@"herramientas"];
}

static BOOL IQFIconsIsCreditsHeader(NSString *header) {
    if (![header isKindOfClass:NSString.class]) {
        return NO;
    }

    NSString *normalized = header.lowercaseString;
    return [normalized isEqualToString:@"dev"] ||
           [normalized isEqualToString:@"developer"] ||
           [normalized isEqualToString:@"desenvolvedor"] ||
           [normalized isEqualToString:@"desarrollador"] ||
           [normalized isEqualToString:@"about"] ||
           [normalized isEqualToString:@"sobre"];
}

static BOOL IQFIconsSectionsContainTitle(NSArray *sections, NSString *wantedTitle) {
    for (id rawSection in sections) {
        if (![rawSection isKindOfClass:NSDictionary.class]) {
            continue;
        }

        NSArray *rows = [rawSection[@"rows"] isKindOfClass:NSArray.class]
            ? rawSection[@"rows"]
            : @[];

        for (id row in rows) {
            if ([IQFIconsSettingTitle(row) isEqualToString:wantedTitle]) {
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
                   @"Change Icon",
                   nil,
                   @"app",
                   picker);
}

static id IQFIconsCreateLinkButton(NSString *title,
                                   NSString *subtitle,
                                   NSString *icon,
                                   NSString *urlString) {
    Class settingClass = NSClassFromString(@"IQFSetting");
    SEL selector = NSSelectorFromString(@"buttonCellWithTitle:subtitle:icon:action:");
    if (settingClass == Nil || ![settingClass respondsToSelector:selector]) {
        return nil;
    }

    void (^action)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *url = [NSURL URLWithString:urlString];
            if (url == nil) {
                return;
            }
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        });
    };

    typedef id (*IQFIconsButtonFactory)(id, SEL, id, id, id, id);
    IQFIconsButtonFactory factory = (IQFIconsButtonFactory)(void *)objc_msgSend;
    return factory(settingClass,
                   selector,
                   title,
                   subtitle,
                   icon,
                   [action copy]);
}

static NSInteger IQFIconsFindSectionIndex(NSArray *sections, BOOL (^predicate)(NSString *header)) {
    for (NSUInteger i = 0; i < sections.count; i++) {
        id rawSection = sections[i];
        if (![rawSection isKindOfClass:NSDictionary.class]) {
            continue;
        }

        NSString *header = [rawSection[@"header"] isKindOfClass:NSString.class]
            ? rawSection[@"header"]
            : nil;
        if (predicate(header)) {
            return (NSInteger)i;
        }
    }
    return NSNotFound;
}

static void IQFIconsAppendSetting(NSMutableArray *sections,
                                  NSInteger sectionIndex,
                                  id setting) {
    if (setting == nil || sectionIndex == NSNotFound ||
        sectionIndex < 0 || (NSUInteger)sectionIndex >= sections.count) {
        return;
    }

    NSDictionary *existingSection = sections[(NSUInteger)sectionIndex];
    if (![existingSection isKindOfClass:NSDictionary.class]) {
        return;
    }

    NSMutableDictionary *updatedSection = [existingSection mutableCopy];
    NSArray *existingRows = [existingSection[@"rows"] isKindOfClass:NSArray.class]
        ? existingSection[@"rows"]
        : @[];
    NSMutableArray *updatedRows = [existingRows mutableCopy];
    [updatedRows addObject:setting];
    updatedSection[@"rows"] = [updatedRows copy];
    sections[(NSUInteger)sectionIndex] = [updatedSection copy];
}

static NSUInteger IQFIconsPreferredToolsInsertionIndex(NSArray *sections) {
    for (NSUInteger i = 0; i < sections.count; i++) {
        id rawSection = sections[i];
        if (![rawSection isKindOfClass:NSDictionary.class]) {
            continue;
        }

        NSString *header = [rawSection[@"header"] isKindOfClass:NSString.class]
            ? rawSection[@"header"]
            : nil;
        if (IQFIconsIsCreditsHeader(header)) {
            return i;
        }
    }
    return sections.count;
}

static NSArray *IQFIconsSectionsWithControls(NSArray *sections) {
    if (![sections isKindOfClass:NSArray.class] || sections.count == 0) {
        return sections;
    }

    BOOL hasChangeIcon = IQFIconsSectionsContainTitle(sections, @"Change Icon") ||
                         IQFIconsSectionsContainTitle(sections, @"Alterar ícone");
    BOOL hasContributor = IQFIconsSectionsContainTitle(sections, @"Lucas");
    BOOL hasIPAVault = IQFIconsSectionsContainTitle(sections, @"IPA Vault");

    if (hasChangeIcon && hasContributor && hasIPAVault) {
        return sections;
    }

    NSMutableArray *updatedSections = [sections mutableCopy];

    NSInteger toolsIndex = IQFIconsFindSectionIndex(updatedSections, ^BOOL(NSString *header) {
        return IQFIconsIsToolsHeader(header);
    });

    if (!hasChangeIcon) {
        id changeIcon = IQFIconsCreateNavigationSetting();
        if (changeIcon != nil) {
            if (toolsIndex == NSNotFound) {
                NSDictionary *toolsSection = @{
                    @"header": @"TOOLS",
                    @"rows": @[changeIcon]
                };
                NSUInteger insertionIndex = IQFIconsPreferredToolsInsertionIndex(updatedSections);
                [updatedSections insertObject:toolsSection
                                       atIndex:MIN(insertionIndex, updatedSections.count)];
                toolsIndex = (NSInteger)MIN(insertionIndex, updatedSections.count - 1);
            } else {
                IQFIconsAppendSetting(updatedSections, toolsIndex, changeIcon);
            }
            hasChangeIcon = YES;
        }
    }

    NSInteger creditsIndex = IQFIconsFindSectionIndex(updatedSections, ^BOOL(NSString *header) {
        return IQFIconsIsCreditsHeader(header);
    });

    NSMutableArray *creditSettings = [NSMutableArray array];
    if (!hasContributor) {
        id contributor = IQFIconsCreateLinkButton(@"Lucas",
                                                   @"Contributor",
                                                   @"person.crop.circle",
                                                   @"https://t.me/lucaspedrosa");
        if (contributor != nil) {
            [creditSettings addObject:contributor];
        }
    }

    if (!hasIPAVault) {
        id ipaVault = IQFIconsCreateLinkButton(@"IPA Vault",
                                                @"IPA Source",
                                                @"shippingbox.circle",
                                                @"https://t.me/ipavault");
        if (ipaVault != nil) {
            [creditSettings addObject:ipaVault];
        }
    }

    if (creditSettings.count > 0) {
        if (creditsIndex != NSNotFound) {
            for (id setting in creditSettings) {
                IQFIconsAppendSetting(updatedSections, creditsIndex, setting);
            }
        } else {
            NSDictionary *creditsSection = @{
                @"header": @"CONTRIBUTORS",
                @"rows": [creditSettings copy]
            };
            [updatedSections addObject:creditsSection];
        }
    }

    return [updatedSections copy];
}

static NSArray *IQFIconsTweakSections(id self, SEL command) {
    NSArray *sections = IQFIconsOriginalTweakSections != NULL
        ? IQFIconsOriginalTweakSections(self, command)
        : nil;
    return IQFIconsSectionsWithControls(sections);
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
