#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kProbeVersion = @"1.0";
static NSString *const kLogName = @"NFBAdBlock1238ThreadProbe.log";
static IMP gOrigSetSections = NULL;
static IMP gOrigUpdateSections = NULL;
static IMP gOrigViewDidAppear = NULL;
static BOOL gItemsHooked = NO;
static BOOL gVCGuardHooked = NO;

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
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS Z";
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
    NSLog(@"[NFBAdBlock1238ThreadProbe] %@", body);
}

static BOOL LooksRelevantControllerName(NSString *name) {
    if (!name.length) return NO;
    NSArray<NSString *> *tokens = @[@"Conversation", @"Thread", @"Tweet", @"Status", @"Detail", @"Timeline", @"ItemsData"];
    for (NSString *token in tokens) {
        if ([name rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static void ProbeObject(id obj, NSString *prefix, NSUInteger depth) {
    if (!obj || depth > 1) return;
    NSString *clsName = NSStringFromClass([obj class]);
    SEL promotedSEL = NSSelectorFromString(@"isPromoted");
    if ([obj respondsToSelector:promotedSEL]) {
        BOOL promoted = ((BOOL (*)(id, SEL))objc_msgSend)(obj, promotedSEL);
        LogLine(@"PROMOTED_OBJECT prefix=%@ class=%@ value=%d", prefix, clsName, promoted);
    }

    for (Class cls = [obj class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            Ivar ivar = ivars[i];
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') continue;
            NSString *ivarName = [NSString stringWithUTF8String:ivar_getName(ivar) ?: "?"];
            NSString *lower = ivarName.lowercaseString;
            BOOL interesting = [lower containsString:@"status"] || [lower containsString:@"tweet"] ||
                               [lower containsString:@"item"] || [lower containsString:@"content"] ||
                               [lower containsString:@"promot"] || [lower containsString:@"ad"];
            if (!interesting) continue;
            id child = nil;
            @try { child = object_getIvar(obj, ivar); } @catch (__unused NSException *e) { child = nil; }
            if (!child) continue;
            LogLine(@"IVAR prefix=%@ owner=%@ name=%@ childClass=%@", prefix, clsName, ivarName, NSStringFromClass([child class]));
            if (depth < 1) ProbeObject(child, [prefix stringByAppendingFormat:@".%@", ivarName], depth + 1);
        }
        free(ivars);
    }
}

static void ProbeSections(id controller, NSArray *sections, NSString *source) {
    if (![sections isKindOfClass:NSArray.class]) return;
    NSString *controllerName = NSStringFromClass([controller class]);
    LogLine(@"SECTIONS source=%@ controller=%@ sectionCount=%lu hide_promoted=%d", source, controllerName,
            (unsigned long)sections.count, [[NSUserDefaults standardUserDefaults] boolForKey:@"hide_promoted"]);
    NSUInteger s = 0;
    for (id section in sections) {
        if (![section isKindOfClass:NSArray.class]) { s++; continue; }
        NSUInteger i = 0;
        for (id item in (NSArray *)section) {
            LogLine(@"ITEM source=%@ controller=%@ s=%lu i=%lu class=%@", source, controllerName,
                    (unsigned long)s, (unsigned long)i, NSStringFromClass([item class]));
            ProbeObject(item, [NSString stringWithFormat:@"s%lu.i%lu", (unsigned long)s, (unsigned long)i], 0);
            i++;
        }
        s++;
    }
}

static void ReplacementSetSections(id self, SEL _cmd, NSArray *sections, BOOL restore) {
    ProbeSections(self, sections, @"setSections");
    ((void (*)(id, SEL, NSArray *, BOOL))gOrigSetSections)(self, _cmd, sections, restore);
}

static void ReplacementUpdateSections(id self, SEL _cmd, NSArray *sections, NSArray *identifiers, long long animation, id completion) {
    ProbeSections(self, sections, @"updateSections");
    ((void (*)(id, SEL, NSArray *, NSArray *, long long, id))gOrigUpdateSections)(self, _cmd, sections, identifiers, animation, completion);
}

static void ReplacementViewDidAppear(id self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))gOrigViewDidAppear)(self, _cmd, animated);
    NSString *name = NSStringFromClass([self class]);
    if (LooksRelevantControllerName(name)) LogLine(@"VC_APPEAR class=%@", name);
}

static void InstallHooks(void) {
    if (!gItemsHooked) {
        Class cls = objc_getClass("TFNItemsDataViewController");
        if (cls) {
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
            gItemsHooked = (gOrigSetSections || gOrigUpdateSections);
        }
    }

    if (!gVCGuardHooked) {
        Class vc = [UIViewController class];
        Method m = class_getInstanceMethod(vc, @selector(viewDidAppear:));
        if (m) {
            gOrigViewDidAppear = method_getImplementation(m);
            method_setImplementation(m, (IMP)ReplacementViewDidAppear);
            gVCGuardHooked = YES;
        }
    }

    LogLine(@"HOOK_RESULT version=%@ items=%d vc=%d", kProbeVersion, gItemsHooked, gVCGuardHooked);
}

__attribute__((constructor)) static void NFBAdBlock1238ThreadProbeInit(void) {
    [[NSFileManager defaultManager] removeItemAtPath:LogPath() error:nil];
    LogLine(@"NEW_SESSION version=%@ target=X_12.38 purpose=opened-post-thread-ad-map", kProbeVersion);
    for (NSNumber *delay in @[@0.0, @0.25, @0.75, @1.5, @3.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            InstallHooks();
        });
    }
}
