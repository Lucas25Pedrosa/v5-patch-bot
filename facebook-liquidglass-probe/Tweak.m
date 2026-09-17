#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *gReportPath;
static dispatch_queue_t gLogQueue;
static NSMutableSet<NSString *> *gSeenLines;
static NSMutableSet<NSString *> *gHookedMethods;
static dispatch_source_t gUITimer;
static NSInteger gUIScanCount = 0;

static NSString *Stamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    @synchronized (formatter) {
        return [formatter stringFromDate:[NSDate date]];
    }
}

static void AppendLine(NSString *line) {
    if (!line.length || !gReportPath.length) return;
    NSString *key = line;
    @synchronized (gSeenLines) {
        if ([gSeenLines containsObject:key]) return;
        [gSeenLines addObject:key];
    }
    dispatch_async(gLogQueue, ^{
        NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:gReportPath];
        if (!handle) {
            [data writeToFile:gReportPath atomically:YES];
            return;
        }
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
        } @catch (__unused NSException *e) {
        }
        [handle closeFile];
    });
}

static BOOL ContainsInsensitive(NSString *value, NSString *needle) {
    if (!value.length || !needle.length) return NO;
    return [value rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL IsInterestingClassName(NSString *name) {
    if (!name.length) return NO;
    return ContainsInsensitive(name, @"LiquidGlass") ||
           ContainsInsensitive(name, @"TabBar") ||
           ContainsInsensitive(name, @"Appearance") ||
           ContainsInsensitive(name, @"Configuration") ||
           [name hasPrefix:@"FB"] ||
           [name hasPrefix:@"BK"] ||
           [name hasPrefix:@"META"] ||
           [name hasPrefix:@"Meta"];
}

static BOOL IsInterestingSelectorName(NSString *name) {
    if (!name.length) return NO;
    NSString *lower = name.lowercaseString;
    if ([lower containsString:@"liquidglass"] ||
        ([lower containsString:@"liquid"] && [lower containsString:@"glass"]) ||
        [lower containsString:@"scrollabletabbar"] ||
        [lower containsString:@"floatingtabbar"] ||
        [lower containsString:@"tabbarconfiguration"] ||
        [lower isEqualToString:@"shouldenablescrollabletabbar"] ||
        [lower containsString:@"tabbarisvisible"] ||
        [lower containsString:@"followtabbarscrollaway"]) {
        return YES;
    }
    return NO;
}

static NSString *MethodEncoding(Method method) {
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding ? [NSString stringWithUTF8String:encoding] : @"?";
}

static BOOL MethodReturnsBoolWithNoExplicitArgs(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char *ret = method_copyReturnType(method);
    BOOL safe = ret && (ret[0] == 'B' || ret[0] == 'c' || ret[0] == 'C');
    if (ret) free(ret);
    return safe;
}

static void InstallTransparentBoolHook(Class targetClass, Method method, BOOL isClassMethod) {
    if (!targetClass || !method) return;

    SEL selector = method_getName(method);
    NSString *className = NSStringFromClass(targetClass) ?: @"?";
    NSString *selectorName = NSStringFromSelector(selector) ?: @"?";
    NSString *hookKey = [NSString stringWithFormat:@"%@|%@|%d", className, selectorName, isClassMethod];

    @synchronized (gHookedMethods) {
        if ([gHookedMethods containsObject:hookKey]) return;
        [gHookedMethods addObject:hookKey];
    }

    IMP original = method_getImplementation(method);
    if (!original) return;

    BOOL (^replacementBlock)(id) = ^BOOL(id obj) {
        BOOL value = ((BOOL (*)(id, SEL))original)(obj, selector);
        AppendLine([NSString stringWithFormat:@"%@ RUNTIME_BOOL %@[%@ %@] => %@",
                    Stamp(), isClassMethod ? @"+" : @"-", className, selectorName,
                    value ? @"true" : @"false"]);
        return value;
    };

    IMP replacement = imp_implementationWithBlock(replacementBlock);
    if (!replacement) return;
    method_setImplementation(method, replacement);

    AppendLine([NSString stringWithFormat:@"%@ HOOK_INSTALLED %@[%@ %@] encoding=%@ (transparent; return value unchanged)",
                Stamp(), isClassMethod ? @"+" : @"-", className, selectorName, MethodEncoding(method)]);
}

static void InspectMethodList(Class ownerClass, Class methodContainer, BOOL isClassMethod) {
    if (!ownerClass || !methodContainer) return;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(methodContainer, &count);
    if (!methods) return;

    NSString *className = NSStringFromClass(ownerClass) ?: @"?";
    for (unsigned int i = 0; i < count; i++) {
        Method method = methods[i];
        SEL selector = method_getName(method);
        NSString *selectorName = NSStringFromSelector(selector) ?: @"?";
        if (!IsInterestingSelectorName(selectorName)) continue;

        AppendLine([NSString stringWithFormat:@"%@ METHOD %@[%@ %@] encoding=%@",
                    Stamp(), isClassMethod ? @"+" : @"-", className, selectorName, MethodEncoding(method)]);

        if (MethodReturnsBoolWithNoExplicitArgs(method)) {
            InstallTransparentBoolHook(ownerClass, method, isClassMethod);
        }
    }
    free(methods);
}

static void InspectObjectiveCRuntime(void) {
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) {
        AppendLine([NSString stringWithFormat:@"%@ RUNTIME no Objective-C classes returned", Stamp()]);
        return;
    }

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
    if (!classes) return;
    classCount = objc_getClassList(classes, classCount);

    NSInteger interestingClasses = 0;
    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        if (!cls) continue;
        NSString *className = NSStringFromClass(cls);
        if (!IsInterestingClassName(className)) continue;

        BOOL strongMatch = ContainsInsensitive(className, @"LiquidGlass") ||
                           ContainsInsensitive(className, @"TabBarConfiguration") ||
                           [className isEqualToString:@"FBLiquidGlassAppJob"] ||
                           [className isEqualToString:@"FBTabBarConfigurationBuilder"] ||
                           [className isEqualToString:@"FBTabBarOptions"] ||
                           [className isEqualToString:@"FBTabBarOverwriteOptions"];

        if (strongMatch) {
            interestingClasses++;
            AppendLine([NSString stringWithFormat:@"%@ CLASS %@ superclass=%@",
                        Stamp(), className ?: @"?", NSStringFromClass(class_getSuperclass(cls)) ?: @"<none>"]);
        }

        InspectMethodList(cls, cls, NO);
        Class meta = object_getClass(cls);
        if (meta) InspectMethodList(cls, meta, YES);
    }

    free(classes);
    AppendLine([NSString stringWithFormat:@"%@ RUNTIME_SCAN complete classCount=%d strongMatches=%ld",
                Stamp(), classCount, (long)interestingClasses]);
}

static void InspectKnownSymbols(void) {
    NSArray<NSString *> *symbols = @[
        @"_METAOverrideLiquidGlassSetEnabled",
        @"_METAResetLiquidGlassOverride",
        @"_fbios_liquid_glass_sessionless"
    ];
    for (NSString *name in symbols) {
        void *address = dlsym(RTLD_DEFAULT, name.UTF8String);
        AppendLine([NSString stringWithFormat:@"%@ SYMBOL %@ => %@",
                    Stamp(), name, address ? [NSString stringWithFormat:@"%p", address] : @"<not-exported>"]);
    }
    AppendLine([NSString stringWithFormat:@"%@ STRING_GATE bk.action.bloks.IsLiquidGlassEnabled observed in Facebook 579 executable (static probe)", Stamp()]);
}

static NSArray<UIWindow *> *AllWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateUnattached) continue;
            [windows addObjectsFromArray:windowScene.windows];
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [windows addObjectsFromArray:UIApplication.sharedApplication.windows];
#pragma clang diagnostic pop
    }
    return windows;
}

static NSString *SubviewClassSummary(UIView *view) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (UIView *child in view.subviews) {
        NSString *name = NSStringFromClass(child.class) ?: @"?";
        if (![names containsObject:name]) [names addObject:name];
        if (names.count >= 16) break;
    }
    return [names componentsJoinedByString:@", "];
}

static void InspectVisibleView(UIView *view, NSUInteger depth) {
    if (!view || depth > 45 || view.hidden || view.alpha <= 0.01) return;

    NSString *className = NSStringFromClass(view.class) ?: @"?";
    NSString *lower = className.lowercaseString;
    BOOL interesting = [view isKindOfClass:UITabBar.class] ||
                       [lower containsString:@"tabbar"] ||
                       [lower containsString:@"liquidglass"] ||
                       ([lower containsString:@"glass"] && [lower containsString:@"view"]);

    if (interesting && view.window) {
        NSString *superName = view.superview ? NSStringFromClass(view.superview.class) : @"<none>";
        AppendLine([NSString stringWithFormat:@"%@ VISIBLE_UI class=%@ super=%@ frame=(%.1f,%.1f %.1fx%.1f) alpha=%.2f children=[%@]",
                    Stamp(), className, superName ?: @"?",
                    view.frame.origin.x, view.frame.origin.y, view.frame.size.width, view.frame.size.height,
                    view.alpha, SubviewClassSummary(view)]);
    }

    for (UIView *child in view.subviews) {
        InspectVisibleView(child, depth + 1);
    }
}

static void InspectViewControllers(UIViewController *controller, NSUInteger depth) {
    if (!controller || depth > 20) return;
    NSString *name = NSStringFromClass(controller.class) ?: @"?";
    NSString *lower = name.lowercaseString;
    if ([controller isKindOfClass:UITabBarController.class] || [lower containsString:@"tabbar"]) {
        NSString *selected = @"<none>";
        if ([controller isKindOfClass:UITabBarController.class]) {
            UIViewController *selectedVC = ((UITabBarController *)controller).selectedViewController;
            if (selectedVC) selected = NSStringFromClass(selectedVC.class) ?: @"?";
        }
        AppendLine([NSString stringWithFormat:@"%@ CONTROLLER class=%@ selected=%@", Stamp(), name, selected]);
    }

    if (controller.presentedViewController) InspectViewControllers(controller.presentedViewController, depth + 1);
    for (UIViewController *child in controller.childViewControllers) InspectViewControllers(child, depth + 1);
}

static void ScanVisibleUI(void) {
    gUIScanCount++;
    for (UIWindow *window in AllWindows()) {
        InspectVisibleView(window, 0);
        InspectViewControllers(window.rootViewController, 0);
    }

    if (gUIScanCount >= 15 && gUITimer) {
        dispatch_source_cancel(gUITimer);
        gUITimer = nil;
        AppendLine([NSString stringWithFormat:@"%@ UI_SCAN stopped after %ld passes", Stamp(), (long)gUIScanCount]);
    }
}

static void PrepareReport(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    gReportPath = [docs stringByAppendingPathComponent:@"NexusLiquidGlassProbe.txt"];
    [[NSFileManager defaultManager] createFileAtPath:gReportPath contents:nil attributes:nil];

    AppendLine(@"Nexus Liquid Glass Probe 0.1");
    AppendLine(@"Diagnostic only: no feature flags, UI state, tab bar configuration, or Liquid Glass values are modified.");
    AppendLine([NSString stringWithFormat:@"%@ START bundle=%@ appVersion=%@ build=%@ iOS=%@ device=%@",
                Stamp(),
                NSBundle.mainBundle.bundleIdentifier ?: @"?",
                [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
                [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?",
                UIDevice.currentDevice.systemVersion ?: @"?",
                UIDevice.currentDevice.model ?: @"?"]);

    id compat = [NSBundle.mainBundle objectForInfoDictionaryKey:@"UIDesignRequiresCompatibility"];
    id sdk = [NSBundle.mainBundle objectForInfoDictionaryKey:@"DTSDKName"];
    id xcode = [NSBundle.mainBundle objectForInfoDictionaryKey:@"DTXcode"];
    AppendLine([NSString stringWithFormat:@"%@ PLIST UIDesignRequiresCompatibility=%@ DTSDKName=%@ DTXcode=%@",
                Stamp(), compat ?: @"<absent>", sdk ?: @"<absent>", xcode ?: @"<absent>"]);
}

__attribute__((constructor))
static void NexusLiquidGlassProbeInit(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }

        gLogQueue = dispatch_queue_create("com.lucas.nexus.liquidglassprobe.log", DISPATCH_QUEUE_SERIAL);
        gSeenLines = [NSMutableSet set];
        gHookedMethods = [NSMutableSet set];

        dispatch_async(dispatch_get_main_queue(), ^{
            PrepareReport();
            InspectKnownSymbols();

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                InspectObjectiveCRuntime();
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                InspectObjectiveCRuntime();
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                InspectObjectiveCRuntime();
            });

            gUITimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(gUITimer,
                                      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                      (uint64_t)(2.0 * NSEC_PER_SEC),
                                      (uint64_t)(0.25 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gUITimer, ^{
                ScanVisibleUI();
            });
            dispatch_resume(gUITimer);
        });
    }
}
