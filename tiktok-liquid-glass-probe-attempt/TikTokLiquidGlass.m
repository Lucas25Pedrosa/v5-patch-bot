#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kLogName = @"TikTokLiquidGlassProbe.log";
static const NSUInteger kMaxLogBytes = 4 * 1024 * 1024;

static NSMutableDictionary<NSString *, NSValue *> *gOriginals;
static NSMutableSet<NSString *> *gHooked;
static NSMutableSet<NSString *> *gLoggedCalls;
static NSMutableSet<NSString *> *gDiscovered;
static NSMutableDictionary<NSString *, NSValue *> *gViewOriginals;
static NSMutableDictionary<NSString *, NSValue *> *gAlphaOriginals;
static NSMutableDictionary<NSString *, NSValue *> *gBarAlphaOriginals;
static NSMutableDictionary<NSString *, NSValue *> *gBarBackgroundOriginals;
static NSMutableDictionary<NSString *, NSValue *> *gFeedLayoutOriginals;
static NSMutableDictionary<NSString *, NSValue *> *gFeedPagingOriginals;
static NSString *gSessionMarker;
static BOOL gCopyAlertShown = NO;
static UIWindow *gProbeOverlayWindow;
static __weak UIWindow *gPreviousKeyWindow;
static NSArray<UIWindow *> *ActiveWindows(void);

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
            @"isFixEnabled",
            @"tux_liquid_glass_enabled",
            @"ttTabbarLiquidGlassFix",
            @"isLiquidGlassEnabled",
            @"liquidGlassEnabled",
            @"isLiquidGlassButtonEnabled",
            @"isLiquidGlassMenuEnabled",
            @"isLiquidGlassIntroPanelEnabled",
            @"isIntroPanelLiquidGlassBackgroundGuardEnabled",
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
            @"innerPushLiquidGlassEnableFlag",
            @"innerPushLiquidGlassInteractiveEnable",
            @"innerPushLiquidGlassInteractiveEnableFlag",
            @"storyFixViewerListRelationButtonLiquidGlass",
            @"enableBigCardLiquidGlass",
            @"studioTextEditorAdaptLiquidGlass",
            @"studioMusicDetailBottomButtonLiquidGlass",
            @"ecPdpStoreV2EnableLiquidGlass",
            @"ugFeedCardLiquidGlassEnable",
            @"p_enableLiquidGlass",
            @"enableLiquidGlass",
            @"isLiquidGlassEnabledForCapture",
            @"isLiquidGlassEnabledForEdit",
            @"should_survey_use_liquid_glass",
            @"live_ec_prompt_card_liquid_glass",
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


#pragma mark - 0.3 targeted gates + native glass reveal

static BOOL HookKnownBool(Class owner, SEL sel, BOOL classMethod, BOOL forced, NSString *reason) {
    if (!owner || !sel) return NO;
    Class methodOwner = classMethod ? object_getClass(owner) : owner;
    Method m = classMethod ? class_getClassMethod(owner, sel) : class_getInstanceMethod(owner, sel);
    if (!methodOwner || !m || !IsZeroArgBool(m)) return NO;

    IMP replacement = forced ? (IMP)ForceYES : (IMP)ForceNO;
    NSString *key = MethodKey(methodOwner, sel);
    IMP current = method_getImplementation(m);
    if (!current || current == replacement) return YES;

    @synchronized(gOriginals) {
        if (!gOriginals[key]) gOriginals[key] = [NSValue valueWithPointer:current];
    }
    method_setImplementation(m, replacement);
    @synchronized(gHooked) {
        [gHooked addObject:key];
    }

    TLGLog(@"EARLY_HOOK reason=%@ owner=%@ scope=%@ selector=%@ forced=%@ originalIMP=%p",
           reason ?: @"-",
           NSStringFromClass(owner),
           classMethod ? @"class" : @"instance",
           NSStringFromSelector(sel),
           forced ? @"YES" : @"NO",
           current);
    return YES;
}

static void InstallImmediateGateHooks(void) {
    HookKnownBool(NSClassFromString(@"TTKIOS26LiquidGlassSwitch"),
                  NSSelectorFromString(@"isFixEnabled"), YES, YES, @"startup");
    HookKnownBool(NSClassFromString(@"TTKABTest"),
                  NSSelectorFromString(@"tux_liquid_glass_enabled"), YES, YES, @"startup");
    HookKnownBool(NSClassFromString(@"TTKABTest"),
                  NSSelectorFromString(@"ttTabbarLiquidGlassFix"), YES, YES, @"startup");
    HookKnownBool(NSClassFromString(@"TUXSwiftBase.TUXAppInfoUtils"),
                  NSSelectorFromString(@"supportLiquidGlass"), YES, YES, @"startup");
    HookKnownBool(NSClassFromString(@"TTKBizUIComponentDependencyImpl"),
                  NSSelectorFromString(@"isTabBarIOS26LiquidGlassFixEnabled"), NO, YES, @"startup");
}

static BOOL ShouldRevealTikTokTabBackgroundClass(Class cls) {
    if (!cls) return NO;
    NSString *name = NSStringFromClass(cls);
    if ([name isEqualToString:@"TTKTabBarBlurView"]) return YES;
    if ([name containsString:@"TikTokTabBarBasic"] &&
        ([name containsString:@"TabBarBackgroundView"] ||
         [name containsString:@"TabBarGradientView"])) return YES;
    return NO;
}

static IMP OriginalViewIMP(id self, SEL sel) {
    Class c = object_getClass(self);
    while (c) {
        NSValue *v = nil;
        @synchronized(gViewOriginals) {
            v = gViewOriginals[MethodKey(c, sel)];
        }
        if (v) return [v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

static void ApplyRevealToView(UIView *view, NSString *reason) {
    if (![view isKindOfClass:UIView.class]) return;
    if (!ShouldRevealTikTokTabBackgroundClass(view.class)) return;

    CGFloat oldAlpha = view.alpha;
    UIColor *oldColor = view.backgroundColor;
    view.alpha = 0.0;
    view.backgroundColor = UIColor.clearColor;

    NSString *onceKey = [NSString stringWithFormat:@"REVEAL|%p", view];
    BOOL first = NO;
    @synchronized(gDiscovered) {
        if (![gDiscovered containsObject:onceKey]) {
            [gDiscovered addObject:onceKey];
            first = YES;
        }
    }
    if (first) {
        TLGLog(@"REVEAL_APPLIED reason=%@ class=%@ frame=%@ oldAlpha=%.2f oldBackground=%@",
               reason ?: @"-",
               NSStringFromClass(view.class),
               NSStringFromCGRect(view.frame),
               oldAlpha,
               oldColor ?: (id)@"-");
    }
}

static void RevealLayoutSubviews(id self, SEL _cmd) {
    IMP original = OriginalViewIMP(self, _cmd);
    if (original) ((void(*)(id,SEL))original)(self, _cmd);
    if ([self isKindOfClass:UIView.class]) ApplyRevealToView((UIView *)self, @"layoutSubviews");
}


static IMP OriginalAlphaIMP(id self, SEL sel) {
    Class c = object_getClass(self);
    while (c) {
        NSValue *v = nil;
        @synchronized(gAlphaOriginals) {
            v = gAlphaOriginals[MethodKey(c, sel)];
        }
        if (v) return [v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

static void RevealSetAlpha(id self, SEL _cmd, CGFloat requestedAlpha) {
    IMP original = OriginalAlphaIMP(self, _cmd);
    if (original) ((void(*)(id,SEL,CGFloat))original)(self, _cmd, 0.0);

    NSString *onceKey = [NSString stringWithFormat:@"ALPHA_BLOCK|%@", NSStringFromClass([self class])];
    BOOL first = NO;
    @synchronized(gDiscovered) {
        if (![gDiscovered containsObject:onceKey]) {
            [gDiscovered addObject:onceKey];
            first = YES;
        }
    }
    if (first) {
        TLGLog(@"ALPHA_BLOCK class=%@ requested=%.2f forced=0.00 frame=%@",
               NSStringFromClass([self class]),
               requestedAlpha,
               [self isKindOfClass:UIView.class] ? NSStringFromCGRect([(UIView *)self frame]) : @"-");
    }
}

static BOOL HookRevealAlphaClass(Class cls, NSString *reason) {
    if (!ShouldRevealTikTokTabBackgroundClass(cls)) return NO;

    SEL sel = @selector(setAlpha:);
    Method inherited = class_getInstanceMethod(cls, sel);
    if (!inherited) return NO;

    NSString *key = MethodKey(cls, sel);
    @synchronized(gAlphaOriginals) {
        if (gAlphaOriginals[key]) return YES;
    }

    IMP current = class_getMethodImplementation(cls, sel);
    if (!current || current == (IMP)RevealSetAlpha) return YES;

    const char *types = method_getTypeEncoding(inherited);
    if (!types) return NO;

    @synchronized(gAlphaOriginals) {
        gAlphaOriginals[key] = [NSValue valueWithPointer:current];
    }

    BOOL added = class_addMethod(cls, sel, (IMP)RevealSetAlpha, types);
    if (!added) {
        Method direct = class_getInstanceMethod(cls, sel);
        if (!direct) return NO;
        method_setImplementation(direct, (IMP)RevealSetAlpha);
    }

    TLGLog(@"ALPHA_HOOK reason=%@ class=%@ originalIMP=%p mode=%@",
           reason ?: @"-",
           NSStringFromClass(cls),
           current,
           added ? @"add" : @"replace");
    return YES;
}

static BOOL HookRevealClass(Class cls, NSString *reason) {
    if (!ShouldRevealTikTokTabBackgroundClass(cls)) return NO;
    SEL sel = @selector(layoutSubviews);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;

    NSString *key = MethodKey(cls, sel);
    @synchronized(gViewOriginals) {
        if (gViewOriginals[key]) return YES;
    }

    IMP current = class_getMethodImplementation(cls, sel);
    if (!current || current == (IMP)RevealLayoutSubviews) return YES;

    const char *types = method_getTypeEncoding(m);
    if (!types) return NO;
    class_replaceMethod(cls, sel, (IMP)RevealLayoutSubviews, types);
    @synchronized(gViewOriginals) {
        gViewOriginals[key] = [NSValue valueWithPointer:current];
    }

    TLGLog(@"REVEAL_HOOK reason=%@ class=%@ selector=layoutSubviews originalIMP=%p",
           reason ?: @"-", NSStringFromClass(cls), current);
    HookRevealAlphaClass(cls, reason);
    return YES;
}

static void InstallImmediateRevealHooks(void) {
    HookRevealClass(NSClassFromString(@"TTKTabBarBlurView"), @"startup");

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        if (ShouldRevealTikTokTabBackgroundClass(classes[i])) {
            HookRevealClass(classes[i], @"startup-scan");
            HookRevealAlphaClass(classes[i], @"startup-scan");
        }
    }
    free(classes);
}

static void RevealTree(UIView *view, NSUInteger depth) {
    if (!view || depth > 40) return;
    ApplyRevealToView(view, @"tree");
    for (UIView *child in view.subviews) RevealTree(child, depth + 1);
}

static void ApplyRevealToAllWindows(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in ActiveWindows()) RevealTree(window, 0);
    });
}


static id SafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *DescribeViewObject(id object) {
    if (!object) return @"-";
    if (![object isKindOfClass:UIView.class]) {
        return [NSString stringWithFormat:@"%@:%p", NSStringFromClass([object class]), object];
    }

    UIView *view = (UIView *)object;
    return [NSString stringWithFormat:@"%@:%p frame=%@ alpha=%.2f hidden=%@ super=%@:%p",
            NSStringFromClass(view.class),
            view,
            NSStringFromCGRect(view.frame),
            view.alpha,
            view.hidden ? @"YES" : @"NO",
            view.superview ? NSStringFromClass(view.superview.class) : @"-",
            view.superview];
}

static void ProbeTabBarControllerState(UIViewController *vc, NSString *reason, NSUInteger depth) {
    if (!vc || depth > 20) return;

    if ([vc isKindOfClass:NSClassFromString(@"TTKTabBarController")]) {
        id mainTabBar = SafeValueForKey(vc, @"mainTabBar");
        id fakeTabBar = SafeValueForKey(vc, @"fakeTabBar");
        id visualTabBar = SafeValueForKey(vc, @"visualTabBar");
        id tabButtons = SafeValueForKey(vc, @"tabButtons");
        id realBar = SafeValueForKey(fakeTabBar, @"realBar");

        TLGLog(@"TABBAR_STATE reason=%@ controller=%@:%p main=[%@] fake=[%@] visual=[%@] fake.realBar=[%@] buttonsClass=%@ buttonsCount=%ld",
               reason ?: @"-",
               NSStringFromClass(vc.class), vc,
               DescribeViewObject(mainTabBar),
               DescribeViewObject(fakeTabBar),
               DescribeViewObject(visualTabBar),
               DescribeViewObject(realBar),
               tabButtons ? NSStringFromClass([tabButtons class]) : @"-",
               (long)([tabButtons respondsToSelector:@selector(count)] ? [tabButtons count] : -1));
    }

    if (vc.presentedViewController) {
        ProbeTabBarControllerState(vc.presentedViewController, reason, depth + 1);
    }
    for (UIViewController *child in vc.childViewControllers) {
        ProbeTabBarControllerState(child, reason, depth + 1);
    }
}

static void ProbeAllTabBars(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in ActiveWindows()) {
            ProbeTabBarControllerState(window.rootViewController, reason, 0);
        }
    });
}

static void DumpClassShape(Class cls) {
    if (!cls) return;
    TLGLog(@"CLASS_SHAPE_BEGIN class=%@", NSStringFromClass(cls));

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    for (unsigned int i = 0; i < ivarCount && i < 120; i++) {
        TLGLog(@"IVAR class=%@ name=%s type=%s offset=%td",
               NSStringFromClass(cls),
               ivar_getName(ivars[i]) ?: "-",
               ivar_getTypeEncoding(ivars[i]) ?: "-",
               ivar_getOffset(ivars[i]));
    }
    free(ivars);

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned int i = 0; i < methodCount && i < 300; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"tab"] ||
            [lower containsString:@"fake"] ||
            [lower containsString:@"glass"] ||
            [lower containsString:@"blur"] ||
            [lower containsString:@"background"] ||
            [lower containsString:@"layout"]) {
            TLGLog(@"CLASS_METHOD class=%@ selector=%@ types=%s imp=%p",
                   NSStringFromClass(cls),
                   name,
                   method_getTypeEncoding(methods[i]) ?: "-",
                   method_getImplementation(methods[i]));
        }
    }
    free(methods);
    TLGLog(@"CLASS_SHAPE_END class=%@", NSStringFromClass(cls));
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
        if (ShouldRevealTikTokTabBackgroundClass(cls)) HookRevealClass(cls, reason);
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

static NSArray<UIWindow *> *ActiveWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        [windows addObjectsFromArray:windowScene.windows ?: @[]];
    }
    return windows;
}



#pragma mark - 0.7 keep functional tab bars visible

static BOOL ShouldKeepBarVisibleClass(Class cls) {
    if (!cls) return NO;
    NSString *name = NSStringFromClass(cls);
    return [name isEqualToString:@"TTKTabBar"] ||
           [name isEqualToString:@"TTKFakeTabBar"];
}

static IMP OriginalBarAlphaIMP(id self, SEL sel) {
    Class c = object_getClass(self);
    while (c) {
        NSValue *v = nil;
        @synchronized(gBarAlphaOriginals) {
            v = gBarAlphaOriginals[MethodKey(c, sel)];
        }
        if (v) return [v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

static void KeepBarVisibleSetAlpha(id self, SEL _cmd, CGFloat requestedAlpha) {
    IMP original = OriginalBarAlphaIMP(self, _cmd);
    if (original) ((void(*)(id,SEL,CGFloat))original)(self, _cmd, 1.0);

    NSString *onceKey = [NSString stringWithFormat:@"BAR_ALPHA_BLOCK|%@", NSStringFromClass([self class])];
    BOOL first = NO;
    @synchronized(gDiscovered) {
        if (![gDiscovered containsObject:onceKey]) {
            [gDiscovered addObject:onceKey];
            first = YES;
        }
    }
    if (first || requestedAlpha < 0.99) {
        TLGLog(@"BAR_ALPHA_BLOCK class=%@ requested=%.2f forced=1.00 frame=%@",
               NSStringFromClass([self class]),
               requestedAlpha,
               [self isKindOfClass:UIView.class] ? NSStringFromCGRect([(UIView *)self frame]) : @"-");
    }
}

static BOOL HookKeepBarVisibleClass(Class cls, NSString *reason) {
    if (!ShouldKeepBarVisibleClass(cls)) return NO;

    SEL sel = @selector(setAlpha:);
    Method inherited = class_getInstanceMethod(cls, sel);
    if (!inherited) return NO;

    NSString *key = MethodKey(cls, sel);
    @synchronized(gBarAlphaOriginals) {
        if (gBarAlphaOriginals[key]) return YES;
    }

    IMP current = class_getMethodImplementation(cls, sel);
    if (!current || current == (IMP)KeepBarVisibleSetAlpha) return YES;

    const char *types = method_getTypeEncoding(inherited);
    if (!types) return NO;

    @synchronized(gBarAlphaOriginals) {
        gBarAlphaOriginals[key] = [NSValue valueWithPointer:current];
    }

    BOOL added = class_addMethod(cls, sel, (IMP)KeepBarVisibleSetAlpha, types);
    if (!added) {
        Method direct = class_getInstanceMethod(cls, sel);
        if (!direct) return NO;
        method_setImplementation(direct, (IMP)KeepBarVisibleSetAlpha);
    }

    TLGLog(@"BAR_ALPHA_HOOK reason=%@ class=%@ originalIMP=%p mode=%@",
           reason ?: @"-",
           NSStringFromClass(cls),
           current,
           added ? @"add" : @"replace");
    return YES;
}

static void InstallKeepBarVisibleHooks(void) {
    HookKeepBarVisibleClass(NSClassFromString(@"TTKTabBar"), @"startup");
    HookKeepBarVisibleClass(NSClassFromString(@"TTKFakeTabBar"), @"startup");
}

static void KeepBarsVisibleInTree(UIView *view, NSUInteger depth) {
    if (!view || depth > 40) return;
    if (ShouldKeepBarVisibleClass(view.class)) {
        if (view.alpha < 0.99) {
            TLGLog(@"BAR_ALPHA_TREE class=%@ oldAlpha=%.2f frame=%@",
                   NSStringFromClass(view.class),
                   view.alpha,
                   NSStringFromCGRect(view.frame));
        }
        view.alpha = 1.0;
    }
    for (UIView *child in view.subviews) KeepBarsVisibleInTree(child, depth + 1);
}

static void ApplyKeepBarsVisibleToAllWindows(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in ActiveWindows()) KeepBarsVisibleInTree(window, 0);
    });
}

static NSString *ViewParentChain(UIView *view) {
    if (!view) return @"-";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIView *cursor = view;
    NSUInteger depth = 0;
    while (cursor && depth < 10) {
        [parts addObject:[NSString stringWithFormat:@"%@:%p(a=%.2f)",
                          NSStringFromClass(cursor.class),
                          cursor,
                          cursor.alpha]];
        cursor = cursor.superview;
        depth++;
    }
    return [parts componentsJoinedByString:@" <- "];
}

static BOOL IsChainTargetView(UIView *view) {
    if (!view) return NO;
    NSString *name = NSStringFromClass(view.class);
    return [name isEqualToString:@"TTKFakeTabBar"] ||
           [name isEqualToString:@"TTKTabBar"] ||
           [name containsString:@"_UITabBarItemPlatterView"] ||
           [name containsString:@"ClearGlassView"] ||
           [name isEqualToString:@"TTKTabBarButton"] ||
           [name isEqualToString:@"AWETabBarPlusButton"];
}

static void LogTargetViewChains(UIView *view, NSMutableSet<NSString *> *seen, NSUInteger depth) {
    if (!view || depth > 40) return;
    if (IsChainTargetView(view)) {
        NSString *name = NSStringFromClass(view.class);
        NSString *key = [NSString stringWithFormat:@"%@|%p", name, view];
        if (![seen containsObject:key]) {
            [seen addObject:key];
            TLGLog(@"UI_CHAIN %@", ViewParentChain(view));
        }
    }
    for (UIView *child in view.subviews) {
        LogTargetViewChains(child, seen, depth + 1);
    }
}

static void LogAllTargetViewChains(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (UIWindow *window in ActiveWindows()) {
            LogTargetViewChains(window, seen, 0);
        }
    });
}


#pragma mark - 0.8 clear root backgrounds + preserve native glass order

static IMP OriginalBarBackgroundIMP(id self, SEL sel) {
    Class c = object_getClass(self);
    while (c) {
        NSValue *v = nil;
        @synchronized(gBarBackgroundOriginals) {
            v = gBarBackgroundOriginals[MethodKey(c, sel)];
        }
        if (v) return [v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

static void KeepBarRootClearSetBackgroundColor(id self, SEL _cmd, UIColor *requestedColor) {
    IMP original = OriginalBarBackgroundIMP(self, _cmd);
    if (original) ((void(*)(id,SEL,id))original)(self, _cmd, UIColor.clearColor);

    NSString *onceKey = [NSString stringWithFormat:@"BAR_BG_CLEAR|%@", NSStringFromClass([self class])];
    BOOL first = NO;
    @synchronized(gDiscovered) {
        if (![gDiscovered containsObject:onceKey]) {
            [gDiscovered addObject:onceKey];
            first = YES;
        }
    }
    if (first) {
        TLGLog(@"BAR_BG_CLEAR class=%@ requested=%@ forced=clear",
               NSStringFromClass([self class]),
               requestedColor ?: (id)@"-");
    }
}

static BOOL HookBarRootBackgroundClass(Class cls, NSString *reason) {
    if (!ShouldKeepBarVisibleClass(cls)) return NO;

    SEL sel = @selector(setBackgroundColor:);
    Method inherited = class_getInstanceMethod(cls, sel);
    if (!inherited) return NO;

    NSString *key = MethodKey(cls, sel);
    @synchronized(gBarBackgroundOriginals) {
        if (gBarBackgroundOriginals[key]) return YES;
    }

    IMP current = class_getMethodImplementation(cls, sel);
    if (!current || current == (IMP)KeepBarRootClearSetBackgroundColor) return YES;

    const char *types = method_getTypeEncoding(inherited);
    if (!types) return NO;

    @synchronized(gBarBackgroundOriginals) {
        gBarBackgroundOriginals[key] = [NSValue valueWithPointer:current];
    }

    BOOL added = class_addMethod(cls, sel, (IMP)KeepBarRootClearSetBackgroundColor, types);
    if (!added) {
        Method direct = class_getInstanceMethod(cls, sel);
        if (!direct) return NO;
        method_setImplementation(direct, (IMP)KeepBarRootClearSetBackgroundColor);
    }

    TLGLog(@"BAR_BG_HOOK reason=%@ class=%@ originalIMP=%p mode=%@",
           reason ?: @"-",
           NSStringFromClass(cls),
           current,
           added ? @"add" : @"replace");
    return YES;
}

static void InstallBarRootBackgroundHooks(void) {
    HookBarRootBackgroundClass(NSClassFromString(@"TTKTabBar"), @"startup");
    HookBarRootBackgroundClass(NSClassFromString(@"TTKFakeTabBar"), @"startup");
}

static void ClearRootBarBackgroundsInTree(UIView *view, NSUInteger depth) {
    if (!view || depth > 40) return;

    if (ShouldKeepBarVisibleClass(view.class)) {
        if (view.backgroundColor && !CGColorEqualToColor(view.backgroundColor.CGColor, UIColor.clearColor.CGColor)) {
            TLGLog(@"BAR_ROOT_CLEAR class=%@ oldBackground=%@ frame=%@",
                   NSStringFromClass(view.class),
                   view.backgroundColor,
                   NSStringFromCGRect(view.frame));
        }
        view.opaque = NO;
        view.backgroundColor = UIColor.clearColor;
    }

    for (UIView *child in view.subviews) {
        ClearRootBarBackgroundsInTree(child, depth + 1);
    }
}

static void ReorderFakeBarBelowCustomBarInView(UIView *view, NSUInteger depth) {
    if (!view || depth > 40) return;

    UIView *fake = nil;
    UIView *custom = nil;
    for (UIView *child in view.subviews) {
        NSString *name = NSStringFromClass(child.class);
        if ([name isEqualToString:@"TTKFakeTabBar"]) fake = child;
        else if ([name isEqualToString:@"TTKTabBar"]) custom = child;
    }

    if (fake && custom && fake.superview == custom.superview) {
        NSArray *siblings = view.subviews;
        NSUInteger fakeIndex = [siblings indexOfObjectIdenticalTo:fake];
        NSUInteger customIndex = [siblings indexOfObjectIdenticalTo:custom];
        if (fakeIndex != NSNotFound && customIndex != NSNotFound && fakeIndex > customIndex) {
            [view insertSubview:fake belowSubview:custom];
            TLGLog(@"BAR_REORDER parent=%@ fakeBelowCustom=YES",
                   NSStringFromClass(view.class));
        }
    }

    for (UIView *child in view.subviews) {
        ReorderFakeBarBelowCustomBarInView(child, depth + 1);
    }
}

static void ApplyRootBarClearAndOrder(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in ActiveWindows()) {
            ClearRootBarBackgroundsInTree(window, 0);
            ReorderFakeBarBelowCustomBarInView(window, 0);
        }
    });
}


#pragma mark - 0.9 Home feed underlay probe + attempt

static NSInteger SelectedIndexForController(id controller) {
    if (!controller) return -1;
    SEL sel = NSSelectorFromString(@"selectedIndex");
    if ([controller respondsToSelector:sel]) {
        return ((NSInteger(*)(id,SEL))objc_msgSend)(controller, sel);
    }
    id value = SafeValueForKey(controller, @"selectedIndex");
    if ([value respondsToSelector:@selector(integerValue)]) return [value integerValue];
    return -1;
}

static UIViewController *SelectedControllerForController(id controller) {
    if (!controller) return nil;
    SEL sel = NSSelectorFromString(@"selectedViewController");
    if ([controller respondsToSelector:sel]) {
        id value = ((id(*)(id,SEL))objc_msgSend)(controller, sel);
        if ([value isKindOfClass:UIViewController.class]) return value;
    }
    id value = SafeValueForKey(controller, @"selectedViewController");
    if ([value isKindOfClass:UIViewController.class]) return value;
    return nil;
}

static BOOL NameLooksLikeHomeFeed(NSString *name) {
    if (!name.length) return NO;
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"home"] ||
           [lower containsString:@"feed"] ||
           [lower containsString:@"recommend"] ||
           [lower containsString:@"aweme"] ||
           [lower containsString:@"timeline"] ||
           [lower containsString:@"fyp"] ||
           [lower containsString:@"foryou"] ||
           [lower containsString:@"for_you"];
}

static BOOL ControllerTreeLooksLikeHomeFeed(UIViewController *vc, NSUInteger depth) {
    if (!vc || depth > 8) return NO;
    if (NameLooksLikeHomeFeed(NSStringFromClass(vc.class))) return YES;
    for (UIViewController *child in vc.childViewControllers) {
        if (ControllerTreeLooksLikeHomeFeed(child, depth + 1)) return YES;
    }
    if (vc.presentedViewController &&
        ControllerTreeLooksLikeHomeFeed(vc.presentedViewController, depth + 1)) return YES;
    return NO;
}

static NSString *InsetsString(UIEdgeInsets insets) {
    return [NSString stringWithFormat:@"{t=%.1f,l=%.1f,b=%.1f,r=%.1f}",
            insets.top, insets.left, insets.bottom, insets.right];
}

static void LogControllerGeometry(UIViewController *vc, NSString *reason, NSUInteger depth) {
    if (!vc || depth > 8) return;
    UIView *view = vc.viewIfLoaded;
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];

    if (view) {
        CGRect windowFrame = view.window ? [view convertRect:view.bounds toView:view.window] : CGRectZero;
        TLGLog(@"FEED_VC %@reason=%@ depth=%lu class=%@:%p parent=%@ frame=%@ windowFrame=%@ bounds=%@ safe=%@ additional=%@ clips=%@ bg=%@",
               indent,
               reason ?: @"-",
               (unsigned long)depth,
               NSStringFromClass(vc.class), vc,
               vc.parentViewController ? NSStringFromClass(vc.parentViewController.class) : @"-",
               NSStringFromCGRect(view.frame),
               NSStringFromCGRect(windowFrame),
               NSStringFromCGRect(view.bounds),
               InsetsString(view.safeAreaInsets),
               InsetsString(vc.additionalSafeAreaInsets),
               view.clipsToBounds ? @"YES" : @"NO",
               view.backgroundColor ?: (id)@"-");
    } else {
        TLGLog(@"FEED_VC %@reason=%@ depth=%lu class=%@:%p viewLoaded=NO",
               indent, reason ?: @"-", (unsigned long)depth,
               NSStringFromClass(vc.class), vc);
    }

    for (UIViewController *child in vc.childViewControllers) {
        LogControllerGeometry(child, reason, depth + 1);
    }
}

static void LogLayoutContainerSubviews(UIView *container, NSString *reason) {
    if (!container) return;
    TLGLog(@"FEED_CONTAINER reason=%@ class=%@:%p frame=%@ bounds=%@ subviews=%lu",
           reason ?: @"-",
           NSStringFromClass(container.class), container,
           NSStringFromCGRect(container.frame),
           NSStringFromCGRect(container.bounds),
           (unsigned long)container.subviews.count);

    NSUInteger index = 0;
    for (UIView *child in container.subviews) {
        TLGLog(@"FEED_CONTAINER_CHILD reason=%@ index=%lu class=%@:%p frame=%@ alpha=%.2f hidden=%@ bg=%@",
               reason ?: @"-",
               (unsigned long)index++,
               NSStringFromClass(child.class), child,
               NSStringFromCGRect(child.frame),
               child.alpha,
               child.hidden ? @"YES" : @"NO",
               child.backgroundColor ?: (id)@"-");
    }
}

static UIView *DirectLayoutContainerForTabController(UIViewController *controller) {
    if (!controller.viewIfLoaded) return nil;
    Class layoutClass = NSClassFromString(@"UILayoutContainerView");

    UIView *candidate = nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:controller.viewIfLoaded];
    NSUInteger scanned = 0;
    while (stack.count && scanned < 1200) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        scanned++;

        if ((layoutClass && [view isKindOfClass:layoutClass]) ||
            [NSStringFromClass(view.class) isEqualToString:@"UILayoutContainerView"]) {
            BOOL hasTTKTabBar = NO;
            for (UIView *child in view.subviews) {
                if ([NSStringFromClass(child.class) isEqualToString:@"TTKTabBar"]) {
                    hasTTKTabBar = YES;
                    break;
                }
            }
            if (hasTTKTabBar) {
                candidate = view;
                break;
            }
        }

        [stack addObjectsFromArray:view.subviews];
    }
    return candidate;
}

static void ExtendContentSiblingUnderTabBar(UIViewController *controller, NSString *reason) {
    UIView *container = DirectLayoutContainerForTabController(controller);
    if (!container) {
        TLGLog(@"FEED_UNDERLAY reason=%@ result=noLayoutContainer", reason ?: @"-");
        return;
    }

    UIView *tabBar = nil;
    UIView *wrapper = nil;
    for (UIView *child in container.subviews) {
        NSString *name = NSStringFromClass(child.class);
        if ([name isEqualToString:@"TTKTabBar"]) tabBar = child;
        if ([name containsString:@"_UITabBarContainerWrapperView"]) wrapper = child;
    }

    if (!tabBar) {
        TLGLog(@"FEED_UNDERLAY reason=%@ result=noTTKTabBar", reason ?: @"-");
        return;
    }

    CGFloat barTop = CGRectGetMinY(tabBar.frame);
    CGFloat targetHeight = CGRectGetHeight(container.bounds);
    NSUInteger changed = 0;

    for (UIView *child in container.subviews) {
        if (child == tabBar || child == wrapper) continue;
        CGRect f = child.frame;

        BOOL fullWidth = fabs(CGRectGetWidth(f) - CGRectGetWidth(container.bounds)) < 3.0;
        BOOL reachesBar = fabs(CGRectGetMaxY(f) - barTop) < 6.0 ||
                          CGRectGetMaxY(f) <= barTop + 2.0;
        BOOL startsNearTop = CGRectGetMinY(f) < 5.0;

        if (fullWidth && reachesBar && startsNearTop && CGRectGetHeight(f) < targetHeight - 1.0) {
            CGRect old = f;
            f.size.height = targetHeight - f.origin.y;
            child.frame = f;
            child.clipsToBounds = NO;
            changed++;
            TLGLog(@"FEED_UNDERLAY_FRAME reason=%@ class=%@:%p old=%@ new=%@",
                   reason ?: @"-",
                   NSStringFromClass(child.class), child,
                   NSStringFromCGRect(old), NSStringFromCGRect(f));
        }
    }

    TLGLog(@"FEED_UNDERLAY reason=%@ barTop=%.1f containerH=%.1f changed=%lu",
           reason ?: @"-", barTop, targetHeight, (unsigned long)changed);
}

static void ApplyHomeSafeAreaUnderlay(UIViewController *vc, CGFloat barHeight, NSString *reason, NSUInteger depth) {
    if (!vc || depth > 8) return;

    UIView *view = vc.viewIfLoaded;
    if (view) {
        vc.edgesForExtendedLayout |= UIRectEdgeBottom;
        vc.extendedLayoutIncludesOpaqueBars = YES;

        UIEdgeInsets add = vc.additionalSafeAreaInsets;
        CGFloat wantedBottom = -barHeight;
        if (fabs(add.bottom - wantedBottom) > 0.5) {
            UIEdgeInsets old = add;
            add.bottom = wantedBottom;
            vc.additionalSafeAreaInsets = add;
            TLGLog(@"FEED_SAFEAREA reason=%@ class=%@:%p old=%@ new=%@",
                   reason ?: @"-",
                   NSStringFromClass(vc.class), vc,
                   InsetsString(old), InsetsString(add));
        }
        view.clipsToBounds = NO;
    }

    for (UIViewController *child in vc.childViewControllers) {
        ApplyHomeSafeAreaUnderlay(child, barHeight, reason, depth + 1);
    }
}

static void ProbeAndAttemptFeedUnderlayForController(UIViewController *controller, NSString *reason) {
    if (!controller) return;

    NSInteger selectedIndex = SelectedIndexForController(controller);
    UIViewController *selected = SelectedControllerForController(controller);
    if (!selected) {
        for (UIViewController *child in controller.childViewControllers) {
            if (child.viewIfLoaded.window) {
                selected = child;
                break;
            }
        }
    }

    BOOL looksHome = (selectedIndex == 0) ||
                     ControllerTreeLooksLikeHomeFeed(selected ?: controller, 0);

    UIView *visualTabBar = nil;
    @try {
        id value = [controller valueForKey:@"visualTabBar"];
        if ([value isKindOfClass:UIView.class]) visualTabBar = value;
    } @catch (__unused NSException *exception) {}

    CGFloat barHeight = visualTabBar ? CGRectGetHeight(visualTabBar.bounds) : 83.0;

    TLGLog(@"FEED_STATE reason=%@ controller=%@:%p selectedIndex=%ld selected=%@:%p looksHome=%@ barHeight=%.1f",
           reason ?: @"-",
           NSStringFromClass(controller.class), controller,
           (long)selectedIndex,
           selected ? NSStringFromClass(selected.class) : @"-",
           selected,
           looksHome ? @"YES" : @"NO",
           barHeight);

    LogControllerGeometry(selected ?: controller, reason, 0);

    UIView *container = DirectLayoutContainerForTabController(controller);
    LogLayoutContainerSubviews(container, reason);

    if (!looksHome) {
        TLGLog(@"FEED_ATTEMPT reason=%@ skipped=notHome", reason ?: @"-");
        return;
    }

    ApplyHomeSafeAreaUnderlay(selected ?: controller, barHeight, reason, 0);
    ExtendContentSiblingUnderTabBar(controller, reason);
}

static IMP OriginalFeedLayoutIMP(id self, SEL sel) {
    Class c = object_getClass(self);
    while (c) {
        NSValue *v = nil;
        @synchronized(gFeedLayoutOriginals) {
            v = gFeedLayoutOriginals[MethodKey(c, sel)];
        }
        if (v) return [v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

static void FeedUnderlayViewDidLayoutSubviews(id self, SEL _cmd) {
    IMP original = OriginalFeedLayoutIMP(self, _cmd);
    if (original) ((void(*)(id,SEL))original)(self, _cmd);

    if ([self isKindOfClass:UIViewController.class]) {
        ProbeAndAttemptFeedUnderlayForController((UIViewController *)self, @"viewDidLayoutSubviews");
    }
}

static void InstallFeedUnderlayLayoutHook(void) {
    Class cls = NSClassFromString(@"TTKTabBarController");
    if (!cls) {
        TLGLog(@"FEED_LAYOUT_HOOK result=noClass");
        return;
    }

    SEL sel = @selector(viewDidLayoutSubviews);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        TLGLog(@"FEED_LAYOUT_HOOK result=noMethod");
        return;
    }

    NSString *key = MethodKey(cls, sel);
    IMP current = class_getMethodImplementation(cls, sel);
    if (!current || current == (IMP)FeedUnderlayViewDidLayoutSubviews) return;

    @synchronized(gFeedLayoutOriginals) {
        gFeedLayoutOriginals[key] = [NSValue valueWithPointer:current];
    }

    const char *types = method_getTypeEncoding(m);
    BOOL added = class_addMethod(cls, sel, (IMP)FeedUnderlayViewDidLayoutSubviews, types);
    if (!added) method_setImplementation(m, (IMP)FeedUnderlayViewDidLayoutSubviews);

    TLGLog(@"FEED_LAYOUT_HOOK class=%@ originalIMP=%p mode=%@",
           NSStringFromClass(cls), current, added ? @"add" : @"replace");
}

static void ProbeAllFeedUnderlay(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class target = NSClassFromString(@"TTKTabBarController");
        if (!target) return;

        NSMutableArray<UIViewController *> *stack = [NSMutableArray array];
        for (UIWindow *window in ActiveWindows()) {
            if (window.rootViewController) [stack addObject:window.rootViewController];
        }

        NSUInteger scanned = 0;
        while (stack.count && scanned < 400) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            scanned++;

            if ([vc isKindOfClass:target]) {
                ProbeAndAttemptFeedUnderlayForController(vc, reason);
            }

            [stack addObjectsFromArray:vc.childViewControllers];
            if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
        }
    });
}


#pragma mark - 1.0 Feed paging probe + visual overdraw attempt

static BOOL PagingSelectorInteresting(NSString *name) {
    if (!name.length) return NO;
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"height"] ||
           [lower containsString:@"row"] ||
           [lower containsString:@"cell"] ||
           [lower containsString:@"page"] ||
           [lower containsString:@"paging"] ||
           [lower containsString:@"inset"] ||
           [lower containsString:@"layout"] ||
           [lower containsString:@"scroll"];
}

static void DumpPagingClassShape(Class cls, NSString *reason) {
    if (!cls) return;
    NSString *onceKey = [NSString stringWithFormat:@"PAGING_SHAPE|%p", cls];
    @synchronized(gDiscovered) {
        if ([gDiscovered containsObject:onceKey]) return;
        [gDiscovered addObject:onceKey];
    }

    TLGLog(@"PAGING_CLASS_BEGIN reason=%@ class=%@", reason ?: @"-", NSStringFromClass(cls));

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        if (!PagingSelectorInteresting(name)) continue;
        TLGLog(@"PAGING_METHOD class=%@ scope=instance selector=%@ types=%s imp=%p",
               NSStringFromClass(cls), name,
               method_getTypeEncoding(methods[i]) ?: "-",
               method_getImplementation(methods[i]));
    }
    free(methods);

    Class meta = object_getClass(cls);
    count = 0;
    methods = class_copyMethodList(meta, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        if (!PagingSelectorInteresting(name)) continue;
        TLGLog(@"PAGING_METHOD class=%@ scope=class selector=%@ types=%s imp=%p",
               NSStringFromClass(cls), name,
               method_getTypeEncoding(methods[i]) ?: "-",
               method_getImplementation(methods[i]));
    }
    free(methods);

    TLGLog(@"PAGING_CLASS_END class=%@", NSStringFromClass(cls));
}

static UITableView *FindPrimaryFeedTableView(UIView *root) {
    if (!root) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger index = 0;
    UITableView *best = nil;
    CGFloat bestArea = 0.0;

    while (index < queue.count && index < 1500) {
        UIView *view = queue[index++];
        if ([view isKindOfClass:UITableView.class]) {
            CGFloat area = CGRectGetWidth(view.bounds) * CGRectGetHeight(view.bounds);
            if (area > bestArea) {
                best = (UITableView *)view;
                bestArea = area;
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return best;
}

static void LogFeedScrollViews(UIView *root, NSString *reason) {
    if (!root) return;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger index = 0;
    NSUInteger logged = 0;

    while (index < queue.count && index < 1500 && logged < 24) {
        UIView *view = queue[index++];
        if ([view isKindOfClass:UIScrollView.class]) {
            UIScrollView *scroll = (UIScrollView *)view;
            TLGLog(@"PAGING_SCROLL reason=%@ class=%@:%p frame=%@ bounds=%@ contentSize=%@ inset=%@ adjusted=%@ paging=%@ clips=%@ delegate=%@",
                   reason ?: @"-",
                   NSStringFromClass(scroll.class), scroll,
                   NSStringFromCGRect(scroll.frame),
                   NSStringFromCGRect(scroll.bounds),
                   NSStringFromCGSize(scroll.contentSize),
                   InsetsString(scroll.contentInset),
                   InsetsString(scroll.adjustedContentInset),
                   scroll.pagingEnabled ? @"YES" : @"NO",
                   scroll.clipsToBounds ? @"YES" : @"NO",
                   scroll.delegate ? NSStringFromClass([scroll.delegate class]) : @"-");
            logged++;
        }
        [queue addObjectsFromArray:view.subviews];
    }
}

static void LogFeedTable(UITableView *table, NSString *reason) {
    if (!table) {
        TLGLog(@"PAGING_TABLE reason=%@ result=notFound", reason ?: @"-");
        return;
    }

    id delegate = table.delegate;
    id dataSource = table.dataSource;
    BOOL hasDelegateHeight = delegate &&
        [delegate respondsToSelector:@selector(tableView:heightForRowAtIndexPath:)];

    TLGLog(@"PAGING_TABLE reason=%@ class=%@:%p frame=%@ bounds=%@ rowHeight=%.1f estimated=%.1f contentSize=%@ inset=%@ adjusted=%@ paging=%@ clips=%@ delegate=%@ dataSource=%@ delegateHeight=%@ visible=%lu",
           reason ?: @"-",
           NSStringFromClass(table.class), table,
           NSStringFromCGRect(table.frame),
           NSStringFromCGRect(table.bounds),
           table.rowHeight,
           table.estimatedRowHeight,
           NSStringFromCGSize(table.contentSize),
           InsetsString(table.contentInset),
           InsetsString(table.adjustedContentInset),
           table.pagingEnabled ? @"YES" : @"NO",
           table.clipsToBounds ? @"YES" : @"NO",
           delegate ? NSStringFromClass([delegate class]) : @"-",
           dataSource ? NSStringFromClass([dataSource class]) : @"-",
           hasDelegateHeight ? @"YES" : @"NO",
           (unsigned long)table.visibleCells.count);

    for (UITableViewCell *cell in table.visibleCells) {
        NSIndexPath *path = [table indexPathForCell:cell];
        TLGLog(@"PAGING_CELL reason=%@ index=%@ class=%@:%p frame=%@ bounds=%@ contentFrame=%@ clips=%@ contentClips=%@",
               reason ?: @"-",
               path ?: (id)@"-",
               NSStringFromClass(cell.class), cell,
               NSStringFromCGRect(cell.frame),
               NSStringFromCGRect(cell.bounds),
               NSStringFromCGRect(cell.contentView.frame),
               cell.clipsToBounds ? @"YES" : @"NO",
               cell.contentView.clipsToBounds ? @"YES" : @"NO");
    }

    if (delegate) DumpPagingClassShape([delegate class], @"tableDelegate");
    if (dataSource && dataSource != delegate) DumpPagingClassShape([dataSource class], @"tableDataSource");
}

static CGFloat FeedVisualTargetHeight(UIViewController *vc) {
    UIWindow *window = vc.viewIfLoaded.window;
    if (window && CGRectGetHeight(window.bounds) > 0.0) return CGRectGetHeight(window.bounds);

    UIViewController *cursor = vc;
    while (cursor.parentViewController) cursor = cursor.parentViewController;
    if (cursor.viewIfLoaded && CGRectGetHeight(cursor.view.bounds) > 0.0)
        return CGRectGetHeight(cursor.view.bounds);

    return UIScreen.mainScreen.bounds.size.height;
}

static void DisableClippingUpToCell(UIView *view) {
    UIView *cursor = view;
    NSUInteger depth = 0;
    while (cursor && depth++ < 10) {
        cursor.clipsToBounds = NO;
        if ([cursor isKindOfClass:UITableViewCell.class]) {
            UITableViewCell *cell = (UITableViewCell *)cursor;
            cell.contentView.clipsToBounds = NO;
            break;
        }
        cursor = cursor.superview;
    }
}

static void ExtendFeedCellControllerVisual(UIViewController *vc, CGFloat targetHeight, NSString *reason) {
    if (!vc || ![NSStringFromClass(vc.class) isEqualToString:@"AWEFeedCellViewController"]) return;
    UIView *view = vc.viewIfLoaded;
    if (!view) return;

    CGRect old = view.frame;
    if (CGRectGetWidth(old) < 300.0 || CGRectGetHeight(old) < 600.0) return;

    CGFloat currentHeight = CGRectGetHeight(old);
    if (targetHeight <= currentHeight + 1.0) return;

    CGRect updated = old;
    updated.size.height = targetHeight;

    view.frame = updated;
    view.clipsToBounds = NO;
    DisableClippingUpToCell(view);

    [view setNeedsLayout];
    [view layoutIfNeeded];

    TLGLog(@"PAGING_CELL_EXTEND reason=%@ controller=%@:%p old=%@ new=%@ target=%.1f",
           reason ?: @"-",
           NSStringFromClass(vc.class), vc,
           NSStringFromCGRect(old), NSStringFromCGRect(view.frame),
           targetHeight);
}

static void ProbeAndAttemptFeedPaging(UIViewController *tableVC, NSString *reason) {
    if (!tableVC || ![NSStringFromClass(tableVC.class) isEqualToString:@"AWENewFeedTableViewController"]) return;
    UIView *root = tableVC.viewIfLoaded;
    if (!root) {
        TLGLog(@"PAGING_STATE reason=%@ controller=%@:%p viewLoaded=NO",
               reason ?: @"-", NSStringFromClass(tableVC.class), tableVC);
        return;
    }

    CGFloat targetHeight = FeedVisualTargetHeight(tableVC);
    UITableView *table = FindPrimaryFeedTableView(root);

    TLGLog(@"PAGING_STATE reason=%@ controller=%@:%p frame=%@ bounds=%@ targetHeight=%.1f children=%lu",
           reason ?: @"-",
           NSStringFromClass(tableVC.class), tableVC,
           NSStringFromCGRect(root.frame),
           NSStringFromCGRect(root.bounds),
           targetHeight,
           (unsigned long)tableVC.childViewControllers.count);

    DumpPagingClassShape(tableVC.class, reason);
    LogFeedTable(table, reason);
    LogFeedScrollViews(root, reason);

    if (table) {
        // Preserve the existing paging geometry; only permit visual overdraw below each 769pt page.
        table.clipsToBounds = NO;
        for (UITableViewCell *cell in table.visibleCells) {
            cell.clipsToBounds = NO;
            cell.contentView.clipsToBounds = NO;
        }
    }

    for (UIViewController *child in tableVC.childViewControllers) {
        if ([NSStringFromClass(child.class) isEqualToString:@"AWEFeedCellViewController"]) {
            ExtendFeedCellControllerVisual(child, targetHeight, reason);
        }
    }
}

static IMP OriginalFeedPagingLayoutIMP(id self, SEL sel) {
    Class c = object_getClass(self);
    while (c) {
        NSValue *v = nil;
        @synchronized(gFeedPagingOriginals) {
            v = gFeedPagingOriginals[MethodKey(c, sel)];
        }
        if (v) return [v pointerValue];
        c = class_getSuperclass(c);
    }
    return NULL;
}

static void FeedPagingViewDidLayoutSubviews(id self, SEL _cmd) {
    IMP original = OriginalFeedPagingLayoutIMP(self, _cmd);
    if (original) ((void(*)(id,SEL))original)(self, _cmd);

    if (![self isKindOfClass:UIViewController.class]) return;
    UIViewController *vc = (UIViewController *)self;
    NSString *name = NSStringFromClass(vc.class);

    if ([name isEqualToString:@"AWENewFeedTableViewController"]) {
        ProbeAndAttemptFeedPaging(vc, @"viewDidLayoutSubviews");
    } else if ([name isEqualToString:@"AWEFeedCellViewController"]) {
        CGFloat targetHeight = FeedVisualTargetHeight(vc);
        ExtendFeedCellControllerVisual(vc, targetHeight, @"cell.viewDidLayoutSubviews");
    }
}

static void InstallFeedPagingHookForClassName(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        TLGLog(@"PAGING_LAYOUT_HOOK class=%@ result=noClass", className);
        return;
    }

    SEL sel = @selector(viewDidLayoutSubviews);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        TLGLog(@"PAGING_LAYOUT_HOOK class=%@ result=noMethod", className);
        return;
    }

    NSString *key = MethodKey(cls, sel);
    IMP current = class_getMethodImplementation(cls, sel);
    if (!current || current == (IMP)FeedPagingViewDidLayoutSubviews) return;

    @synchronized(gFeedPagingOriginals) {
        gFeedPagingOriginals[key] = [NSValue valueWithPointer:current];
    }

    const char *types = method_getTypeEncoding(m);
    BOOL added = class_addMethod(cls, sel, (IMP)FeedPagingViewDidLayoutSubviews, types);
    if (!added) method_setImplementation(m, (IMP)FeedPagingViewDidLayoutSubviews);

    TLGLog(@"PAGING_LAYOUT_HOOK class=%@ originalIMP=%p mode=%@",
           className, current, added ? @"add" : @"replace");
}

static void InstallFeedPagingHooks(void) {
    InstallFeedPagingHookForClassName(@"AWENewFeedTableViewController");
    InstallFeedPagingHookForClassName(@"AWEFeedCellViewController");
}

static void ProbeAllFeedPaging(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray<UIViewController *> *stack = [NSMutableArray array];
        for (UIWindow *window in ActiveWindows()) {
            if (window.rootViewController) [stack addObject:window.rootViewController];
        }

        NSUInteger scanned = 0;
        while (stack.count && scanned < 700) {
            UIViewController *vc = stack.lastObject;
            [stack removeLastObject];
            scanned++;

            NSString *name = NSStringFromClass(vc.class);
            if ([name isEqualToString:@"AWENewFeedTableViewController"]) {
                ProbeAndAttemptFeedPaging(vc, reason);
            } else if ([name isEqualToString:@"AWEFeedCellViewController"]) {
                ExtendFeedCellControllerVisual(vc, FeedVisualTargetHeight(vc), reason);
            }

            [stack addObjectsFromArray:vc.childViewControllers];
            if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
        }
    });
}

#pragma mark - Copy probe alert

static NSString *ReadFullLog(void) {
    NSError *error = nil;
    NSString *text = [NSString stringWithContentsOfFile:LogPath()
                                               encoding:NSUTF8StringEncoding
                                                  error:&error];
    if (!text.length) {
        return error ? [NSString stringWithFormat:@"Falha ao ler o log: %@", error.localizedDescription ?: @"erro desconhecido"] : @"";
    }
    return text;
}

static NSString *ReadCurrentSessionLog(void) {
    NSString *text = ReadFullLog();
    if (!text.length || !gSessionMarker.length) return text ?: @"";

    NSString *needle = [NSString stringWithFormat:@"SESSION_BEGIN id=%@", gSessionMarker];
    NSRange markerRange = [text rangeOfString:needle options:NSBackwardsSearch];
    if (markerRange.location == NSNotFound) return text;

    NSRange lineRange = [text lineRangeForRange:NSMakeRange(markerRange.location, 1)];
    if (lineRange.location >= text.length) return text;
    return [text substringFromIndex:lineRange.location];
}

static UIWindowScene *ForegroundWindowScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (!fallback) fallback = windowScene;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
    }
    return fallback;
}

static void TearDownProbeOverlay(void) {
    UIWindow *window = gProbeOverlayWindow;
    gProbeOverlayWindow = nil;

    if (window) {
        window.hidden = YES;
        window.rootViewController = nil;
    }

    UIWindow *previous = gPreviousKeyWindow;
    gPreviousKeyWindow = nil;
    if (previous && !previous.hidden) {
        [previous makeKeyWindow];
    }
}

static void PresentCopyAlert(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gCopyAlertShown || gProbeOverlayWindow) return;

        UIWindowScene *scene = ForegroundWindowScene();
        if (!scene) {
            TLGLog(@"COPY_OVERLAY_FAILED reason=noWindowScene");
            return;
        }

        for (UIWindow *candidate in scene.windows) {
            if (candidate.isKeyWindow) {
                gPreviousKeyWindow = candidate;
                break;
            }
        }

        UIViewController *root = [UIViewController new];
        root.view.backgroundColor = UIColor.clearColor;

        UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
        window.frame = scene.coordinateSpace.bounds;
        window.backgroundColor = UIColor.clearColor;
        window.windowLevel = UIWindowLevelAlert + 100.0;
        window.rootViewController = root;
        gProbeOverlayWindow = window;

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"TikTokLiquidGlass Probe"
                                                message:@"Coleta concluída. Escolha o que deseja copiar."
                                         preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction actionWithTitle:@"Copiar esta sessão"
                                     style:UIAlertActionStyleDefault
                                   handler:^(__unused UIAlertAction *action) {
                NSString *text = ReadCurrentSessionLog();
                UIPasteboard.generalPasteboard.string = text ?: @"";
                TLGLog(@"COPY_ACTION scope=currentSession chars=%lu",
                       (unsigned long)text.length);
                TearDownProbeOverlay();
            }]];

        [alert addAction:
            [UIAlertAction actionWithTitle:@"Copiar log completo"
                                     style:UIAlertActionStyleDefault
                                   handler:^(__unused UIAlertAction *action) {
                NSString *text = ReadFullLog();
                UIPasteboard.generalPasteboard.string = text ?: @"";
                TLGLog(@"COPY_ACTION scope=fullLog chars=%lu",
                       (unsigned long)text.length);
                TearDownProbeOverlay();
            }]];

        [alert addAction:
            [UIAlertAction actionWithTitle:@"Fechar"
                                     style:UIAlertActionStyleCancel
                                   handler:^(__unused UIAlertAction *action) {
                TLGLog(@"COPY_ACTION scope=close");
                TearDownProbeOverlay();
            }]];

        gCopyAlertShown = YES;
        window.hidden = NO;
        [window makeKeyAndVisible];

        TLGLog(@"COPY_OVERLAY_SHOW scene=%@ level=%.0f",
               scene.session.persistentIdentifier ?: @"-",
               window.windowLevel);

        dispatch_async(dispatch_get_main_queue(), ^{
            [root presentViewController:alert animated:YES completion:^{
                TLGLog(@"COPY_ALERT_PRESENT overlay=YES");
            }];
        });
    });
}

static void SnapshotUI(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<UIWindow *> *windows = ActiveWindows();
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

    TLGLog(@"========== TikTokLiquidGlass 1.0 Feed Paging Probe+Attempt loaded ==========");
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
        gViewOriginals = [NSMutableDictionary dictionary];
        gAlphaOriginals = [NSMutableDictionary dictionary];
        gBarAlphaOriginals = [NSMutableDictionary dictionary];
        gBarBackgroundOriginals = [NSMutableDictionary dictionary];
        gFeedLayoutOriginals = [NSMutableDictionary dictionary];
        gFeedPagingOriginals = [NSMutableDictionary dictionary];
        gSessionMarker = NSUUID.UUID.UUIDString;
        TLGLog(@"SESSION_BEGIN id=%@", gSessionMarker);

        InstallImmediateGateHooks();
        InstallImmediateRevealHooks();
        InstallKeepBarVisibleHooks();
        InstallBarRootBackgroundHooks();
        InstallFeedUnderlayLayoutHook();
        InstallFeedPagingHooks();
        LogContext();
        DumpClassShape(NSClassFromString(@"TTKIOS26LiquidGlassSwitch"));
        DumpClassShape(NSClassFromString(@"TTKTabBarController"));
        DumpClassShape(NSClassFromString(@"TTKFakeTabBar"));
        DumpClassShape(NSClassFromString(@"TTKTabBar"));
        DumpClassShape(NSClassFromString(@"TTKTabBarBlurView"));
        ScanRuntime(@"constructor");

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
                        TLGLog(@"EVENT UIApplicationDidFinishLaunchingNotification");
                        ScanRuntime(@"didFinishLaunching");
                        ApplyRevealToAllWindows();
                        ApplyKeepBarsVisibleToAllWindows();
                        ApplyRootBarClearAndOrder();
                        ProbeAllFeedUnderlay(@"didFinishLaunching");
                        ProbeAllFeedPaging(@"didFinishLaunching");
                        ProbeAllTabBars(@"didFinishLaunching");
                        LogAllTargetViewChains();
                        SnapshotUI(@"didFinishLaunching");
                    }];

        for (NSNumber *n in @[@1.0, @3.0, @8.0]) {
            NSTimeInterval delay = n.doubleValue;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                NSString *reason = [NSString stringWithFormat:@"delay-%.0fs", delay];
                ScanRuntime(reason);
                ApplyRevealToAllWindows();
                ApplyKeepBarsVisibleToAllWindows();
                ApplyRootBarClearAndOrder();
                ProbeAllFeedUnderlay(reason);
                ProbeAllFeedPaging(reason);
                ProbeAllTabBars(reason);
                LogAllTargetViewChains();
                SnapshotUI(reason);
            });
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(9.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PresentCopyAlert();
        });
    }
}
