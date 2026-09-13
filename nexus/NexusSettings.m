#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

__attribute__((used, visibility("default"))) NSString * const NexusVersion = @"1.0";

extern id NexusIconsCreateSetting(void);
extern id NexusCacheCreateManualSetting(void);
extern id NexusCacheCreateAutomaticSetting(void);
extern id NexusOLEDCreateModeSetting(void);
extern id NexusOLEDCreateSeparatorSetting(void);
extern void NexusOLEDPrepareSettingsCell(void);

static NSArray *(*NexusOriginalSections)(id, SEL) = NULL;
static BOOL NexusHookInstalled = NO;
static NSInteger NexusHookAttempts = 0;

static NSString *NexusStringProperty(id object, NSString *key) {
    if (object == nil || key.length == 0) return nil;
    @try {
        id value = [object valueForKey:key];
        return [value isKindOfClass:NSString.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *NexusTitleForSetting(id setting) {
    return NexusStringProperty(setting, @"title");
}

static NSString *NexusSubtitleForSetting(id setting) {
    return NexusStringProperty(setting, @"subtitle");
}

static BOOL NexusIsToolsHeader(NSString *header) {
    if (![header isKindOfClass:NSString.class]) return NO;
    NSString *normalized = header.lowercaseString;
    return [normalized isEqualToString:@"nexus"] ||
           [normalized isEqualToString:@"ferramentas"] ||
           [normalized isEqualToString:@"tools"] ||
           [normalized isEqualToString:@"herramientas"];
}

static BOOL NexusIsDevHeader(NSString *header) {
    if (![header isKindOfClass:NSString.class]) return NO;
    NSString *normalized = header.lowercaseString;
    return [normalized isEqualToString:@"dev"] ||
           [normalized isEqualToString:@"developer"] ||
           [normalized isEqualToString:@"desenvolvedor"] ||
           [normalized isEqualToString:@"desarrollador"];
}

static BOOL NexusIsAboutHeader(NSString *header) {
    if (![header isKindOfClass:NSString.class]) return NO;
    NSString *normalized = header.lowercaseString;
    return [normalized isEqualToString:@"about"] ||
           [normalized isEqualToString:@"sobre"];
}

static BOOL NexusIsOwnedTitle(NSString *title) {
    if (![title isKindOfClass:NSString.class]) return NO;
    return [title isEqualToString:@"Alterar ícone"] ||
           [title isEqualToString:@"Change Icon"] ||
           [title isEqualToString:@"Modo OLED"] ||
           [title isEqualToString:@"OLED Mode"] ||
           [title isEqualToString:@"Separadores no feed"] ||
           [title isEqualToString:@"Feed separators"] ||
           [title isEqualToString:@"Limpar cache"] ||
           [title isEqualToString:@"Clear cache"] ||
           [title isEqualToString:@"Limpar cache automaticamente"] ||
           [title isEqualToString:@"Clear cache automatically"];
}

static id NexusCreateButtonSetting(NSString *title,
                                   NSString *subtitle,
                                   NSString *icon,
                                   void (^action)(void)) {
    Class settingClass = NSClassFromString(@"IQFSetting");
    SEL selector = NSSelectorFromString(@"buttonCellWithTitle:subtitle:icon:action:");
    if (settingClass == Nil || ![settingClass respondsToSelector:selector]) return nil;

    typedef id (*Factory)(id, SEL, id, id, id, id);
    Factory factory = (Factory)(void *)objc_msgSend;
    return factory(settingClass, selector, title, subtitle, icon, [action copy]);
}

static id NexusCreateStaticSetting(NSString *title,
                                   NSString *subtitle,
                                   NSString *icon) {
    Class settingClass = NSClassFromString(@"IQFSetting");
    SEL selector = NSSelectorFromString(@"staticCellWithTitle:subtitle:icon:");
    if (settingClass == Nil || ![settingClass respondsToSelector:selector]) return nil;

    typedef id (*Factory)(id, SEL, id, id, id);
    Factory factory = (Factory)(void *)objc_msgSend;
    return factory(settingClass, selector, title, subtitle, icon);
}

static id NexusCreateDeveloperCredit(void) {
    void (^action)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *url = [NSURL URLWithString:@"https://t.me/lucaspedrosa"];
            if (url == nil) return;
            [UIApplication.sharedApplication openURL:url
                                            options:@{}
                                  completionHandler:nil];
        });
    };

    return NexusCreateButtonSetting(@"Lucas",
                                    @"Desenvolvedor do Nexus",
                                    @"paperplane.fill",
                                    action);
}

static id NexusCreateAboutVersion(void) {
    return NexusCreateStaticSetting(@"Nexus v1.0", nil, @"point.3.connected.trianglepath.dotted");
}

static NSArray *NexusRows(void) {
    NexusOLEDPrepareSettingsCell();

    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:5];
    id icon = NexusIconsCreateSetting();
    id oled = NexusOLEDCreateModeSetting();
    id separators = NexusOLEDCreateSeparatorSetting();
    id cache = NexusCacheCreateManualSetting();
    id autoCache = NexusCacheCreateAutomaticSetting();

    if (icon != nil) [rows addObject:icon];
    if (oled != nil) [rows addObject:oled];
    if (separators != nil) [rows addObject:separators];
    if (cache != nil) [rows addObject:cache];
    if (autoCache != nil) [rows addObject:autoCache];
    return [rows copy];
}

static void NexusAddDeveloperCredit(NSMutableArray *sections) {
    for (NSUInteger i = 0; i < sections.count; i++) {
        id rawSection = sections[i];
        if (![rawSection isKindOfClass:NSDictionary.class]) continue;

        NSDictionary *section = (NSDictionary *)rawSection;
        NSString *header = [section[@"header"] isKindOfClass:NSString.class]
            ? section[@"header"]
            : nil;
        if (!NexusIsDevHeader(header)) continue;

        NSArray *existingRows = [section[@"rows"] isKindOfClass:NSArray.class]
            ? section[@"rows"]
            : @[];

        for (id row in existingRows) {
            if ([NexusTitleForSetting(row) isEqualToString:@"Lucas"] &&
                [NexusSubtitleForSetting(row) isEqualToString:@"Desenvolvedor do Nexus"]) {
                return;
            }
        }

        id credit = NexusCreateDeveloperCredit();
        if (credit == nil) return;

        NSMutableArray *rows = [existingRows mutableCopy];
        [rows addObject:credit];

        NSMutableDictionary *updatedSection = [section mutableCopy];
        updatedSection[@"rows"] = [rows copy];
        sections[i] = [updatedSection copy];
        return;
    }
}

static void NexusAddAboutVersion(NSMutableArray *sections) {
    for (NSUInteger i = 0; i < sections.count; i++) {
        id rawSection = sections[i];
        if (![rawSection isKindOfClass:NSDictionary.class]) continue;

        NSDictionary *section = (NSDictionary *)rawSection;
        NSString *header = [section[@"header"] isKindOfClass:NSString.class]
            ? section[@"header"]
            : nil;
        if (!NexusIsAboutHeader(header)) continue;

        NSArray *existingRows = [section[@"rows"] isKindOfClass:NSArray.class]
            ? section[@"rows"]
            : @[];

        for (id row in existingRows) {
            if ([NexusTitleForSetting(row) isEqualToString:@"Nexus v1.0"]) {
                return;
            }
        }

        id version = NexusCreateAboutVersion();
        if (version == nil) return;

        NSMutableArray *rows = [existingRows mutableCopy];
        NSUInteger insertionIndex = rows.count;

        for (NSUInteger rowIndex = 0; rowIndex < rows.count; rowIndex++) {
            NSString *title = NexusTitleForSetting(rows[rowIndex]);
            NSString *normalized = title.lowercaseString;
            if ([normalized hasPrefix:@"iqface v1.1"]) {
                insertionIndex = rowIndex + 1;
                break;
            }
        }

        [rows insertObject:version atIndex:MIN(insertionIndex, rows.count)];

        NSMutableDictionary *updatedSection = [section mutableCopy];
        updatedSection[@"rows"] = [rows copy];
        sections[i] = [updatedSection copy];
        return;
    }
}

static NSArray *NexusSectionsWithAdditions(NSArray *sections) {
    if (![sections isKindOfClass:NSArray.class]) return sections;

    NSArray *ownedRows = NexusRows();
    NSMutableArray *updatedSections = [sections mutableCopy];
    NSInteger toolsIndex = NSNotFound;

    for (NSUInteger i = 0; i < updatedSections.count; i++) {
        id rawSection = updatedSections[i];
        if (![rawSection isKindOfClass:NSDictionary.class]) continue;
        NSString *header = [rawSection[@"header"] isKindOfClass:NSString.class]
            ? rawSection[@"header"]
            : nil;
        if (NexusIsToolsHeader(header)) {
            toolsIndex = (NSInteger)i;
            break;
        }
    }

    if (ownedRows.count > 0) {
        if (toolsIndex != NSNotFound) {
            NSDictionary *section = updatedSections[(NSUInteger)toolsIndex];
            NSArray *existingRows = [section[@"rows"] isKindOfClass:NSArray.class]
                ? section[@"rows"]
                : @[];
            NSMutableArray *rows = [NSMutableArray arrayWithArray:ownedRows];

            for (id row in existingRows) {
                if (!NexusIsOwnedTitle(NexusTitleForSetting(row))) {
                    [rows addObject:row];
                }
            }

            NSMutableDictionary *updatedSection = [section mutableCopy];
            updatedSection[@"header"] = @"NEXUS";
            updatedSection[@"rows"] = [rows copy];
            updatedSections[(NSUInteger)toolsIndex] = [updatedSection copy];
        } else {
            NSDictionary *nexusSection = @{
                @"header": @"NEXUS",
                @"rows": ownedRows
            };

            NSUInteger insertionIndex = updatedSections.count;
            for (NSUInteger i = 0; i < updatedSections.count; i++) {
                id rawSection = updatedSections[i];
                if (![rawSection isKindOfClass:NSDictionary.class]) continue;
                NSString *header = [rawSection[@"header"] isKindOfClass:NSString.class]
                    ? rawSection[@"header"]
                    : nil;
                if (NexusIsDevHeader(header) || NexusIsAboutHeader(header)) {
                    insertionIndex = i;
                    break;
                }
            }

            [updatedSections insertObject:nexusSection
                                  atIndex:MIN(insertionIndex, updatedSections.count)];
        }
    }

    NexusAddDeveloperCredit(updatedSections);
    NexusAddAboutVersion(updatedSections);
    return [updatedSections copy];
}

static NSArray *NexusTweakSections(id self, SEL command) {
    NSArray *sections = NexusOriginalSections != NULL
        ? NexusOriginalSections(self, command)
        : nil;
    return NexusSectionsWithAdditions(sections);
}

static void NexusTryInstallHook(void) {
    if (NexusHookInstalled) return;
    NexusHookAttempts += 1;

    Class target = NSClassFromString(@"IQFTweakSettings");
    SEL selector = NSSelectorFromString(@"sections");
    Method method = target != Nil ? class_getClassMethod(target, selector) : NULL;

    if (method != NULL) {
        NexusOriginalSections = (NSArray *(*)(id, SEL))method_getImplementation(method);
        method_setImplementation(method, (IMP)&NexusTweakSections);
        NexusHookInstalled = YES;
    }

    if (!NexusHookInstalled && NexusHookAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ NexusTryInstallHook(); });
    }
}

__attribute__((constructor))
static void NexusInitialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ NexusTryInstallHook(); });
    }
}
