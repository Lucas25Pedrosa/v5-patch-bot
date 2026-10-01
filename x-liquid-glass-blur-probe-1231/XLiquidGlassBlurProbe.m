#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kXBPLogFileName = @"XLiquidGlassBlurProbe12.31.log";
static const NSUInteger kXBPMaxLogBytes = 6 * 1024 * 1024;
static NSString *const kXBPVersion = @"0.1.0";

#pragma mark - Original IMPs / state

static IMP gOrigSearchLayout = NULL;
static IMP gOrigSearchDidAppear = NULL;
static IMP gOrigVisualEffectSetEffect = NULL;
static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;

static NSMutableDictionary<NSString *, NSValue *> *gOrigInterestingLayouts = nil;
static NSMutableSet<NSString *> *gHookedInterestingLayoutClasses = nil;

static BOOL gSearchHooksInstalled = NO;
static BOOL gVisualEffectHookInstalled = NO;
static BOOL gNFBHookInstalled = NO;
static NSUInteger gCaptureCount = 0;

static char kXBPLastSearchSignatureKey;
static char kXBPLastVisualEffectSignatureKey;
static char kXBPLastInterestingLayoutSignatureKey;

#pragma mark - Logging

static NSString *XBPLogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kXBPLogFileName];
}

static NSString *XBPStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:NSDate.date];
}

static NSString *XBPText(id value) {
    if (!value || value == NSNull.null) return @"-";
    NSString *s = [value description] ?: @"-";
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (s.length > 900) {
        s = [[s substringToIndex:900] stringByAppendingString:@"…"];
    }
    return s.length ? s : @"-";
}

static void XBPTrimLogIfNeeded(void) {
    NSString *path = XBPLogPath();
    NSDictionary *attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size <= kXBPMaxLogBytes) return;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length <= kXBPMaxLogBytes) return;

    NSUInteger keep = kXBPMaxLogBytes / 2;
    NSData *tail =
        [data subdataWithRange:NSMakeRange(data.length - keep, keep)];
    [tail writeToFile:path atomically:YES];
}

static void XBPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void XBPLog(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args, format);
    NSString *body =
        [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"[%@] %@\n", XBPStamp(), body ?: @""];
    NSLog(@"[XLiquidGlassBlurProbe] %@", body ?: @"");

    @synchronized([NSFileManager defaultManager]) {
        NSString *path = XBPLogPath();
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [@"" writeToFile:path
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:nil];
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
        XBPTrimLogIfNeeded();
    }
}

#pragma mark - Generic helpers

static BOOL XBPHookMethod(Class cls,
                          SEL sel,
                          IMP replacement,
                          IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP current = class_getMethodImplementation(cls, sel);
    if (current == replacement) return YES;

    if (originalOut && !*originalOut) *originalOut = current;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    class_replaceMethod(cls, sel, replacement, types);
    return class_getMethodImplementation(cls, sel) == replacement;
}

static BOOL XBPStringHasAny(NSString *text, NSArray<NSString *> *needles) {
    if (!text.length) return NO;
    NSString *lower = text.lowercaseString;
    for (NSString *needle in needles) {
        if ([lower containsString:needle.lowercaseString]) return YES;
    }
    return NO;
}

static NSArray<NSString *> *XBPInterestingFragments(void) {
    static NSArray<NSString *> *fragments;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fragments = @[
            @"blur",
            @"glass",
            @"effect",
            @"backdrop",
            @"material",
            @"scrolledge",
            @"scroll_edge",
            @"xds"
        ];
    });
    return fragments;
}

static NSArray<UIWindow *> *XBPAllWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window) [windows addObject:window];
        }
    }

    if (!windows.count) {
        for (UIWindow *window in UIApplication.sharedApplication.windows ?: @[]) {
            if (window) [windows addObject:window];
        }
    }

    return windows;
}

static NSArray<UIViewController *> *XBPControllerHierarchy(void) {
    NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
    for (UIWindow *window in XBPAllWindows()) {
        if (window.rootViewController) [queue addObject:window.rootViewController];
    }

    NSMutableArray<UIViewController *> *result = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];

    for (NSUInteger i = 0; i < queue.count && i < 1024; i++) {
        UIViewController *vc = queue[i];
        if (!vc) continue;

        NSValue *key = [NSValue valueWithNonretainedObject:vc];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [result addObject:vc];

        if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
        [queue addObjectsFromArray:vc.childViewControllers ?: @[]];

        if ([vc isKindOfClass:UINavigationController.class]) {
            [queue addObjectsFromArray:
                ((UINavigationController *)vc).viewControllers ?: @[]];
        }
        if ([vc isKindOfClass:UITabBarController.class]) {
            [queue addObjectsFromArray:
                ((UITabBarController *)vc).viewControllers ?: @[]];
        }
    }

    return result;
}

static BOOL XBPIsSearchController(id object) {
    return object &&
        [object isKindOfClass:UIViewController.class] &&
        [NSStringFromClass([object class])
            isEqualToString:@"TTSSearchContainerViewControllerV2"];
}

static NSArray<UIViewController *> *XBPVisibleSearchControllers(void) {
    NSMutableArray *result = [NSMutableArray array];

    for (UIViewController *vc in XBPControllerHierarchy()) {
        if (!XBPIsSearchController(vc)) continue;
        if (vc.isViewLoaded && vc.view.window) [result addObject:vc];
    }

    return result;
}

static UIViewController *XBPSearchControllerForView(UIView *view) {
    if (!view) return nil;

    UIResponder *responder = view;
    for (NSUInteger depth = 0; responder && depth < 100; depth++) {
        if (XBPIsSearchController(responder)) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }

    for (UIViewController *controller in XBPVisibleSearchControllers()) {
        if (controller.isViewLoaded &&
            [view isDescendantOfView:controller.view]) {
            return controller;
        }
    }

    return nil;
}

static NSString *XBPSuperviewChain(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIView *current = view;

    for (NSUInteger depth = 0; current && depth < 14; depth++) {
        [parts addObject:NSStringFromClass(current.class) ?: @"?"];
        current = current.superview;
    }

    return [parts componentsJoinedByString:@" <- "];
}

static NSString *XBPNearestControllerName(UIView *view) {
    UIResponder *responder = view;
    for (NSUInteger depth = 0; responder && depth < 80; depth++) {
        if ([responder isKindOfClass:UIViewController.class]) {
            return NSStringFromClass([responder class]) ?: @"-";
        }
        responder = responder.nextResponder;
    }
    return @"-";
}

static id XBPSafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *XBPLayerSignals(CALayer *layer) {
    if (!layer) return @"-";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    id filters = XBPSafeValueForKey(layer, @"filters");
    if (filters) [parts addObject:[NSString stringWithFormat:@"filters=%@", XBPText(filters)]];

    id backgroundFilters = XBPSafeValueForKey(layer, @"backgroundFilters");
    if (backgroundFilters) {
        [parts addObject:
            [NSString stringWithFormat:@"backgroundFilters=%@",
             XBPText(backgroundFilters)]];
    }

    id compositingFilter = XBPSafeValueForKey(layer, @"compositingFilter");
    if (compositingFilter) {
        [parts addObject:
            [NSString stringWithFormat:@"compositingFilter=%@",
             XBPText(compositingFilter)]];
    }

    id cornerCurve = XBPSafeValueForKey(layer, @"cornerCurve");
    if (cornerCurve) {
        [parts addObject:
            [NSString stringWithFormat:@"cornerCurve=%@", XBPText(cornerCurve)]];
    }

    return parts.count ? [parts componentsJoinedByString:@" "] : @"-";
}

static BOOL XBPLayerLooksInteresting(CALayer *layer) {
    NSString *signals = XBPLayerSignals(layer);
    return XBPStringHasAny(signals, XBPInterestingFragments()) ||
           [signals.lowercaseString containsString:@"gaussian"] ||
           [signals.lowercaseString containsString:@"variable"];
}

static NSString *XBPEffectDescription(UIView *view) {
    if (![view isKindOfClass:UIVisualEffectView.class]) return @"-";

    UIVisualEffect *effect = ((UIVisualEffectView *)view).effect;
    if (!effect) return @"nil";

    return [NSString stringWithFormat:@"%@:%@",
            NSStringFromClass(effect.class),
            XBPText(effect)];
}

static BOOL XBPViewLooksInteresting(UIView *view) {
    if (!view) return NO;

    NSString *className = NSStringFromClass(view.class) ?: @"";
    if (XBPStringHasAny(className, XBPInterestingFragments())) return YES;

    if ([view isKindOfClass:UIVisualEffectView.class]) return YES;

    NSString *effect = XBPEffectDescription(view);
    if (XBPStringHasAny(effect, XBPInterestingFragments())) return YES;

    if (XBPLayerLooksInteresting(view.layer)) return YES;

    return NO;
}

static NSArray<UIView *> *XBPCandidateViews(UIView *root) {
    if (!root) return @[];

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSMutableArray<UIView *> *result = [NSMutableArray array];

    for (NSUInteger i = 0; i < queue.count && i < 7000; i++) {
        UIView *view = queue[i];
        if (XBPViewLooksInteresting(view)) [result addObject:view];
        [queue addObjectsFromArray:view.subviews ?: @[]];
    }

    return result;
}

static void XBPDumpRelevantObjectIvars(id object, NSString *label) {
    if (!object) return;

    for (Class cls = object_getClass(object);
         cls && cls != NSObject.class;
         cls = class_getSuperclass(cls)) {

        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);

        for (unsigned int i = 0; i < count; i++) {
            Ivar ivar = ivars[i];
            const char *rawName = ivar_getName(ivar);
            const char *rawType = ivar_getTypeEncoding(ivar);
            NSString *name = rawName ? [NSString stringWithUTF8String:rawName] : @"";

            if (!XBPStringHasAny(name, XBPInterestingFragments())) continue;

            if (rawType && rawType[0] == '@') {
                id value = nil;
                @try {
                    value = object_getIvar(object, ivar);
                } @catch (__unused NSException *exception) {
                }

                XBPLog(@"OBJECT_IVAR label=%@ owner=%@ name=%@ type=%s valueClass=%@ value=%@",
                       label,
                       NSStringFromClass(cls),
                       name,
                       rawType ?: "-",
                       value ? NSStringFromClass([value class]) : @"nil",
                       XBPText(value));
            } else {
                XBPLog(@"OBJECT_IVAR label=%@ owner=%@ name=%@ type=%s value=<scalar>",
                       label,
                       NSStringFromClass(cls),
                       name,
                       rawType ?: "-");
            }
        }

        free(ivars);
    }
}

static NSString *XBPCandidateSignature(UIViewController *controller) {
    if (!controller || !controller.isViewLoaded) return @"-";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    for (UIView *view in XBPCandidateViews(controller.view)) {
        UIWindow *window = view.window ?: controller.view.window;
        CGRect frame = window
            ? [view convertRect:view.bounds toView:window]
            : view.frame;

        [parts addObject:
            [NSString stringWithFormat:@"%@|%@|%.3f|%d|%@|%@",
             NSStringFromClass(view.class),
             NSStringFromCGRect(frame),
             view.alpha,
             view.hidden,
             XBPEffectDescription(view),
             XBPLayerSignals(view.layer)]];
    }

    return [parts componentsJoinedByString:@"\n"];
}

static void XBPDumpCandidate(UIView *view,
                             UIViewController *searchController,
                             NSUInteger index,
                             NSString *reason) {
    if (!view || !searchController) return;

    UIWindow *window = view.window ?: searchController.view.window;
    CGRect frameInWindow = window
        ? [view convertRect:view.bounds toView:window]
        : CGRectZero;
    CGRect frameInSearch =
        [view convertRect:view.bounds toView:searchController.view];

    NSString *superName =
        view.superview ? NSStringFromClass(view.superview.class) : @"nil";

    XBPLog(@"SEARCH_CANDIDATE index=%lu reason=%@ ptr=%p class=%@ superclass=%@ frameWindow=%@ frameSearch=%@ bounds=%@ alpha=%.3f hidden=%d opaque=%d clips=%d userInteraction=%d bg=%@ super=%@ owner=%@ effect=%@ layer=%@ chain=%@",
           (unsigned long)index,
           reason ?: @"-",
           view,
           NSStringFromClass(view.class),
           NSStringFromClass(class_getSuperclass(view.class)),
           NSStringFromCGRect(frameInWindow),
           NSStringFromCGRect(frameInSearch),
           NSStringFromCGRect(view.bounds),
           view.alpha,
           view.hidden,
           view.opaque,
           view.clipsToBounds,
           view.userInteractionEnabled,
           XBPText(view.backgroundColor),
           superName,
           XBPNearestControllerName(view),
           XBPEffectDescription(view),
           XBPLayerSignals(view.layer),
           XBPSuperviewChain(view));

    XBPDumpRelevantObjectIvars(
        view,
        [NSString stringWithFormat:@"candidate-%lu", (unsigned long)index]);
}

#pragma mark - Runtime class metadata

static BOOL XBPSelectorLooksInteresting(NSString *selectorName) {
    return XBPStringHasAny(
        selectorName,
        @[@"blur", @"glass", @"effect", @"backdrop", @"material",
          @"scroll", @"edge", @"treatment", @"configuration", @"configure",
          @"style", @"surface", @"occluder", @"tray", @"layout"]);
}

static void XBPDumpClassMetadata(Class cls) {
    if (!cls) return;

    NSString *name = NSStringFromClass(cls);
    XBPLog(@"CLASS_DUMP_BEGIN class=%@ superclass=%@ ptr=%p",
           name,
           NSStringFromClass(class_getSuperclass(cls)),
           cls);

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *rawName = ivar_getName(ivars[i]);
        const char *type = ivar_getTypeEncoding(ivars[i]);
        NSString *ivarName =
            rawName ? [NSString stringWithUTF8String:rawName] : @"";

        if (!XBPStringHasAny(ivarName, XBPInterestingFragments())) continue;

        XBPLog(@"IVAR class=%@ name=%@ type=%s offset=%td",
               name,
               ivarName,
               type ?: "-",
               ivar_getOffset(ivars[i]));
    }
    free(ivars);

    unsigned int propertyCount = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &propertyCount);
    for (unsigned int i = 0; i < propertyCount; i++) {
        const char *rawName = property_getName(properties[i]);
        const char *attrs = property_getAttributes(properties[i]);
        NSString *propertyName =
            rawName ? [NSString stringWithUTF8String:rawName] : @"";

        if (!XBPStringHasAny(propertyName, XBPInterestingFragments())) continue;

        XBPLog(@"PROPERTY class=%@ name=%@ attrs=%s",
               name,
               propertyName,
               attrs ?: "-");
    }
    free(properties);

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *selectorName = NSStringFromSelector(sel);
        if (!XBPSelectorLooksInteresting(selectorName)) continue;

        XBPLog(@"METHOD class=%@ selector=%@ types=%s",
               name,
               selectorName,
               method_getTypeEncoding(methods[i]) ?: "-");
    }
    free(methods);

    XBPLog(@"CLASS_DUMP_END class=%@", name);
}

static NSArray<Class> *XBPInterestingRuntimeClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return @[];

    Class *classes =
        (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);

    NSMutableArray<Class> *result = [NSMutableArray array];

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls) ?: @"";
        if (!XBPStringHasAny(name, XBPInterestingFragments())) continue;

        [result addObject:cls];
        if (result.count >= 320) break;
    }

    free(classes);

    [result sortUsingComparator:^NSComparisonResult(Class a, Class b) {
        return [NSStringFromClass(a) compare:NSStringFromClass(b)];
    }];

    return result;
}

static void XBPDumpExactClassPresence(void) {
    NSArray<NSString *> *names = @[
        @"TTSSearchContainerViewControllerV2",
        @"XDesignSystem.ScrollEdgeTreatment",
        @"XDesignSystem.Blur",
        @"XDesignSystem.Glass",
        @"XDesignSystem.Blur.Configuration",
        @"XDesignSystem.Glass.Configuration",
        @"UIGlassEffect",
        @"UIVisualEffectView",
        @"_TtCC5UIKit20ScrollEdgeEffectView12BackdropView",
        @"TFNUISwift.LegacySegmentedTabBarView"
    ];

    XBPLog(@"EXACT_CLASS_PRESENCE_BEGIN");
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        XBPLog(@"CLASS_PRESENCE requested=%@ resolved=%@ ptr=%p superclass=%@",
               name,
               cls ? NSStringFromClass(cls) : @"nil",
               cls,
               cls ? NSStringFromClass(class_getSuperclass(cls)) : @"-");
    }
    XBPLog(@"EXACT_CLASS_PRESENCE_END");
}

#pragma mark - Captures

static void XBPDumpEnvironment(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};

    XBPLog(@"ENV probe=%@ appVersion=%@ appBuild=%@ bundle=%@ system=%@ UIDesignRequiresCompatibility=%@",
           kXBPVersion,
           XBPText(info[@"CFBundleShortVersionString"]),
           XBPText(info[@"CFBundleVersion"]),
           XBPText(info[@"CFBundleIdentifier"]),
           UIDevice.currentDevice.systemVersion,
           XBPText(info[@"UIDesignRequiresCompatibility"]));
}

static void XBPCaptureSearchController(UIViewController *controller,
                                       NSString *reason,
                                       BOOL dumpClassMetadata) {
    if (!controller || !controller.isViewLoaded) return;

    gCaptureCount++;

    XBPLog(@"================ SEARCH_CAPTURE #%lu reason=%@ ================",
           (unsigned long)gCaptureCount,
           reason ?: @"-");

    UIWindow *window = controller.view.window;
    XBPLog(@"SEARCH_ROOT controller=%@ ptr=%p view=%p window=%p frameWindow=%@ bounds=%@ children=%lu",
           NSStringFromClass(controller.class),
           controller,
           controller.view,
           window,
           window
                ? NSStringFromCGRect(
                    [controller.view convertRect:controller.view.bounds
                                           toView:window])
                : @"-",
           NSStringFromCGRect(controller.view.bounds),
           (unsigned long)controller.childViewControllers.count);

    NSArray<UIView *> *candidates = XBPCandidateViews(controller.view);
    XBPLog(@"SEARCH_CANDIDATE_COUNT=%lu", (unsigned long)candidates.count);

    NSUInteger index = 0;
    for (UIView *candidate in candidates) {
        XBPDumpCandidate(candidate, controller, index++, reason);
    }

    if (dumpClassMetadata) {
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (UIView *candidate in candidates) {
            NSString *name = NSStringFromClass(candidate.class);
            if ([seen containsObject:name]) continue;
            [seen addObject:name];
            XBPDumpClassMetadata(candidate.class);
        }
    }

    XBPLog(@"================ END_SEARCH_CAPTURE #%lu ================",
           (unsigned long)gCaptureCount);
}

static void XBPCaptureAllVisibleSearch(NSString *reason,
                                       BOOL dumpClassMetadata) {
    NSArray<UIViewController *> *controllers = XBPVisibleSearchControllers();

    if (!controllers.count) {
        XBPLog(@"SEARCH_CAPTURE_SKIPPED reason=%@ visibleSearch=0",
               reason ?: @"-");
        return;
    }

    for (UIViewController *controller in controllers) {
        XBPCaptureSearchController(controller, reason, dumpClassMetadata);
    }
}

static void XBPFullRuntimeCapture(NSString *reason) {
    gCaptureCount++;

    XBPLog(@"================ FULL_RUNTIME_CAPTURE #%lu reason=%@ ================",
           (unsigned long)gCaptureCount,
           reason ?: @"-");

    XBPDumpEnvironment();
    XBPDumpExactClassPresence();

    NSArray<Class> *classes = XBPInterestingRuntimeClasses();
    XBPLog(@"RUNTIME_CLASS_SCAN count=%lu", (unsigned long)classes.count);

    for (Class cls in classes) {
        XBPDumpClassMetadata(cls);
    }

    XBPLog(@"CONTROLLER_SCAN_BEGIN");
    for (UIViewController *vc in XBPControllerHierarchy()) {
        NSString *name = NSStringFromClass(vc.class);
        if ([name.lowercaseString containsString:@"search"] ||
            [name.lowercaseString containsString:@"explore"] ||
            XBPStringHasAny(name, XBPInterestingFragments())) {
            XBPLog(@"CONTROLLER class=%@ ptr=%p loaded=%d visible=%d parent=%@ nav=%@ presented=%@",
                   name,
                   vc,
                   vc.isViewLoaded,
                   vc.isViewLoaded && vc.view.window != nil,
                   NSStringFromClass(vc.parentViewController.class),
                   NSStringFromClass(vc.navigationController.class),
                   NSStringFromClass(vc.presentedViewController.class));
        }
    }
    XBPLog(@"CONTROLLER_SCAN_END");

    XBPLog(@"================ END_FULL_RUNTIME_CAPTURE #%lu ================",
           (unsigned long)gCaptureCount);
}

#pragma mark - Automatic Search hooks

static void XBPMaybeAutoCaptureSearch(UIViewController *controller,
                                      NSString *reason) {
    if (!controller || !controller.isViewLoaded || !controller.view.window) return;

    NSString *signature = XBPCandidateSignature(controller);
    NSString *previous =
        objc_getAssociatedObject(controller, &kXBPLastSearchSignatureKey);

    if ([previous isEqualToString:signature]) return;

    objc_setAssociatedObject(controller,
                             &kXBPLastSearchSignatureKey,
                             signature,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);

    XBPCaptureSearchController(controller, reason, NO);
}

static void XBPSearchLayout(id self, SEL cmd) {
    if (gOrigSearchLayout) {
        ((void(*)(id,SEL))gOrigSearchLayout)(self, cmd);
    }

    if (![self isKindOfClass:UIViewController.class]) return;
    XBPMaybeAutoCaptureSearch((UIViewController *)self, @"search-layout-change");
}

static void XBPSearchDidAppear(id self, SEL cmd, BOOL animated) {
    if (gOrigSearchDidAppear) {
        ((void(*)(id,SEL,BOOL))gOrigSearchDidAppear)(self, cmd, animated);
    }

    if (![self isKindOfClass:UIViewController.class]) return;

    UIViewController *controller = (UIViewController *)self;
    XBPMaybeAutoCaptureSearch(controller, @"search-didAppear");

    __weak UIViewController *weakController = controller;
    for (NSNumber *delayNumber in @[@0.05, @0.20, @0.50]) {
        NSTimeInterval delay = delayNumber.doubleValue;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                UIViewController *strongController = weakController;
                if (!strongController) return;
                XBPMaybeAutoCaptureSearch(
                    strongController,
                    [NSString stringWithFormat:@"search-delayed-%.2f", delay]);
            });
    }
}

static void XBPInstallSearchHooks(void) {
    if (gSearchHooksInstalled) return;

    Class cls = NSClassFromString(@"TTSSearchContainerViewControllerV2");
    if (!cls) return;

    BOOL layout = XBPHookMethod(
        cls,
        @selector(viewDidLayoutSubviews),
        (IMP)XBPSearchLayout,
        &gOrigSearchLayout);

    BOOL appear = XBPHookMethod(
        cls,
        @selector(viewDidAppear:),
        (IMP)XBPSearchDidAppear,
        &gOrigSearchDidAppear);

    gSearchHooksInstalled = layout || appear;

    if (gSearchHooksInstalled) {
        XBPLog(@"Installed passive Search hooks on %@ layout=%d appear=%d",
               NSStringFromClass(cls),
               layout,
               appear);
    }
}

#pragma mark - Passive UIVisualEffectView observation

static void XBPVisualEffectSetEffect(id self,
                                     SEL cmd,
                                     UIVisualEffect *effect) {
    if (gOrigVisualEffectSetEffect) {
        ((void(*)(id,SEL,id))gOrigVisualEffectSetEffect)(self, cmd, effect);
    }

    if (![self isKindOfClass:UIVisualEffectView.class]) return;

    UIVisualEffectView *view = (UIVisualEffectView *)self;
    UIViewController *search = XBPSearchControllerForView(view);
    if (!search || !view.window) return;

    CGRect frame = [view convertRect:view.bounds toView:view.window];
    NSString *signature =
        [NSString stringWithFormat:@"%@|%@|%@|%@",
         effect ? NSStringFromClass(effect.class) : @"nil",
         XBPText(effect),
         NSStringFromCGRect(frame),
         XBPLayerSignals(view.layer)];

    NSString *previous =
        objc_getAssociatedObject(view, &kXBPLastVisualEffectSignatureKey);
    if ([previous isEqualToString:signature]) return;

    objc_setAssociatedObject(view,
                             &kXBPLastVisualEffectSignatureKey,
                             signature,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);

    XBPLog(@"SET_EFFECT_SEARCH ptr=%p viewClass=%@ effectClass=%@ effect=%@ frameWindow=%@ owner=%@ layer=%@ chain=%@",
           view,
           NSStringFromClass(view.class),
           effect ? NSStringFromClass(effect.class) : @"nil",
           XBPText(effect),
           NSStringFromCGRect(frame),
           NSStringFromClass(search.class),
           XBPLayerSignals(view.layer),
           XBPSuperviewChain(view));
}

static void XBPInstallVisualEffectObservation(void) {
    if (gVisualEffectHookInstalled) return;

    Class cls = UIVisualEffectView.class;
    gVisualEffectHookInstalled =
        XBPHookMethod(cls,
                      @selector(setEffect:),
                      (IMP)XBPVisualEffectSetEffect,
                      &gOrigVisualEffectSetEffect);

    if (gVisualEffectHookInstalled) {
        XBPLog(@"Installed passive UIVisualEffectView setEffect: observation.");
    }
}

#pragma mark - Passive interesting-view layout observation

static void XBPInterestingLayout(id self, SEL cmd) {
    NSString *className = NSStringFromClass([self class]);
    NSValue *origValue = gOrigInterestingLayouts[className];
    IMP original = [origValue pointerValue];

    if (original) {
        ((void(*)(id,SEL))original)(self, cmd);
    }

    if (![self isKindOfClass:UIView.class]) return;
    UIView *view = (UIView *)self;

    UIViewController *search = XBPSearchControllerForView(view);
    if (!search || !view.window) return;

    CGRect frame = [view convertRect:view.bounds toView:view.window];
    NSString *signature =
        [NSString stringWithFormat:@"%@|%@|%.3f|%d|%@",
         NSStringFromCGRect(frame),
         NSStringFromCGRect(view.bounds),
         view.alpha,
         view.hidden,
         XBPLayerSignals(view.layer)];

    NSString *previous =
        objc_getAssociatedObject(view, &kXBPLastInterestingLayoutSignatureKey);
    if ([previous isEqualToString:signature]) return;

    objc_setAssociatedObject(view,
                             &kXBPLastInterestingLayoutSignatureKey,
                             signature,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);

    XBPLog(@"INTERESTING_LAYOUT class=%@ ptr=%p frameWindow=%@ bounds=%@ alpha=%.3f hidden=%d owner=%@ effect=%@ layer=%@ chain=%@",
           className,
           view,
           NSStringFromCGRect(frame),
           NSStringFromCGRect(view.bounds),
           view.alpha,
           view.hidden,
           NSStringFromClass(search.class),
           XBPEffectDescription(view),
           XBPLayerSignals(view.layer),
           XBPSuperviewChain(view));
}

static void XBPTryHookInterestingLayoutClass(Class cls) {
    if (!cls || ![cls isSubclassOfClass:UIView.class]) return;

    NSString *name = NSStringFromClass(cls);
    if ([gHookedInterestingLayoutClasses containsObject:name]) return;

    Method method = class_getInstanceMethod(cls, @selector(layoutSubviews));
    if (!method) return;

    IMP current = class_getMethodImplementation(cls, @selector(layoutSubviews));
    if (current == (IMP)XBPInterestingLayout) {
        [gHookedInterestingLayoutClasses addObject:name];
        return;
    }

    const char *types = method_getTypeEncoding(method);
    if (!types) return;

    gOrigInterestingLayouts[name] = [NSValue valueWithPointer:current];
    class_replaceMethod(cls,
                        @selector(layoutSubviews),
                        (IMP)XBPInterestingLayout,
                        types);

    if (class_getMethodImplementation(cls, @selector(layoutSubviews)) ==
        (IMP)XBPInterestingLayout) {
        [gHookedInterestingLayoutClasses addObject:name];
        XBPLog(@"Installed passive layout observation class=%@", name);
    }
}

static void XBPInstallInterestingLayoutObservations(void) {
    if (!gOrigInterestingLayouts) {
        gOrigInterestingLayouts = [NSMutableDictionary dictionary];
    }
    if (!gHookedInterestingLayoutClasses) {
        gHookedInterestingLayoutClasses = [NSMutableSet set];
    }

    NSArray<NSString *> *exact = @[
        @"XDesignSystem.ScrollEdgeTreatment",
        @"XDesignSystem.Blur",
        @"XDesignSystem.Glass",
        @"XDSBlur",
        @"XDSGlass",
        @"XDSGlassContainer",
        @"_TtCC5UIKit20ScrollEdgeEffectView12BackdropView"
    ];

    for (NSString *name in exact) {
        XBPTryHookInterestingLayoutClass(NSClassFromString(name));
    }

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes =
        (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);

    NSUInteger hookedThisPass = 0;

    for (int i = 0; i < count && hookedThisPass < 80; i++) {
        Class cls = classes[i];
        if (![cls isSubclassOfClass:UIView.class]) continue;

        NSString *name = NSStringFromClass(cls) ?: @"";
        if (!XBPStringHasAny(name, XBPInterestingFragments())) continue;

        NSUInteger before = gHookedInterestingLayoutClasses.count;
        XBPTryHookInterestingLayoutClass(cls);
        if (gHookedInterestingLayoutClasses.count > before) hookedThisPass++;
    }

    free(classes);
}

#pragma mark - NFB menu

@interface XLiquidGlassBlurProbeViewController : UITableViewController
@end

@implementation XLiquidGlassBlurProbeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Blur Probe 12.31";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return @"Probe somente leitura para o X 12.31. Observa Search, ScrollEdge, Blur/Glass, UIGlassEffect, Backdrop e filtros de CALayer. Não remove blur nem altera o Liquid Glass.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"XBPBlurCell";

    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
          reuseIdentifier:identifier];
    }

    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (indexPath.row == 0) {
        cell.textLabel.text = @"Capturar Search agora";
        cell.detailTextLabel.text =
            [NSString stringWithFormat:@"Capturas: %lu",
             (unsigned long)gCaptureCount];
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"Captura runtime completa";
        cell.detailTextLabel.text = @"Classes Blur / Glass / ScrollEdge / XDS.";
    } else if (indexPath.row == 2) {
        cell.textLabel.text = @"Copiar relatório";
        cell.detailTextLabel.text = kXBPLogFileName;
    } else {
        cell.textLabel.text = @"Limpar relatório";
        cell.detailTextLabel.text = @"Remove o relatório anterior.";
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.row == 0) {
        XBPCaptureAllVisibleSearch(@"manual-search", YES);
        [tableView reloadData];
        return;
    }

    if (indexPath.row == 1) {
        XBPFullRuntimeCapture(@"manual-runtime");
        XBPCaptureAllVisibleSearch(@"manual-runtime-search", YES);
        [tableView reloadData];
        return;
    }

    if (indexPath.row == 2) {
        NSString *report =
            [NSString stringWithContentsOfFile:XBPLogPath()
                                      encoding:NSUTF8StringEncoding
                                         error:nil] ?: @"";

        UIPasteboard.generalPasteboard.string = report;

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"Blur Probe 12.31"
                                 message:
                    [NSString stringWithFormat:
                        @"Relatório copiado (%lu caracteres).",
                        (unsigned long)report.length]
                          preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:nil]];

        [self presentViewController:alert
                           animated:YES
                         completion:nil];
        return;
    }

    [[NSFileManager defaultManager]
        removeItemAtPath:XBPLogPath()
                   error:nil];

    gCaptureCount = 0;
    XBPLog(@"LOG RESET");
    XBPDumpEnvironment();
    [tableView reloadData];
}

@end

static BOOL XBPSectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"action"]
                isEqualToString:@"showXLiquidGlassBlurProbe1231"]) {
            return YES;
        }
    }
    return NO;
}

static void XBPInjectNFBSection(id controller) {
    NSArray *sections = nil;

    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        return;
    }

    if (![sections isKindOfClass:NSArray.class] ||
        XBPSectionsContainEntry(sections)) {
        return;
    }

    NSMutableArray *updated = [sections mutableCopy];
    [updated addObject:@{
        @"title": @"Blur Probe 12.31",
        @"subtitle": @"Search / ScrollEdge / UIGlassEffect.",
        @"icon": @"waveform.path.ecg",
        @"action": @"showXLiquidGlassBlurProbe1231"
    }];

    @try {
        [controller setValue:[updated copy] forKey:@"sections"];
    } @catch (__unused NSException *exception) {
    }
}

static void XBPNFBSetupSections(id self, SEL cmd) {
    if (gOrigNFBSetupSections) {
        ((void(*)(id,SEL))gOrigNFBSetupSections)(self, cmd);
    }
    XBPInjectNFBSection(self);
}

static void XBPNFBViewWillAppear(id self, SEL cmd, BOOL animated) {
    if (gOrigNFBViewWillAppear) {
        ((void(*)(id,SEL,BOOL))gOrigNFBViewWillAppear)(self, cmd, animated);
    }

    XBPInjectNFBSection(self);

    UITableView *tableView = nil;
    @try {
        tableView = [self valueForKey:@"tableView"];
    } @catch (__unused NSException *exception) {
    }

    [tableView reloadData];
}

static void XBPShowProbeSettings(id self, SEL cmd) {
    (void)cmd;
    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassBlurProbeViewController *vc =
        [XLiquidGlassBlurProbeViewController new];

    UINavigationController *navigation =
        ((UIViewController *)self).navigationController;

    if (navigation) {
        [navigation pushViewController:vc animated:YES];
    } else {
        UINavigationController *wrapper =
            [[UINavigationController alloc] initWithRootViewController:vc];
        [(UIViewController *)self
            presentViewController:wrapper
                         animated:YES
                       completion:nil];
    }
}

static void XBPInstallNFBIntegration(void) {
    if (gNFBHookInstalled) return;

    Class cls = NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;

    class_addMethod(
        cls,
        NSSelectorFromString(@"showXLiquidGlassBlurProbe1231"),
        (IMP)XBPShowProbeSettings,
        "v@:");

    BOOL setup =
        XBPHookMethod(cls,
                      NSSelectorFromString(@"setupSections"),
                      (IMP)XBPNFBSetupSections,
                      &gOrigNFBSetupSections);

    BOOL appear =
        XBPHookMethod(cls,
                      @selector(viewWillAppear:),
                      (IMP)XBPNFBViewWillAppear,
                      &gOrigNFBViewWillAppear);

    gNFBHookInstalled = setup || appear;

    if (gNFBHookInstalled) {
        XBPLog(@"Installed optional NeoFreeBird Blur Probe menu.");
    }
}

#pragma mark - Install

static void XBPInstallAll(void) {
    XBPInstallSearchHooks();
    XBPInstallVisualEffectObservation();
    XBPInstallInterestingLayoutObservations();
    XBPInstallNFBIntegration();
}

static void XBPScheduleInstall(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            XBPInstallAll();
        });
}

__attribute__((constructor))
static void XLiquidGlassBlurProbeInit(void) {
    @autoreleasepool {
        XBPLog(@"========== XLiquidGlass Blur Probe 12.31 v%@ loaded ==========",
               kXBPVersion);
        XBPLog(@"logPath=%@", XBPLogPath());
        XBPLog(@"Probe is read-only for Search/Blur/Glass/ScrollEdge state.");

        XBPDumpEnvironment();
        XBPDumpExactClassPresence();

        XBPInstallAll();

        for (NSNumber *delayNumber in @[@0.05,@0.20,@0.50,@1.00,@2.00,@4.00]) {
            XBPScheduleInstall(delayNumber.doubleValue);
        }

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(2.5 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                XBPInstallAll();
                XBPLog(@"AUTO_BASELINE_BEGIN");
                XBPDumpEnvironment();
                XBPDumpExactClassPresence();
                XBPCaptureAllVisibleSearch(@"auto-baseline", NO);
                XBPLog(@"AUTO_BASELINE_END");
            });
    }
}
