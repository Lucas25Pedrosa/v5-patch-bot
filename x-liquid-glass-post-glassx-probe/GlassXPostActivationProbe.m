#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *const kVersion = @"2.0";
static NSString *const kLogName = @"GlassXFeatureConsumptionProbe.log";

static NSMutableDictionary<NSString *, NSValue *> *gOriginals;
static NSMutableDictionary<NSString *, NSNumber *> *gCallCounts;
static dispatch_queue_t gStateQueue;

static NSString *LogPath(void) {
    NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!d.length) d = NSTemporaryDirectory();
    return [d stringByAppendingPathComponent:kLogName];
}

static void PLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void PLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", NSDate.date, body ?: @""];
    @synchronized(NSFileManager.defaultManager) {
        NSString *p = LogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:p]) {
            [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
    }
    NSLog(@"[GlassXFeatureConsumptionProbe] %@", body ?: @"");
}

static NSString *AddrInfo(const void *p) {
    if (!p) return @"nil";
    Dl_info d = {0};
    if (dladdr(p, &d) && d.dli_fbase) {
        NSString *image = d.dli_fname ? [[NSString stringWithUTF8String:d.dli_fname] lastPathComponent] : @"?";
        uintptr_t offset = (uintptr_t)p - (uintptr_t)d.dli_fbase;
        return [NSString stringWithFormat:@"%@+0x%llx", image, (unsigned long long)offset];
    }
    return [NSString stringWithFormat:@"%p", p];
}

static NSArray<NSString *> *NoArgSelectors(void) {
    return @[
        @"isRedesignEnabled",
        @"isPushChromeSnapEnabled",
        @"liquidGlassConvoHeaderEnabled",
        @"isLiquidGlassConvoHeaderEnabled",
        @"liquidGlassRedesignEnabled",
        @"isLiquidGlassRedesignEnabled",
        @"declaresGlassComposer"
    ];
}

static NSArray<NSString *> *OneArgSelectors(void) {
    return @[
        @"isAvatarBadgeEnabledWithFeatureSwitches:",
        @"isQuickComposerEnabledWithFeatureSwitches:",
        @"isQuickComposerEnabledNoImpressionWithFeatureSwitches:"
    ];
}

static NSArray<NSString *> *KnownFlags(void) {
    return @[
        @"ios_liquid_glass_redesign_enabled",
        @"ios_liquid_glass_redesign_quick_composer_enabled",
        @"ios_liquid_glass_avatar_badge_enabled",
        @"ios_liquid_glass_push_chrome_snap_enabled",
        @"xchat_liquid_glass_convo_header_enabled",
        @"T1LiquidGlassRedesignPersistedGate"
    ];
}

static NSString *KeyForClass(Class owner, SEL sel, BOOL classMethod) {
    return [NSString stringWithFormat:@"%@|%@|%@",
            classMethod ? @"C" : @"I",
            owner ? NSStringFromClass(owner) : @"?",
            sel ? NSStringFromSelector(sel) : @"?"];
}

static IMP OriginalForReceiver(id self, SEL sel, BOOL classMethod, NSString **resolvedOwner) {
    Class cls = classMethod ? (Class)self : [self class];
    __block IMP result = NULL;
    __block NSString *ownerName = nil;

    while (cls && !result) {
        NSString *key = KeyForClass(cls, sel, classMethod);
        dispatch_sync(gStateQueue, ^{
            NSValue *v = gOriginals[key];
            if (v) result = [v pointerValue];
        });
        if (result) ownerName = NSStringFromClass(cls);
        cls = class_getSuperclass(cls);
    }

    if (resolvedOwner) *resolvedOwner = ownerName ?: @"<unresolved>";
    return result;
}

static NSUInteger IncrementCallCount(id self, SEL sel, BOOL classMethod) {
    Class cls = classMethod ? (Class)self : [self class];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@",
                     classMethod ? @"C" : @"I",
                     cls ? NSStringFromClass(cls) : @"?",
                     NSStringFromSelector(sel)];
    __block NSUInteger count = 0;
    dispatch_sync(gStateQueue, ^{
        count = [gCallCounts[key] unsignedIntegerValue] + 1;
        gCallCounts[key] = @(count);
    });
    return count;
}

static BOOL ProbeHook0(id self, SEL _cmd) {
    BOOL classMethod = object_isClass(self);
    NSString *owner = nil;
    IMP orig = OriginalForReceiver(self, _cmd, classMethod, &owner);
    BOOL value = orig ? ((BOOL(*)(id,SEL))orig)(self, _cmd) : NO;
    NSUInteger call = IncrementCallCount(self, _cmd, classMethod);
    void *caller = __builtin_extract_return_addr(__builtin_return_address(0));
    PLog(@"CONSUMED selector=%@ kind=%@ runtimeClass=%@ owner=%@ call=%lu value=%d caller=%@",
         NSStringFromSelector(_cmd),
         classMethod ? @"class" : @"instance",
         classMethod ? NSStringFromClass((Class)self) : NSStringFromClass([self class]),
         owner,
         (unsigned long)call,
         value ? 1 : 0,
         AddrInfo(caller));
    return value;
}

static BOOL ProbeHook1(id self, SEL _cmd, id featureSwitches) {
    BOOL classMethod = object_isClass(self);
    NSString *owner = nil;
    IMP orig = OriginalForReceiver(self, _cmd, classMethod, &owner);
    BOOL value = orig ? ((BOOL(*)(id,SEL,id))orig)(self, _cmd, featureSwitches) : NO;
    NSUInteger call = IncrementCallCount(self, _cmd, classMethod);
    void *caller = __builtin_extract_return_addr(__builtin_return_address(0));
    PLog(@"CONSUMED selector=%@ kind=%@ runtimeClass=%@ owner=%@ call=%lu value=%d argClass=%@ caller=%@",
         NSStringFromSelector(_cmd),
         classMethod ? @"class" : @"instance",
         classMethod ? NSStringFromClass((Class)self) : NSStringFromClass([self class]),
         owner,
         (unsigned long)call,
         value ? 1 : 0,
         featureSwitches ? NSStringFromClass([featureSwitches class]) : @"nil",
         AddrInfo(caller));
    return value;
}

static BOOL MethodReturnsBool(Method method) {
    if (!method) return NO;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return returnType[0] == 'B' || returnType[0] == 'c' || returnType[0] == 'C';
}

static NSUInteger HookDeclaredMethods(Class target, Class ownerClass, BOOL classMethods) {
    if (!target || !ownerClass) return 0;
    unsigned count = 0;
    Method *methods = class_copyMethodList(target, &count);
    if (!methods) return 0;

    NSUInteger hooked = 0;
    for (unsigned i = 0; i < count; i++) {
        Method m = methods[i];
        SEL sel = method_getName(m);
        NSString *name = NSStringFromSelector(sel);
        if (!MethodReturnsBool(m)) continue;

        IMP replacement = NULL;
        if ([NoArgSelectors() containsObject:name] && method_getNumberOfArguments(m) == 2) {
            replacement = (IMP)ProbeHook0;
        } else if ([OneArgSelectors() containsObject:name] && method_getNumberOfArguments(m) == 3) {
            replacement = (IMP)ProbeHook1;
        } else {
            continue;
        }

        IMP current = method_getImplementation(m);
        if (current == replacement) continue;

        NSString *key = KeyForClass(ownerClass, sel, classMethods);
        dispatch_sync(gStateQueue, ^{
            gOriginals[key] = [NSValue valueWithPointer:current];
        });

        class_replaceMethod(target, sel, replacement, method_getTypeEncoding(m));
        if (class_getMethodImplementation(target, sel) == replacement) {
            hooked++;
            PLog(@"HOOK selector=%@ kind=%@ owner=%@ original=%@",
                 name,
                 classMethods ? @"class" : @"instance",
                 NSStringFromClass(ownerClass),
                 AddrInfo((const void *)current));
        }
    }

    free(methods);
    return hooked;
}

static NSUInteger InstallConsumptionHooks(NSString *reason) {
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return 0;

    __unsafe_unretained Class *classes = (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
    if (!classes) return 0;
    classCount = objc_getClassList(classes, classCount);

    NSUInteger hooked = 0;
    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        if (!cls) continue;
        hooked += HookDeclaredMethods(cls, cls, NO);
        Class meta = object_getClass(cls);
        if (meta) hooked += HookDeclaredMethods(meta, cls, YES);
    }
    free(classes);

    PLog(@"HOOK_PASS reason=%@ hooked=%lu", reason, (unsigned long)hooked);
    return hooked;
}

static NSString *GlassXCompanion(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i);
        if (!p) continue;
        NSString *name = [[NSString stringWithUTF8String:p] lastPathComponent];
        if ([name isEqualToString:@"GlassX.dylib"] || [name isEqualToString:@"GlassXDE.dylib"]) return name;
    }
    return @"<not-loaded>";
}

static void Snapshot(NSString *reason) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *app = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
    PLog(@"SNAPSHOT_BEGIN reason=%@ app=%@ build=%@ companion=%@", reason, app, build, GlassXCompanion());
    for (NSString *key in KnownFlags()) {
        id v = [d objectForKey:key];
        PLog(@"FLAG key=%@ value=%@ bool=%d", key, v ?: @"<nil>", [d boolForKey:key] ? 1 : 0);
    }
    NSDictionary *all = [d dictionaryRepresentation];
    for (NSString *key in [[all allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *lower = key.lowercaseString;
        if (([lower containsString:@"liquid_glass"] || [lower containsString:@"liquidglass"]) && ![KnownFlags() containsObject:key]) {
            PLog(@"DISCOVERED_FLAG key=%@ value=%@", key, all[key]);
        }
    }
    PLog(@"SNAPSHOT_END reason=%@", reason);
}

__attribute__((constructor)) static void Init(void) {
    @autoreleasepool {
        gOriginals = [NSMutableDictionary dictionary];
        gCallCounts = [NSMutableDictionary dictionary];
        gStateQueue = dispatch_queue_create("com.lucas.glassx.feature-consumption-probe.state", DISPATCH_QUEUE_SERIAL);

        PLog(@"NEW_SESSION version=%@ mode=FEATURE_CONSUMPTION readOnly=1 expectedCompanion=GlassX-3.1", kVersion);
        NSArray<NSNumber *> *delays = @[@0.10,@0.30,@0.70,@1.20,@2.0,@3.5,@5.0,@6.0,@8.0,@12.0,@20.0,@30.0,@60.0,@120.0];
        for (NSNumber *delay in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSString *reason = [NSString stringWithFormat:@"auto-%.2fs", delay.doubleValue];
                InstallConsumptionHooks(reason);
                if (delay.doubleValue == 0.70 || delay.doubleValue == 5.0 || delay.doubleValue == 12.0 || delay.doubleValue == 30.0 || delay.doubleValue == 60.0 || delay.doubleValue == 120.0) {
                    Snapshot(reason);
                }
            });
        }
    }
}
