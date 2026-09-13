#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

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

static NSString *NexusTitleForSetting(id setting) {
    if (setting == nil) return nil;
    @try {
        id title = [setting valueForKey:@"title"];
        return [title isKindOfClass:NSString.class] ? title : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL NexusIsToolsHeader(NSString *header) {
    if (![header isKindOfClass:NSString.class]) return NO;
    NSString *normalized = header.lowercaseString;
    return [normalized isEqualToString:@"ferramentas"] ||
           [normalized isEqualToString:@"tools"] ||
           [normalized isEqualToString:@"herramientas"];
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

static NSArray *NexusSectionsWithTools(NSArray *sections) {
    if (![sections isKindOfClass:NSArray.class]) return sections;

    NSArray *ownedRows = NexusRows();
    if (ownedRows.count == 0) return sections;

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
        updatedSection[@"header"] = @"FERRAMENTAS";
        updatedSection[@"rows"] = [rows copy];
        updatedSections[(NSUInteger)toolsIndex] = [updatedSection copy];
        return [updatedSections copy];
    }

    NSDictionary *toolsSection = @{
        @"header": @"FERRAMENTAS",
        @"rows": ownedRows
    };

    NSUInteger insertionIndex = updatedSections.count;
    for (NSUInteger i = 0; i < updatedSections.count; i++) {
        id rawSection = updatedSections[i];
        if (![rawSection isKindOfClass:NSDictionary.class]) continue;
        NSString *header = [rawSection[@"header"] isKindOfClass:NSString.class]
            ? rawSection[@"header"]
            : nil;
        if ([header caseInsensitiveCompare:@"DEV"] == NSOrderedSame ||
            [header caseInsensitiveCompare:@"ABOUT"] == NSOrderedSame ||
            [header caseInsensitiveCompare:@"SOBRE"] == NSOrderedSame) {
            insertionIndex = i;
            break;
        }
    }

    [updatedSections insertObject:toolsSection atIndex:MIN(insertionIndex, updatedSections.count)];
    return [updatedSections copy];
}

static NSArray *NexusTweakSections(id self, SEL command) {
    NSArray *sections = NexusOriginalSections != NULL
        ? NexusOriginalSections(self, command)
        : nil;
    return NexusSectionsWithTools(sections);
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
