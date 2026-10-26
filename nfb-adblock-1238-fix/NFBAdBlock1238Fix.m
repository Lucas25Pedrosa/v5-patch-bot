#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kFixVersion = @"1.1";
static NSString *const kLogName = @"NFBAdBlock1238Fix.log";

static IMP gOrigSetSections = NULL;
static IMP gOrigUpdateSections = NULL;
static BOOL gHookInstalled = NO;
static NSUInteger gSeenItems = 0;
static NSUInteger gRemovedItems = 0;
static NSUInteger gWrappedItems = 0;

static NSString *LogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:kLogName];
}

static void LogLine(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *df = [NSDateFormatter new];
    df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], body];

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = LogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh closeFile];
    }
    NSLog(@"[NFBAdBlock1238Fix] %@", body);
}

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

static id StatusItemFromPresentedItem(id item, BOOL *wrappedOut) {
    if (wrappedOut) *wrappedOut = NO;
    if (!item) return nil;

    if (IsStatusItemClass(item)) {
        return item;
    }

    // X 12.38 conversation/thread timelines wrap URT status items in
    // TFNDataViewItem. The probe showed the status view model in `_item`.
    if (!IsDataViewItemClass(item)) {
        return nil;
    }

    Ivar itemIvar = FindIvarInHierarchy([item class], "_item");
    if (!itemIvar) {
        itemIvar = FindIvarInHierarchy([item class], "item");
    }
    if (!itemIvar) return nil;

    id child = object_getIvar(item, itemIvar);
    if (!IsStatusItemClass(child)) return nil;

    if (wrappedOut) *wrappedOut = YES;
    return child;
}

static BOOL StatusItemIsPromoted(id statusItem) {
    if (!IsStatusItemClass(statusItem)) return NO;

    Ivar statusIvar = FindIvarInHierarchy([statusItem class], "status");
    if (!statusIvar) {
        static NSMutableSet<NSString *> *loggedMissing;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ loggedMissing = [NSMutableSet set]; });
        NSString *name = NSStringFromClass([statusItem class]);
        @synchronized (loggedMissing) {
            if (![loggedMissing containsObject:name]) {
                [loggedMissing addObject:name];
                LogLine(@"STATUS_IVAR_MISSING class=%@", name);
            }
        }
        return NO;
    }

    id status = object_getIvar(statusItem, statusIvar);
    SEL promotedSEL = NSSelectorFromString(@"isPromoted");
    if (!status || ![status respondsToSelector:promotedSEL]) {
        return NO;
    }

    return ((BOOL (*)(id, SEL))objc_msgSend)(status, promotedSEL);
}

static NSArray *FilteredSections(NSArray *sections, NSString *source) {
    if (!FixEnabled() || ![sections isKindOfClass:[NSArray class]]) return sections;

    BOOL modified = NO;
    NSMutableArray *outSections = [NSMutableArray arrayWithCapacity:sections.count];
    NSUInteger removedThisPass = 0;
    NSUInteger statusItemsThisPass = 0;
    NSUInteger wrappedThisPass = 0;

    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            [outSections addObject:section];
            continue;
        }

        NSMutableArray *kept = [NSMutableArray arrayWithCapacity:[section count]];
        for (id presentedItem in (NSArray *)section) {
            BOOL wrapped = NO;
            id statusItem = StatusItemFromPresentedItem(presentedItem, &wrapped);

            if (statusItem) {
                statusItemsThisPass++;
                gSeenItems++;
                if (wrapped) {
                    wrappedThisPass++;
                    gWrappedItems++;
                }

                if (StatusItemIsPromoted(statusItem)) {
                    removedThisPass++;
                    gRemovedItems++;
                    modified = YES;
                    LogLine(@"REMOVE source=%@ outerClass=%@ statusClass=%@ wrapped=%d",
                            source,
                            NSStringFromClass([presentedItem class]),
                            NSStringFromClass([statusItem class]),
                            wrapped ? 1 : 0);
                    continue;
                }
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

    if (statusItemsThisPass || removedThisPass || wrappedThisPass) {
        LogLine(@"FILTER source=%@ statusItems=%lu wrapped=%lu removed=%lu totalSeen=%lu totalWrapped=%lu totalRemoved=%lu",
                source,
                (unsigned long)statusItemsThisPass,
                (unsigned long)wrappedThisPass,
                (unsigned long)removedThisPass,
                (unsigned long)gSeenItems,
                (unsigned long)gWrappedItems,
                (unsigned long)gRemovedItems);
    }

    return modified ? outSections : sections;
}

static void ReplacementSetSections(id self, SEL _cmd, NSArray *sections, BOOL restore) {
    NSArray *filtered = FilteredSections(sections, @"setSections");
    ((void (*)(id, SEL, NSArray *, BOOL))gOrigSetSections)(self, _cmd, filtered, restore);
}

static void ReplacementUpdateSections(id self, SEL _cmd, NSArray *sections, NSArray *identifiers, long long animation, id completion) {
    NSArray *filtered = FilteredSections(sections, @"updateSections");
    ((void (*)(id, SEL, NSArray *, NSArray *, long long, id))gOrigUpdateSections)(self, _cmd, filtered, identifiers, animation, completion);
}

static void InstallHooks(void) {
    if (gHookInstalled) return;

    Class cls = objc_getClass("TFNItemsDataViewController");
    if (!cls) {
        LogLine(@"HOOK_WAIT class=TFNItemsDataViewController present=0");
        return;
    }

    SEL setSel = NSSelectorFromString(@"setSections:restoreScrollPosition:");
    Method setMethod = class_getInstanceMethod(cls, setSel);
    SEL updateSel = NSSelectorFromString(@"updateSections:reconfigureItemIdentifiers:withRowAnimation:completion:");
    Method updateMethod = class_getInstanceMethod(cls, updateSel);

    if (setMethod && !gOrigSetSections) {
        gOrigSetSections = method_getImplementation(setMethod);
        method_setImplementation(setMethod, (IMP)ReplacementSetSections);
    }

    if (updateMethod && !gOrigUpdateSections) {
        gOrigUpdateSections = method_getImplementation(updateMethod);
        method_setImplementation(updateMethod, (IMP)ReplacementUpdateSections);
    }

    gHookInstalled = (gOrigSetSections != NULL || gOrigUpdateSections != NULL);

    Class oldClass = objc_getClass("T1URTTimelineStatusItemViewModel");
    Class newClass = objc_getClass("URTTimelineStatusItemViewModel");
    Class wrapperClass = objc_getClass("TFNDataViewItem");
    Class swiftClass = NSClassFromString(@"TwitterURT.URTTimelineStatusItemViewModel");

    LogLine(@"HOOK_RESULT version=%@ installed=%d setSections=%d updateSections=%d hide_promoted=%d oldClass=%d newClass=%d wrapperClass=%d swiftClass=%d",
            kFixVersion,
            gHookInstalled,
            gOrigSetSections != NULL,
            gOrigUpdateSections != NULL,
            FixEnabled(),
            oldClass != Nil,
            newClass != Nil,
            wrapperClass != Nil,
            swiftClass != Nil);
}

__attribute__((constructor)) static void NFBAdBlock1238FixInit(void) {
    LogLine(@"NEW_SESSION version=%@ target=X_12.38 purpose=timeline-and-conversation-promoted-status-filter", kFixVersion);

    NSArray<NSNumber *> *delays = @[@0.0, @0.25, @0.75, @1.5, @3.0];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            InstallHooks();
        });
    }
}
