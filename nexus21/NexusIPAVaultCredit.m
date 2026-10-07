#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Nexus 2.1.1 — IPA Vault credit bridge.
// Mirrors the Nexus 1.0.2 credit: IPA Vault / IPA Source • Nexus Distributor
// using the same shippingbox.circle icon and https://t.me/ipavault target.

static NSArray *(*NXIPAOriginalSections)(id, SEL) = NULL;
static BOOL NXIPAHookInstalled = NO;
static NSInteger NXIPAHookAttempts = 0;

static NSString *NXIPASettingTitle(id setting) {
    if (setting == nil) return nil;
    @try {
        id value = [setting valueForKey:@"title"];
        return [value isKindOfClass:NSString.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id NXIPACreateCreditSetting(void) {
    Class settingClass = NSClassFromString(@"IQFSetting");
    SEL selector = NSSelectorFromString(@"buttonCellWithTitle:subtitle:icon:action:");
    if (settingClass == Nil || ![settingClass respondsToSelector:selector]) return nil;

    void (^action)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *url = [NSURL URLWithString:@"https://t.me/ipavault"];
            if (url == nil) return;
            [UIApplication.sharedApplication openURL:url
                                            options:@{}
                                  completionHandler:nil];
        });
    };

    typedef id (*Factory)(id, SEL, id, id, id, id);
    Factory factory = (Factory)(void *)objc_msgSend;
    return factory(settingClass,
                   selector,
                   @"IPA Vault",
                   @"IPA Source • Nexus Distributor",
                   @"shippingbox.circle",
                   [action copy]);
}

static NSArray *NXIPASectionsWithCredit(NSArray *sections) {
    if (![sections isKindOfClass:NSArray.class] || sections.count == 0) return sections;

    NSMutableArray *updatedSections = [sections mutableCopy];

    for (NSUInteger sectionIndex = 0; sectionIndex < updatedSections.count; sectionIndex++) {
        id rawSection = updatedSections[sectionIndex];
        if (![rawSection isKindOfClass:NSDictionary.class]) continue;

        NSDictionary *section = (NSDictionary *)rawSection;
        NSArray *rows = [section[@"rows"] isKindOfClass:NSArray.class] ? section[@"rows"] : @[];

        NSInteger lucasIndex = NSNotFound;
        NSInteger iqTweakIndex = NSNotFound;

        for (NSUInteger rowIndex = 0; rowIndex < rows.count; rowIndex++) {
            NSString *title = NXIPASettingTitle(rows[rowIndex]);
            if ([title isEqualToString:@"IPA Vault"]) return sections;
            if ([title isEqualToString:@"Lucas"]) lucasIndex = (NSInteger)rowIndex;
            if ([title isEqualToString:@"iQTweak"]) iqTweakIndex = (NSInteger)rowIndex;
        }

        // The Lucas row uniquely identifies the developer/credits section in Nexus 2.1.
        if (lucasIndex == NSNotFound) continue;

        id credit = NXIPACreateCreditSetting();
        if (credit == nil) return sections;

        NSMutableArray *updatedRows = [rows mutableCopy];
        NSUInteger insertionIndex;
        if (iqTweakIndex != NSNotFound) {
            insertionIndex = (NSUInteger)iqTweakIndex + 1;
        } else {
            insertionIndex = (NSUInteger)lucasIndex + 1;
        }
        insertionIndex = MIN(insertionIndex, updatedRows.count);
        [updatedRows insertObject:credit atIndex:insertionIndex];

        NSMutableDictionary *updatedSection = [section mutableCopy];
        updatedSection[@"rows"] = [updatedRows copy];
        updatedSections[sectionIndex] = [updatedSection copy];
        return [updatedSections copy];
    }

    return sections;
}

static NSArray *NXIPATweakSections(id self, SEL command) {
    NSArray *sections = NXIPAOriginalSections != NULL
        ? NXIPAOriginalSections(self, command)
        : nil;
    return NXIPASectionsWithCredit(sections);
}

static void NXIPATryInstallHook(void) {
    if (NXIPAHookInstalled) return;
    NXIPAHookAttempts += 1;

    Class target = NSClassFromString(@"IQFTweakSettings");
    SEL selector = NSSelectorFromString(@"sections");
    Method method = target != Nil ? class_getClassMethod(target, selector) : NULL;

    if (method != NULL) {
        NXIPAOriginalSections = (NSArray *(*)(id, SEL))method_getImplementation(method);
        method_setImplementation(method, (IMP)&NXIPATweakSections);
        NXIPAHookInstalled = YES;
        return;
    }

    if (NXIPAHookAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ NXIPATryInstallHook(); });
    }
}

__attribute__((constructor))
static void NXIPAInitialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        // Nexus2 installs its own IQFTweakSettings hook asynchronously on launch.
        // Install this bridge shortly afterwards so it wraps the final Nexus sections.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ NXIPATryInstallHook(); });
    }
}
