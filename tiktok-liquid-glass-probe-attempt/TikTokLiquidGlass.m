#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

static NSString *const kLogName = @"TikTokLiquidGlassProbe.log";
static const NSUInteger kMaxLogBytes = 4 * 1024 * 1024;

static NSMutableDictionary<NSString *, NSValue *> *gOriginals;
static NSMutableSet<NSString *> *gHooked;
static NSMutableSet<NSString *> *gLoggedCalls;
static NSMutableSet<NSString *> *gDiscovered;

static NSString *LogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kLogName];
}

static NSString *Stamp(void) {
    static NSDateFormatter *f;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        f = [NSDateFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [f stringFromDate:NSDate.date];
}

static void TrimLog(void) {
    NSString *path = LogPath();
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size <= kMaxLogBytes) return;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length <= kMaxLogBytes) return;
    NSUInteger keep = kMaxLogBytes / 2;
    [[data subdataWithRange:NSMakeRange(data.length - keep, keep)] writeToFile:path atomically:YES];
}

static void TLGLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void TLGLog(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", Stamp(), body ?: @""];
    NSLog(@"[TikTokLiquidGlass] %@", body ?: @"");

    @synchronized([NSFileManager defaultManager]) {
        NSString *path = LogPath();
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
        TrimLog();
    }
}

static NSString *MethodKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%p|%@", cls, NSStringFromSelector(sel)];
}

static const char *SkipQualifiers(const char *t) {
    if (!t) return NULL;
    while (*t == 'r' || *t == 'n' || *t == 'N' || *t == 'o' ||
           *t == 'O' || *t == 'R' || *t == 'V') t++;
    return t;
}

static BOOL IsZeroArgBool(Method m) {
    if (!m || method_getNumberOfArguments(m) != 2) return NO;
    char *ret = method_copyReturnType(m);
    const char *t = SkipQualifiers(ret);
    BOOL ok = t && (t[0] == 'B' || t[0] == 'c');
    if (ret) free(ret);
    return ok;
}

static NSSet<NSString *> *ForceYESNames(void) {
    static NSSet<NSString *> *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [NSSet setWithArray:@[
            @"supportLiquidGlass",
            @"isLiquidGlassEnabled",
            @"liquidGlassEnabled",
            @"isLiquidGlassButtonEnabled",
            @"isLiquidGlassMenuEnabled",
            @"isLiquidGlassIntroPanelEnabled",
            @"isLiquidGlassToastEnabled",
            @"isLiquidGlassCenterToastEnabled",
            @"isLiquidGlassBottomToastEnabled",
            @"isLiquidGlassFloatingNoticeEnabled",
            @"isLiquidGlassInAppPushEnabled",
            @"isLiquidGlassModalEnabled",
            @"isLiquidGlassPopoverEnabled",
            @"isLiquidGlassSheetEnabled",
            @"isLiquidGlassDialogEnabled",
            @"isLiquidGlassStyleEnabled",
            @"isTabBarIOS26LiquidGlassFixEnabled",
            @"feedStandardButtonEnableLiquidGlass",
            @"innerPushLiquidGlassEnable",
            @"innerPushLiquidGlassInteractiveEnable",
            @"storyFixViewerListRelationButtonLiquidGlass",
            @"enableBigCardLiquidGlass",
            @"studioTextEditorAdaptLiquidGlass",
            @"studioMusicDetailBottomButtonLiquidGlass",
            @"ecPdpStoreV2EnableLiquidGlass",
            @"ugFeedCardLiquidGlassEnable",
            @"p_isBigCardLiquidGlassEnabled",
            @"p_shouldEnableStyle4OfficialLiquidGlass"
        ]];
    });
    return s;
}

static NSSet<NSString *> *ForceNONames(void) {
    static NSSet<NSString *> *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [NSSet setWithArray:@[@"disableLiquidGlass"]];
    });
    return s;
}

static BOOL SelectorLooksGlass(NSString *name) {
    if (!name.length) return NO;
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"liquidglass"] ||
           [lower containsString:@"liquid_glass"] ||
           [name isEqualToString:@"supportLiquidGlass"];
}

static BOOL ClassLooksSwitch(Class cls) {
    if (!cls) return NO;
    NSString *lower = NSStringFromClass(cls).lowercaseString;
    return [lower containsString:@"liquidglassswitch"] ||
           [lower containsString:@"liquid_glass_switch"];
}

static BOOL GenericSwitchGetter(NSString *name) {
    static NSSet<NSString *> *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [NSSet setWithArray:@[
            @"isEnabled", @"enabled", @"isOn", @"isOpen",
            @"isAvailable", @"available", @"isSupported", @"supported"
        ]];
    });
    return [s containsObject:name];
}

static BOOL OriginalBool(id self, SEL sel, BOOL *found) {
    if (found) *found = NO;
    Class c = object_getClass(self);
    while (c) {
        NSValue *v = nil;
        @synchronized(gOriginals) {
            v = gOriginals[MethodKey(c, sel)];
        }
        if (v) {
            IMP imp = [v pointerValue];
            if (imp) {
                if (found) *found = YES;
                return ((BOOL(*)(id,SEL))imp)(self, sel);
            }
        }
        c = class_getSuperclass(c);
    }
    return NO;
}

static BOOL ForcedValue(id self, SEL sel, BOOL forced) {
    Class runtimeClass = object_getClass(self);
    NSString *callKey = [NSString stringWithFormat:@"%p|%@", runtimeClass, NSStringFromSelector(sel)];

    BOOL first = NO;
    @synchronized(gLoggedCalls) {
        if (![gLoggedCalls containsObject:callKey]) {
            [gLoggedCalls addObject:callKey];
            first = YES;
        }
    }

    if (first) {
        BOOL found = NO;
        BOOL original = OriginalBool(self, sel, &found);
        TLGLog(@"CALL class=%@ selector=%@ original=%@ forced=%@ originalFound=%@ receiverKind=%@",
               NSStringFromClass(runtimeClass),
               NSStringFromSelector(sel),
               found ? (original ? @"YES" : @"NO") : @"?",
               forced ? @"YES" : @"NO",
               found ? @"YES" : @"NO",
               object_isClass(self) ? @"class" : @"instance");
    }

    return forced;
}

static BOOL ForceYES(id self, SEL sel) { return ForcedValue(self, sel, YES); }
static BOOL ForceNO(id self, SEL sel) { return ForcedValue(self, sel, NO); }

static void InspectMethodList(Class owner, BOOL classMethod, NSString *reason) {
    Class methodOwner = classMethod ? object_getClass(owner) : owner;
    if (!methodOwner) return;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(methodOwner, &count);

    for (unsigned int i = 0; i < count; i++) {
        Method m = methods[i];
        SEL sel = method_getName(m);
        NSString *name = NSStringFromSelector(sel);
        BOOL ownerIsSwitch = ClassLooksSwitch(owner);

        if (!SelectorLooksGlass(name) && !ownerIsSwitch) continue;

        BOOL boolGetter = IsZeroArgBool(m);
        BOOL forceYES = [ForceYESNames() containsObject:name] ||
                        (ownerIsSwitch && GenericSwitchGetter(name));
        BOOL forceNO = [ForceNONames() containsObject:name];
        BOOL forceCandidate = forceYES || forceNO;

        NSString *discoveryKey = [NSString stringWithFormat:@"%p|%d|%@", methodOwner, classMethod, name];
        BOOL first = NO;
        @synchronized(gDiscovered) {
            if (![gDiscovered containsObject:discoveryKey]) {
                [gDiscovered addObject:discoveryKey];
                first = YES;
            }
        }

        if (first) {
            TLGLog(@"FOUND_METHOD reason=%@ owner=%@ scope=%@ selector=%@ types=%s boolGetter=%@ forceCandidate=%@",
                   reason ?: @"-",
                   NSStringFromClass(owner),
                   classMethod ? @"class" : @"instance",
                   name,
                   method_getTypeEncoding(m) ?: "-",
                   boolGetter ? @"YES" : @"NO",
                   forceCandidate ? @"YES" : @"NO");
        }

        if (!boolGetter || !forceCandidate) continue;

        IMP replacement = forceNO ? (IMP)ForceNO : (IMP)ForceYES;
        NSString *key = MethodKey(methodOwner, sel);

        @synchronized(gHooked) {
            if ([gHooked containsObject:key]) continue;
        }

        IMP current = method_getImplementation(m);
        if (!current || current == replacement) continue;

        @synchronized(gOriginals) {
            if (!gOriginals[key]) gOriginals[key] = [NSValue valueWithPointer:current];
        }

        method_setImplementation(m, replacement);

        @synchronized(gHooked) {
            [gHooked addObject:key];
        }

        TLGLog(@"HOOKED owner=%@ scope=%@ selector=%@ originalIMP=%p replacementIMP=%p",
               NSStringFromClass(owner),
               classMethod ? @"class" : @"instance",
               name,
               current,
               replacement);
    }

    free(methods);
}

static void ScanRuntime(NSString *reason) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);

    NSUInteger glassClasses = 0;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!cls) continue;

        NSString *className = NSStringFromClass(cls);
        NSString *lower = className.lowercaseString;
        if ([lower containsString:@"liquidglass"] || [lower containsString:@"liquid_glass"]) {
            glassClasses++;
            NSString *key = [@"CLASS|" stringByAppendingString:className];
            BOOL first = NO;
            @synchronized(gDiscovered) {
                if (![gDiscovered containsObject:key]) {
                    [gDiscovered addObject:key];
                    first = YES;
                }
            }
            if (first) TLGLog(@"FOUND_CLASS reason=%@ class=%@", reason ?: @"-", className);
        }

        InspectMethodList(cls, NO, reason);
        InspectMethodList(cls, YES, reason);
    }

    free(classes);
    TLGLog(@"SCAN_DONE reason=%@ classes=%d glassClasses=%lu hooked=%lu",
           reason ?: @"-",
           count,
           (unsigned long)glassClasses,
           (unsigned long)gHooked.count);
}

static void CollectViews(UIView *view, NSUInteger depth, NSMutableArray<NSString *> *hits, NSUInteger *visited) {
    if (!view || depth > 40 || hits.count >= 160) return;
    if (visited) (*visited)++;

    NSString *name = NSStringFromClass(view.class);
    NSString *lower = name.lowercaseString;
    if ([lower containsString:@"glass"] ||
        [lower containsString:@"visualeffect"] ||
        [lower containsString:@"tabbar"]) {
        [hits addObject:[NSString stringWithFormat:@"%@ frame=%@ hidden=%@ alpha=%.2f",
                         name,
                         NSStringFromCGRect(view.frame),
                         view.hidden ? @"YES" : @"NO",
                         view.alpha]];
    }

    for (UIView *child in view.subviews) {
        CollectViews(child, depth + 1, hits, visited);
        if (hits.count >= 160) break;
    }
}

static void SnapshotUI(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<UIWindow *> *windows = UIApplication.sharedApplication.windows ?: @[];
        NSMutableArray<NSString *> *hits = [NSMutableArray array];
        NSUInteger visited = 0;

        for (UIWindow *window in windows) {
            CollectViews(window, 0, hits, &visited);
            if (hits.count >= 160) break;
        }

        TLGLog(@"UI_SNAPSHOT reason=%@ windows=%lu visited=%lu hits=%lu",
               reason ?: @"-",
               (unsigned long)windows.count,
               (unsigned long)visited,
               (unsigned long)hits.count);

        for (NSString *hit in hits) TLGLog(@"UI_HIT %@", hit);
    });
}

static void LogContext(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSDictionary *info = bundle.infoDictionary ?: @{};

    TLGLog(@"========== TikTokLiquidGlass 0.1 Probe+Attempt loaded ==========");
    TLGLog(@"logPath=%@", LogPath());
    TLGLog(@"bundle=%@ version=%@ build=%@ executable=%@",
           bundle.bundleIdentifier ?: @"-",
           info[@"CFBundleShortVersionString"] ?: @"-",
           info[@"CFBundleVersion"] ?: @"-",
           info[@"CFBundleExecutable"] ?: @"-");
    TLGLog(@"system=%@ UIDesignRequiresCompatibility=%@ DTSDKName=%@ DTPlatformVersion=%@",
           UIDevice.currentDevice.systemVersion ?: @"-",
           info[@"UIDesignRequiresCompatibility"] ?: @"<missing>",
           info[@"DTSDKName"] ?: @"-",
           info[@"DTPlatformVersion"] ?: @"-");

    for (NSString *name in @[
        @"TUXSwiftBase.TUXExperiments",
        @"_TtC12TUXSwiftBase14TUXExperiments",
        @"TUXSwiftBase.TUXAppInfoUtils",
        @"_TtC12TUXSwiftBase15TUXAppInfoUtils",
        @"TTKIOS26LiquidGlassSwitch",
        @"IOS26LiquidGlassSwitchBridge",
        @"TikTokTabBarBasic.TabBarController"
    ]) {
        Class cls = NSClassFromString(name);
        TLGLog(@"KNOWN_CLASS name=%@ resolved=%@ runtime=%@",
               name,
               cls ? @"YES" : @"NO",
               cls ? NSStringFromClass(cls) : @"-");
    }
}

__attribute__((constructor))
static void TikTokLiquidGlassInit(void) {
    @autoreleasepool {
        gOriginals = [NSMutableDictionary dictionary];
        gHooked = [NSMutableSet set];
        gLoggedCalls = [NSMutableSet set];
        gDiscovered = [NSMutableSet set];

        LogContext();
        ScanRuntime(@"constructor");

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
                        TLGLog(@"EVENT UIApplicationDidFinishLaunchingNotification");
                        ScanRuntime(@"didFinishLaunching");
                        SnapshotUI(@"didFinishLaunching");
                    }];

        for (NSNumber *n in @[@1.0, @3.0, @8.0]) {
            NSTimeInterval delay = n.doubleValue;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                NSString *reason = [NSString stringWithFormat:@"delay-%.0fs", delay];
                ScanRuntime(reason);
                SnapshotUI(reason);
            });
        }
    }
}
