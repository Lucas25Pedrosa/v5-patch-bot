#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// NFBAdBlock1238Fix 1.1 FINAL
// X 12.38 — production build with probe/logging removed.
// Keeps only the validated promoted-status filtering for home + conversation/thread timelines.

static IMP gOrigSetSections = NULL;
static IMP gOrigUpdateSections = NULL;
static BOOL gHookInstalled = NO;

static BOOL FixEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"hide_promoted"];
}

static Ivar FindIvarInHierarchy(Class cls, const char *name) {
    for (Class current = cls; current != Nil; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *ivarName = ivar_getName(ivars[i]);
            if (ivarName && strcmp(ivarName, name) == 0) {
                Ivar found = ivars[i];
                free(ivars);
                return found;
            }
        }
        free(ivars);
    }
    return NULL;
}

static BOOL IsStatusItemClass(id item) {
    if (!item) return NO;
    NSString *name = NSStringFromClass([item class]);
    return [name isEqualToString:@"URTTimelineStatusItemViewModel"] ||
           [name isEqualToString:@"T1URTTimelineStatusItemViewModel"] ||
           [name hasSuffix:@".URTTimelineStatusItemViewModel"];
}

static BOOL IsDataViewItemClass(id item) {
    if (!item) return NO;
    NSString *name = NSStringFromClass([item class]);
    return [name isEqualToString:@"TFNDataViewItem"] ||
           [name hasSuffix:@".TFNDataViewItem"];
}

static id StatusItemFromPresentedItem(id item) {
    if (!item) return nil;

    if (IsStatusItemClass(item)) {
        return item;
    }

    // X 12.38 conversation/thread timelines wrap URT status items in
    // TFNDataViewItem. The validated inner status view model lives in `_item`.
    if (!IsDataViewItemClass(item)) {
        return nil;
    }

    Ivar itemIvar = FindIvarInHierarchy([item class], "_item");
    if (!itemIvar) {
        itemIvar = FindIvarInHierarchy([item class], "item");
    }
    if (!itemIvar) return nil;

    id child = object_getIvar(item, itemIvar);
    return IsStatusItemClass(child) ? child : nil;
}

static BOOL StatusItemIsPromoted(id statusItem) {
    if (!IsStatusItemClass(statusItem)) return NO;

    Ivar statusIvar = FindIvarInHierarchy([statusItem class], "status");
    if (!statusIvar) return NO;

    id status = object_getIvar(statusItem, statusIvar);
    SEL promotedSEL = NSSelectorFromString(@"isPromoted");
    if (!status || ![status respondsToSelector:promotedSEL]) return NO;

    return ((BOOL (*)(id, SEL))objc_msgSend)(status, promotedSEL);
}

static NSArray *FilteredSections(NSArray *sections) {
    if (!FixEnabled() || ![sections isKindOfClass:[NSArray class]]) return sections;

    BOOL modified = NO;
    NSMutableArray *outSections = [NSMutableArray arrayWithCapacity:sections.count];

    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            [outSections addObject:section];
            continue;
        }

        NSMutableArray *kept = [NSMutableArray arrayWithCapacity:[section count]];
        for (id presentedItem in (NSArray *)section) {
            id statusItem = StatusItemFromPresentedItem(presentedItem);
            if (statusItem && StatusItemIsPromoted(statusItem)) {
                modified = YES;
                continue;
            }
            [kept addObject:presentedItem];
        }

        if (kept.count > 0) {
            [outSections addObject:kept];
        } else if ([(NSArray *)section count] == 0) {
            [outSections addObject:section];
        } else {
            modified = YES;
        }
    }

    return modified ? outSections : sections;
}

static void ReplacementSetSections(id self, SEL _cmd, NSArray *sections, BOOL restore) {
    NSArray *filtered = FilteredSections(sections);
    ((void (*)(id, SEL, NSArray *, BOOL))gOrigSetSections)(self, _cmd, filtered, restore);
}

static void ReplacementUpdateSections(id self, SEL _cmd, NSArray *sections, NSArray *identifiers, long long animation, id completion) {
    NSArray *filtered = FilteredSections(sections);
    ((void (*)(id, SEL, NSArray *, NSArray *, long long, id))gOrigUpdateSections)(self, _cmd, filtered, identifiers, animation, completion);
}

static void InstallHooks(void) {
    if (gHookInstalled) return;

    Class cls = objc_getClass("TFNItemsDataViewController");
    if (!cls) return;

    SEL setSel = NSSelectorFromString(@"setSections:restoreScrollPosition:");
    Method setMethod = class_getInstanceMethod(cls, setSel);
    if (setMethod && !gOrigSetSections) {
        gOrigSetSections = method_getImplementation(setMethod);
        method_setImplementation(setMethod, (IMP)ReplacementSetSections);
    }

    SEL updateSel = NSSelectorFromString(@"updateSections:reconfigureItemIdentifiers:withRowAnimation:completion:");
    Method updateMethod = class_getInstanceMethod(cls, updateSel);
    if (updateMethod && !gOrigUpdateSections) {
        gOrigUpdateSections = method_getImplementation(updateMethod);
        method_setImplementation(updateMethod, (IMP)ReplacementUpdateSections);
    }

    gHookInstalled = (gOrigSetSections != NULL || gOrigUpdateSections != NULL);
}

__attribute__((constructor)) static void NFBAdBlock1238FixInit(void) {
    NSArray<NSNumber *> *delays = @[@0.0, @0.25, @0.75, @1.5, @3.0];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            InstallHooks();
        });
    }
}
