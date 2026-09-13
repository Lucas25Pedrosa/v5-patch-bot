#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

__attribute__((used, visibility("default"))) NSString * const NexusReleaseVersion102 = @"1.0.2";

static NSArray *(*Nexus102OriginalSections)(id, SEL) = NULL;
static BOOL Nexus102Installed = NO;
static NSInteger Nexus102Attempts = 0;

static NSString *Nexus102String(id object, NSString *key) {
    if (object == nil) return nil;
    @try {
        id value = [object valueForKey:key];
        return [value isKindOfClass:NSString.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL Nexus102HasNexusRow(NSArray *sections) {
    if (![sections isKindOfClass:NSArray.class]) return NO;
    for (id rawSection in sections) {
        if (![rawSection isKindOfClass:NSDictionary.class]) continue;
        NSArray *rows = [rawSection[@"rows"] isKindOfClass:NSArray.class] ? rawSection[@"rows"] : @[];
        for (id row in rows) {
            if ([Nexus102String(row, @"title") isEqualToString:@"Nexus"]) return YES;
        }
    }
    return NO;
}

static NSArray *Nexus102Sections(id self, SEL command) {
    NSArray *sections = Nexus102OriginalSections != NULL ? Nexus102OriginalSections(self, command) : nil;
    for (id rawSection in sections) {
        if (![rawSection isKindOfClass:NSDictionary.class]) continue;
        NSArray *rows = [rawSection[@"rows"] isKindOfClass:NSArray.class] ? rawSection[@"rows"] : @[];
        for (id row in rows) {
            if (![Nexus102String(row, @"title") isEqualToString:@"Nexus"]) continue;
            @try { [row setValue:@"v1.0.2" forKey:@"valueText"]; }
            @catch (__unused NSException *exception) {}
        }
    }
    return sections;
}

static void Nexus102TryInstall(void) {
    if (Nexus102Installed) return;
    Nexus102Attempts += 1;

    Class target = NSClassFromString(@"IQFTweakSettings");
    SEL selector = NSSelectorFromString(@"sections");
    Method method = target != Nil ? class_getClassMethod(target, selector) : NULL;
    if (method != NULL) {
        IMP current = method_getImplementation(method);
        NSArray *(*currentSections)(id, SEL) = (NSArray *(*)(id, SEL))current;
        NSArray *sections = currentSections(target, selector);
        if (Nexus102HasNexusRow(sections)) {
            Nexus102OriginalSections = currentSections;
            method_setImplementation(method, (IMP)&Nexus102Sections);
            Nexus102Installed = YES;
            return;
        }
    }

    if (Nexus102Attempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ Nexus102TryInstall(); });
    }
}

__attribute__((constructor))
static void Nexus102Initialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{ Nexus102TryInstall(); });
    }
}
