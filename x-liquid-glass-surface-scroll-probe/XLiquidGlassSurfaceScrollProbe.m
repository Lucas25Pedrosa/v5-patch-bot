#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kSSPLogFileName = @"XLiquidGlassSurfaceScrollProbe.log";
static const NSUInteger kSSPMaxLogBytes = 8 * 1024 * 1024;

static BOOL gSSPScreenMonitorEnabled = NO;
static BOOL gSSPGestureArmed = NO;
static BOOL gSSPGestureActive = NO;
static NSUInteger gSSPGestureSerial = 0;
static NSTimeInterval gSSPLastGestureSample = 0;
static NSString *gSSPLastScreenSignature = nil;
static NSMutableSet<NSString *> *gSSPDumpedRuntimeClasses = nil;
static NSMutableSet<NSString *> *gSSPDumpedCollapseClasses = nil;
static NSUInteger gSSPLastTransformStackSerial = NSNotFound;

static IMP gSSPOrigUIApplicationSendEvent = NULL;
static IMP gSSPOrigNFBSetupSections = NULL;
static IMP gSSPOrigNFBViewWillAppear = NULL;

static IMP gSSPOrigTabBarLayout = NULL;
static IMP gSSPOrigTabBarSetFrame = NULL;
static IMP gSSPOrigTabBarSetCenter = NULL;
static IMP gSSPOrigTabBarSetTransform = NULL;
static IMP gSSPOrigTabBarSetAlpha = NULL;
static IMP gSSPOrigTabBarSetHidden = NULL;

#pragma mark - Log

static NSString *SSPLogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kSSPLogFileName];
}

static NSString *SSPStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:NSDate.date];
}

static NSString *SSPText(id value) {
    if (!value || value == NSNull.null) return @"-";
    NSString *text = [value description] ?: @"-";
    if (text.length > 1400) {
        text = [[text substringToIndex:1400] stringByAppendingString:@"…"];
    }
    return text.length ? text : @"-";
}

static void SSPTrimLog(void) {
    NSString *path = SSPLogPath();
    NSDictionary *attrs =
        [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size <= kSSPMaxLogBytes) return;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length <= kSSPMaxLogBytes) return;

    NSUInteger keep = kSSPMaxLogBytes / 2;
    NSData *tail = [data subdataWithRange:NSMakeRange(data.length - keep, keep)];
    [tail writeToFile:path atomically:YES];
}

static void SSPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void SSPLog(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"[%@] %@\n", SSPStamp(), body ?: @""];
    NSLog(@"[XLiquidGlassSurfaceScrollProbe] %@", body ?: @"");

    @synchronized(NSFileManager.defaultManager) {
        NSString *path = SSPLogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
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
        SSPTrimLog();
    }
}

#pragma mark - Helpers

static id SSPSafeValue(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL SSPHookInstanceMethod(Class cls,
                                  SEL sel,
                                  IMP replacement,
                                  IMP *original) {
    if (!cls || !sel || !replacement) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP current = class_getMethodImplementation(cls, sel);
    if (current == replacement) return YES;

    if (original && !*original) {
        *original = current;
    }

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    class_replaceMethod(cls, sel, replacement, types);
    return class_getMethodImplementation(cls, sel) == replacement;
}

static UIWindow *SSPBestWindow(void) {
    UIWindow *best = nil;

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;

        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) {
            if (window.hidden || window.alpha <= 0.01) continue;
            if (!best || window.isKeyWindow) best = window;
            if (window.isKeyWindow) return window;
        }
    }
    return best;
}

static NSString *SSPColor(UIColor *color) {
    if (!color) return @"nil";

    CGFloat r=0,g=0,b=0,a=0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        return [NSString stringWithFormat:@"rgba(%.3f,%.3f,%.3f,%.3f)",
                r,g,b,a];
    }

    CGFloat w=0;
    if ([color getWhite:&w alpha:&a]) {
        return [NSString stringWithFormat:@"white(%.3f,%.3f)",w,a];
    }

    return SSPText(color);
}

static NSString *SSPTransform(CGAffineTransform t) {
    return [NSString stringWithFormat:
        @"[%.4f %.4f %.4f %.4f %.2f %.2f]",
        t.a,t.b,t.c,t.d,t.tx,t.ty];
}

static NSString *SSPResponderPath(UIResponder *responder) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIResponder *cursor = responder;

    for (NSUInteger i=0; cursor && i<50; i++, cursor=cursor.nextResponder) {
        [parts addObject:NSStringFromClass(cursor.class) ?: @"?"];
    }

    return [parts componentsJoinedByString:@" > "];
}

static NSString *SSPViewPath(UIView *view, UIWindow *window) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIView *cursor = view;

    for (NSUInteger i=0; cursor && i<40; i++, cursor=cursor.superview) {
        [parts addObject:NSStringFromClass(cursor.class) ?: @"?"];
        if (cursor == window) break;
    }

    return [parts componentsJoinedByString:@" < "];
}

static BOOL SSPResponderContains(UIResponder *responder, NSString *needle) {
    if (!needle.length) return NO;

    UIResponder *cursor=responder;
    for (NSUInteger i=0; cursor && i<60; i++, cursor=cursor.nextResponder) {
        NSString *name=NSStringFromClass(cursor.class) ?: @"";
        if ([name containsString:needle]) return YES;
    }
    return NO;
}

static NSArray<UIView *> *SSPSubviewsMatching(UIView *root,
                                              BOOL (^predicate)(UIView *)) {
    if (!root || !predicate) return @[];

    NSMutableArray<UIView *> *queue=[NSMutableArray arrayWithObject:root];
    NSMutableArray<UIView *> *result=[NSMutableArray array];

    for (NSUInteger i=0; i<queue.count && i<10000; i++) {
        UIView *view=queue[i];
        if (predicate(view)) [result addObject:view];
        [queue addObjectsFromArray:view.subviews ?: @[]];
    }

    return result;
}

static NSArray<UIView *> *SSPSubviewsNamed(UIView *root, NSString *className) {
    return SSPSubviewsMatching(root, ^BOOL(UIView *view) {
        return [NSStringFromClass(view.class) isEqualToString:className];
    });
}

static NSString *SSPControllerTitle(UIViewController *vc) {
    if (!vc) return @"-";

    NSString *title=vc.navigationItem.title;
    if (!title.length) title=vc.title;

    id searchItem=SSPSafeValue(vc.navigationItem, @"searchController");
    NSString *query=nil;
    if ([searchItem isKindOfClass:UISearchController.class]) {
        query=((UISearchController *)searchItem).searchBar.text;
    }

    if (query.length) {
        return [NSString stringWithFormat:@"%@ query=%@",
                title.length ? title : @"-",query];
    }
    return title.length ? title : @"-";
}

#pragma mark - Controller tree / signature

static void SSPAppendVisibleControllerInfo(UIViewController *vc,
                                           UIWindow *window,
                                           NSUInteger depth,
                                           NSMutableArray<NSString *> *parts,
                                           NSMutableSet<NSValue *> *visited) {
    if (!vc || depth>14) return;

    NSValue *token=[NSValue valueWithNonretainedObject:vc];
    if ([visited containsObject:token]) return;
    [visited addObject:token];

    BOOL visible =
        vc == window.rootViewController ||
        (vc.isViewLoaded && vc.view.window == window);

    if (visible) {
        NSString *entry=[NSString stringWithFormat:@"%@[%@]",
            NSStringFromClass(vc.class) ?: @"?",
            SSPControllerTitle(vc)];
        [parts addObject:entry];
    }

    if (vc.presentedViewController) {
        SSPAppendVisibleControllerInfo(
            vc.presentedViewController,window,depth+1,parts,visited);
    }

    if ([vc isKindOfClass:UINavigationController.class]) {
        SSPAppendVisibleControllerInfo(
            ((UINavigationController *)vc).visibleViewController,
            window,depth+1,parts,visited);
    }

    if ([vc isKindOfClass:UITabBarController.class]) {
        SSPAppendVisibleControllerInfo(
            ((UITabBarController *)vc).selectedViewController,
            window,depth+1,parts,visited);
    }

    for (UIViewController *child in vc.childViewControllers ?: @[]) {
        if (child.isViewLoaded && child.view.window != window) continue;
        SSPAppendVisibleControllerInfo(
            child,window,depth+1,parts,visited);
    }
}

static NSString *SSPScreenSignature(UIWindow *window) {
    if (!window) return @"window=nil";

    NSMutableArray<NSString *> *parts=[NSMutableArray array];
    NSMutableSet<NSValue *> *visited=[NSMutableSet set];
    SSPAppendVisibleControllerInfo(
        window.rootViewController,window,0,parts,visited);

    return [parts componentsJoinedByString:@" -> "];
}

static void SSPDumpControllerTree(UIViewController *vc,
                                  UIWindow *window,
                                  NSUInteger depth,
                                  NSMutableSet<NSValue *> *visited) {
    if (!vc || depth>14) return;

    NSValue *token=[NSValue valueWithNonretainedObject:vc];
    if ([visited containsObject:token]) return;
    [visited addObject:token];

    BOOL visible =
        vc == window.rootViewController ||
        (vc.isViewLoaded && vc.view.window == window);

    SSPLog(@"CONTROLLER depth=%lu visible=%d class=%@ ptr=%p title=%@ viewClass=%@ presented=%@ children=%lu",
           (unsigned long)depth,
           visible,
           NSStringFromClass(vc.class),
           vc,
           SSPControllerTitle(vc),
           vc.isViewLoaded ? NSStringFromClass(vc.view.class) : @"notLoaded",
           vc.presentedViewController
                ? NSStringFromClass(vc.presentedViewController.class) : @"nil",
           (unsigned long)vc.childViewControllers.count);

    if ([vc isKindOfClass:UINavigationController.class]) {
        UINavigationController *nav=(UINavigationController *)vc;
        SSPLog(@"NAV_CONTROLLER depth=%lu visibleClass=%@ topClass=%@ count=%lu",
               (unsigned long)depth,
               nav.visibleViewController
                    ? NSStringFromClass(nav.visibleViewController.class) : @"nil",
               nav.topViewController
                    ? NSStringFromClass(nav.topViewController.class) : @"nil",
               (unsigned long)nav.viewControllers.count);
    }

    if ([vc isKindOfClass:UITabBarController.class]) {
        UITabBarController *tab=(UITabBarController *)vc;
        SSPLog(@"TAB_CONTROLLER depth=%lu selectedIndex=%lu selectedClass=%@",
               (unsigned long)depth,
               (unsigned long)tab.selectedIndex,
               tab.selectedViewController
                    ? NSStringFromClass(tab.selectedViewController.class) : @"nil");
    }

    if (vc.presentedViewController) {
        SSPDumpControllerTree(
            vc.presentedViewController,window,depth+1,visited);
    }

    for (UIViewController *child in vc.childViewControllers ?: @[]) {
        SSPDumpControllerTree(child,window,depth+1,visited);
    }
}

#pragma mark - Runtime dump

static BOOL SSPRuntimeNameInteresting(NSString *name) {
    NSString *lower=name.lowercaseString ?: @"";
    NSArray<NSString *> *needles=@[
        @"scroll",
        @"tabbar",
        @"tab_bar",
        @"bottom",
        @"hide",
        @"hidden",
        @"show",
        @"visible",
        @"visibility",
        @"offset",
        @"inset",
        @"pan",
        @"drag",
        @"collapse",
        @"expand",
        @"minimi",
        @"transition",
        @"accessory",
        @"effect",
        @"blur",
        @"glass",
        @"material",
        @"background",
        @"alpha",
        @"transform",
        @"frame"
    ];

    for (NSString *needle in needles) {
        if ([lower containsString:needle]) return YES;
    }
    return NO;
}

static void SSPDumpRuntimeClassOnce(Class cls) {
    if (!cls) return;

    if (!gSSPDumpedRuntimeClasses) {
        gSSPDumpedRuntimeClasses=[NSMutableSet set];
    }

    NSString *className=NSStringFromClass(cls) ?: @"?";
    if ([gSSPDumpedRuntimeClasses containsObject:className]) return;
    [gSSPDumpedRuntimeClasses addObject:className];

    SSPLog(@"RUNTIME_CLASS_BEGIN class=%@ ptr=%p",className,cls);

    unsigned int ivarCount=0;
    Ivar *ivars=class_copyIvarList(cls,&ivarCount);
    for (unsigned int i=0;i<ivarCount;i++) {
        NSString *name=[NSString stringWithUTF8String:
            ivar_getName(ivars[i]) ?: ""];
        if (!SSPRuntimeNameInteresting(name)) continue;

        SSPLog(@"IVAR class=%@ name=%@ type=%s offset=%td",
               className,name,
               ivar_getTypeEncoding(ivars[i]) ?: "-",
               ivar_getOffset(ivars[i]));
    }
    free(ivars);

    unsigned int propertyCount=0;
    objc_property_t *properties=class_copyPropertyList(cls,&propertyCount);
    for (unsigned int i=0;i<propertyCount;i++) {
        NSString *name=[NSString stringWithUTF8String:
            property_getName(properties[i]) ?: ""];
        if (!SSPRuntimeNameInteresting(name)) continue;

        SSPLog(@"PROPERTY class=%@ name=%@ attrs=%s",
               className,name,
               property_getAttributes(properties[i]) ?: "-");
    }
    free(properties);

    unsigned int methodCount=0;
    Method *methods=class_copyMethodList(cls,&methodCount);
    for (unsigned int i=0;i<methodCount;i++) {
        SEL sel=method_getName(methods[i]);
        NSString *name=NSStringFromSelector(sel);
        if (!SSPRuntimeNameInteresting(name)) continue;

        SSPLog(@"METHOD class=%@ selector=%@ encoding=%s imp=%p",
               className,name,
               method_getTypeEncoding(methods[i]) ?: "-",
               method_getImplementation(methods[i]));
    }
    free(methods);

    SSPLog(@"RUNTIME_CLASS_END class=%@",className);
}

static void SSPDumpVisibleControllerRuntimeClasses(UIWindow *window) {
    if (!window) return;

    NSMutableArray<UIViewController *> *queue=
        [NSMutableArray arrayWithObject:window.rootViewController];
    NSMutableSet<NSValue *> *visited=[NSMutableSet set];

    for (NSUInteger i=0;i<queue.count && i<200;i++) {
        UIViewController *vc=queue[i];
        NSValue *token=[NSValue valueWithNonretainedObject:vc];
        if ([visited containsObject:token]) continue;
        [visited addObject:token];

        if (vc==window.rootViewController ||
            (vc.isViewLoaded && vc.view.window==window)) {
            SSPDumpRuntimeClassOnce(vc.class);
        }

        if (vc.presentedViewController) {
            [queue addObject:vc.presentedViewController];
        }
        [queue addObjectsFromArray:vc.childViewControllers ?: @[]];
    }
}


#pragma mark - XLiquidGlass 2.1 native collapse diagnostics

static void SSPDumpAllMethodsForCollapseClass(Class cls) {
    if (!cls) return;

    if (!gSSPDumpedCollapseClasses) {
        gSSPDumpedCollapseClasses=[NSMutableSet set];
    }

    NSString *className=NSStringFromClass(cls) ?: @"?";
    if ([gSSPDumpedCollapseClasses containsObject:className]) return;
    [gSSPDumpedCollapseClasses addObject:className];

    SSPLog(@"COLLAPSE_CLASS_BEGIN class=%@ ptr=%p super=%@",
           className,
           cls,
           class_getSuperclass(cls)
               ? NSStringFromClass(class_getSuperclass(cls))
               : @"nil");

    unsigned int ivarCount=0;
    Ivar *ivars=class_copyIvarList(cls,&ivarCount);
    for (unsigned int i=0;i<ivarCount;i++) {
        SSPLog(@"COLLAPSE_IVAR class=%@ name=%s type=%s offset=%td",
               className,
               ivar_getName(ivars[i]) ?: "-",
               ivar_getTypeEncoding(ivars[i]) ?: "-",
               ivar_getOffset(ivars[i]));
    }
    free(ivars);

    unsigned int propertyCount=0;
    objc_property_t *properties=class_copyPropertyList(cls,&propertyCount);
    for (unsigned int i=0;i<propertyCount;i++) {
        SSPLog(@"COLLAPSE_PROPERTY class=%@ name=%s attrs=%s",
               className,
               property_getName(properties[i]) ?: "-",
               property_getAttributes(properties[i]) ?: "-");
    }
    free(properties);

    unsigned int methodCount=0;
    Method *methods=class_copyMethodList(cls,&methodCount);
    unsigned int limit=MIN(methodCount,240u);
    for (unsigned int i=0;i<limit;i++) {
        SEL sel=method_getName(methods[i]);
        SSPLog(@"COLLAPSE_METHOD class=%@ selector=%@ encoding=%s imp=%p",
               className,
               NSStringFromSelector(sel),
               method_getTypeEncoding(methods[i]) ?: "-",
               method_getImplementation(methods[i]));
    }
    if (methodCount>limit) {
        SSPLog(@"COLLAPSE_METHOD_TRUNCATED class=%@ total=%u logged=%u",
               className,methodCount,limit);
    }
    free(methods);

    SSPLog(@"COLLAPSE_CLASS_END class=%@",className);
}

static void SSPDumpCollapseClassHierarchy(id object) {
    if (!object) return;

    Class cls=object_getClass(object);
    for (NSUInteger depth=0; cls && depth<8; depth++) {
        SSPDumpAllMethodsForCollapseClass(cls);
        cls=class_getSuperclass(cls);
    }
}

static void SSPLogBoolCapabilityIfPresent(
    UIViewController *vc,
    NSString *selectorName) {

    if (!vc || !selectorName.length) return;
    SEL sel=NSSelectorFromString(selectorName);
    if (![vc respondsToSelector:sel]) return;

    Method method=class_getInstanceMethod(vc.class,sel);
    const char *encoding=method ? method_getTypeEncoding(method) : NULL;

    BOOL value=((BOOL(*)(id,SEL))objc_msgSend)(vc,sel);
    SSPLog(@"COLLAPSE_CAPABILITY controller=%@ ptr=%p selector=%@ value=%d encoding=%s",
           NSStringFromClass(vc.class),
           vc,
           selectorName,
           value,
           encoding ?: "-");
}

static void SSPDumpVisibleCollapseCapabilities(UIWindow *window) {
    if (!window) return;

    NSMutableArray<UIViewController *> *queue=
        [NSMutableArray arrayWithObject:window.rootViewController];
    NSMutableSet<NSValue *> *visited=[NSMutableSet set];

    for (NSUInteger i=0;i<queue.count && i<220;i++) {
        UIViewController *vc=queue[i];
        NSValue *token=[NSValue valueWithNonretainedObject:vc];
        if ([visited containsObject:token]) continue;
        [visited addObject:token];

        BOOL visible=
            vc==window.rootViewController ||
            (vc.isViewLoaded && vc.view.window==window);

        if (visible) {
            SSPLogBoolCapabilityIfPresent(vc,@"tfn_supportsTabBarCollapsing");
            SSPLogBoolCapabilityIfPresent(vc,@"tfn_prefersTabBarPinned");
            SSPLogBoolCapabilityIfPresent(vc,@"tfn_preferManualNavBarCollapse");
            SSPLogBoolCapabilityIfPresent(vc,@"tfn_prefersNavigationBarExpandedWhenScrolledToBottom");
        }

        if (vc.presentedViewController) {
            [queue addObject:vc.presentedViewController];
        }
        [queue addObjectsFromArray:vc.childViewControllers ?: @[]];
    }
}

static Ivar SSPFindIvarInHierarchy(Class cls, const char *name) {
    for (Class cursor=cls; cursor; cursor=class_getSuperclass(cursor)) {
        Ivar ivar=class_getInstanceVariable(cursor,name);
        if (ivar) return ivar;
    }
    return NULL;
}

static void SSPDumpNavigationCollapseEngine(
    UIViewController *controller) {

    if (!controller) return;

    NSString *name=NSStringFromClass(controller.class) ?: @"";
    if (![name isEqualToString:@"XNavigation.NavigationController"]) {
        return;
    }

    Ivar engineIvar=
        SSPFindIvarInHierarchy(
            controller.class,
            "$__lazy_storage_$_collapseEngine");

    Ivar watcherIvar=
        SSPFindIvarInHierarchy(
            controller.class,
            "scrollToTopWatcher");

    id engine=nil;
    id watcher=nil;

    if (engineIvar) {
        @try {
            engine=object_getIvar(controller,engineIvar);
        } @catch (__unused NSException *exception) {
            engine=nil;
        }
    }

    if (watcherIvar) {
        @try {
            watcher=object_getIvar(controller,watcherIvar);
        } @catch (__unused NSException *exception) {
            watcher=nil;
        }
    }

    SSPLog(@"COLLAPSE_ENGINE nav=%p engineIvar=%p engine=%p engineClass=%@ watcher=%p watcherClass=%@",
           controller,
           engineIvar,
           engine,
           engine ? NSStringFromClass(object_getClass(engine)) : @"nil",
           watcher,
           watcher ? NSStringFromClass(object_getClass(watcher)) : @"nil");

    if (engine) SSPDumpCollapseClassHierarchy(engine);
    if (watcher) SSPDumpCollapseClassHierarchy(watcher);
}

static void SSPDumpVisibleNavigationCollapseEngines(UIWindow *window) {
    if (!window) return;

    NSMutableArray<UIViewController *> *queue=
        [NSMutableArray arrayWithObject:window.rootViewController];
    NSMutableSet<NSValue *> *visited=[NSMutableSet set];

    for (NSUInteger i=0;i<queue.count && i<220;i++) {
        UIViewController *vc=queue[i];
        NSValue *token=[NSValue valueWithNonretainedObject:vc];
        if ([visited containsObject:token]) continue;
        [visited addObject:token];

        if (vc==window.rootViewController ||
            (vc.isViewLoaded && vc.view.window==window)) {
            SSPDumpNavigationCollapseEngine(vc);
        }

        if (vc.presentedViewController) {
            [queue addObject:vc.presentedViewController];
        }
        [queue addObjectsFromArray:vc.childViewControllers ?: @[]];
    }
}

static void SSPDumpNativeCollapseContext(
    UIWindow *window,
    NSString *reason) {

    if (!window) return;

    SSPLog(@"========== NATIVE_COLLAPSE_CONTEXT reason=%@ ==========",
           reason ?: @"-");
    SSPDumpVisibleCollapseCapabilities(window);
    SSPDumpVisibleNavigationCollapseEngines(window);
    SSPLog(@"========== NATIVE_COLLAPSE_CONTEXT_END reason=%@ ==========",
           reason ?: @"-");
}

static void SSPLogTabBarTransformCallStack(
    UIView *view,
    CGAffineTransform transform) {

    if (!gSSPGestureActive ||
        gSSPLastTransformStackSerial==gSSPGestureSerial) {
        return;
    }

    CGFloat ty=transform.ty;
    if (!isfinite(ty) || fabs(ty)<0.5) return;

    gSSPLastTransformStackSerial=gSSPGestureSerial;

    NSArray<NSString *> *symbols=[NSThread callStackSymbols] ?: @[];
    NSUInteger start=MIN((NSUInteger)1,symbols.count);
    NSUInteger count=
        symbols.count>start
            ? MIN((NSUInteger)20,symbols.count-start)
            : 0;
    NSArray<NSString *> *slice=
        count ? [symbols subarrayWithRange:NSMakeRange(start,count)] : @[];

    SSPLog(@"TABBAR_TRANSFORM_CALLSTACK serial=%lu ptr=%p ty=%.2f stack=%@",
           (unsigned long)gSSPGestureSerial,
           view,
           ty,
           [slice componentsJoinedByString:@" | "]);

    SSPDumpNativeCollapseContext(
        view.window ?: SSPBestWindow(),
        @"first-transform-during-gesture");
}

#pragma mark - Surface / blur capture

static BOOL SSPSurfaceClassInteresting(NSString *name) {
    if (!name.length) return NO;

    NSArray<NSString *> *needles=@[
        @"ScrollEdge",
        @"VisualEffect",
        @"Backdrop",
        @"Blur",
        @"Glass",
        @"Liquid",
        @"Material",
        @"NavigationBar",
        @"BarBackground",
        @"ChromeBackground",
        @"AccessoryStack",
        @"TabBar",
        @"Platter"
    ];

    for (NSString *needle in needles) {
        if ([name localizedCaseInsensitiveContainsString:needle]) return YES;
    }
    return NO;
}

static NSString *SSPRegionForFrame(CGRect frame,
                                   CGFloat topLimit,
                                   CGFloat bottomStart) {
    BOOL top=CGRectGetMaxY(frame)>0.0 &&
             CGRectGetMinY(frame)<topLimit;
    BOOL bottom=CGRectGetMaxY(frame)>bottomStart;

    if (top && bottom) return @"BOTH";
    if (top) return @"TOP";
    if (bottom) return @"BOTTOM";
    return nil;
}

static void SSPSnapshotSurface(UIWindow *window, NSString *reason) {
    if (!window) return;

    CGRect bounds=window.bounds;
    CGFloat height=CGRectGetHeight(bounds);
    CGFloat topLimit=MIN(240.0,height*0.32);
    CGFloat bottomStart=MAX(height-240.0,height*0.68);

    NSString *signature=SSPScreenSignature(window);

    SSPLog(@"========== SURFACE_SNAPSHOT reason=%@ ==========",
           reason ?: @"-");
    SSPLog(@"SCREEN signature=%@",signature);
    SSPLog(@"WINDOW class=%@ ptr=%p bounds=%@ safeInsets=%@ topLimit=%.1f bottomStart=%.1f",
           NSStringFromClass(window.class),
           window,
           NSStringFromCGRect(bounds),
           NSStringFromUIEdgeInsets(window.safeAreaInsets),
           topLimit,
           bottomStart);

    NSMutableSet<NSValue *> *visited=[NSMutableSet set];
    SSPDumpControllerTree(window.rootViewController,window,0,visited);

    NSMutableArray<UIView *> *queue=[NSMutableArray arrayWithObject:window];
    NSMutableSet<NSString *> *runtimeClasses=[NSMutableSet set];
    NSUInteger count=0;

    for (NSUInteger i=0;i<queue.count && i<10000;i++) {
        UIView *view=queue[i];
        [queue addObjectsFromArray:view.subviews ?: @[]];

        if (view.hidden || view.alpha<=0.001) continue;

        CGRect frame=CGRectZero;
        @try {
            frame=[view convertRect:view.bounds toView:window];
        } @catch (__unused NSException *exception) {
            continue;
        }

        NSString *region=SSPRegionForFrame(frame,topLimit,bottomStart);
        if (!region) continue;

        NSString *className=NSStringFromClass(view.class) ?: @"?";
        BOOL isEffect=[view isKindOfClass:UIVisualEffectView.class];

        id filters=SSPSafeValue(view.layer,@"filters");
        id backgroundFilters=SSPSafeValue(view.layer,@"backgroundFilters");
        id compositingFilter=SSPSafeValue(view.layer,@"compositingFilter");

        BOOL layerEffect=
            ([filters respondsToSelector:@selector(count)] &&
             [filters count]>0) ||
            ([backgroundFilters respondsToSelector:@selector(count)] &&
             [backgroundFilters count]>0) ||
            compositingFilter!=nil;

        if (!isEffect &&
            !layerEffect &&
            !SSPSurfaceClassInteresting(className)) {
            continue;
        }

        NSString *effectClass=@"-";
        NSString *effectText=@"-";
        if (isEffect) {
            UIVisualEffect *effect=((UIVisualEffectView *)view).effect;
            effectClass=effect ? NSStringFromClass(effect.class) : @"nil";
            effectText=SSPText(effect);
        }

        SSPLog(@"SURFACE n=%lu region=%@ class=%@ ptr=%p frame=%@ alpha=%.3f hidden=%d bg=%@ tint=%@ effectClass=%@ effect=%@ filters=%@ backgroundFilters=%@ compositingFilter=%@ path=%@",
               (unsigned long)count++,
               region,
               className,
               view,
               NSStringFromCGRect(frame),
               view.alpha,
               view.hidden,
               SSPColor(view.backgroundColor),
               SSPColor(view.tintColor),
               effectClass,
               effectText,
               SSPText(filters),
               SSPText(backgroundFilters),
               SSPText(compositingFilter),
               SSPViewPath(view,window));

        [runtimeClasses addObject:className];
    }

    SSPLog(@"SURFACE_SUMMARY count=%lu classes=%@",
           (unsigned long)count,
           [[runtimeClasses allObjects]
                sortedArrayUsingSelector:@selector(compare:)]);

    for (NSString *name in
         [[runtimeClasses allObjects]
            sortedArrayUsingSelector:@selector(compare:)]) {
        SSPDumpRuntimeClassOnce(NSClassFromString(name));
    }

    SSPLog(@"========== SURFACE_SNAPSHOT_END reason=%@ ==========",
           reason ?: @"-");
}

static void SSPSnapshotCurrentScreen(NSString *reason) {
    UIWindow *window=SSPBestWindow();
    if (!window) {
        SSPLog(@"SURFACE_SNAPSHOT reason=%@ window=nil",reason ?: @"-");
        return;
    }
    SSPSnapshotSurface(window,reason);
}

#pragma mark - Screen monitor

static BOOL SSPWindowIsSettings(UIWindow *window) {
    if (!window) return NO;

    UIView *hit=[window hitTest:
        CGPointMake(CGRectGetMidX(window.bounds),
                    CGRectGetMidY(window.bounds))
                     withEvent:nil];

    if (hit && SSPResponderContains(hit,@"SurfaceScrollProbe")) return YES;
    if (hit && SSPResponderContains(hit,@"ModernSettingsViewController")) return YES;
    return NO;
}

static void SSPCheckScreenChange(void) {
    if (!gSSPScreenMonitorEnabled) return;

    UIWindow *window=SSPBestWindow();
    if (!window || SSPWindowIsSettings(window)) return;

    NSString *signature=SSPScreenSignature(window);
    if (!signature.length) return;

    if ([signature isEqualToString:gSSPLastScreenSignature]) return;

    gSSPLastScreenSignature=[signature copy];
    SSPLog(@"SCREEN_CHANGE signature=%@",signature);
    SSPSnapshotSurface(window,@"screen-change");
}

static void SSPScheduleScreenChangeCheck(void) {
    if (!gSSPScreenMonitorEnabled) return;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(0.28*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            SSPCheckScreenChange();
        });
}

#pragma mark - Tab Bar / scroll state

static BOOL SSPIsVisibleView(UIView *view, UIWindow *window) {
    if (!view || !window ||
        view.hidden ||
        view.alpha<=0.001 ||
        view.window!=window) {
        return NO;
    }

    CGRect frame=CGRectZero;
    @try {
        frame=[view convertRect:view.bounds toView:window];
    } @catch (__unused NSException *exception) {
        return NO;
    }

    return CGRectIntersectsRect(frame,window.bounds);
}

static void SSPLogTabBarViewState(UIView *bar,
                                  UIWindow *window,
                                  NSString *reason) {
    if (!bar || !window) return;

    CGRect frame=CGRectZero;
    @try {
        frame=[bar convertRect:bar.bounds toView:window];
    } @catch (__unused NSException *exception) {
        return;
    }

    CALayer *presentation=(CALayer *)bar.layer.presentationLayer;
    CGRect presentationFrame=
        presentation ? presentation.frame : CGRectNull;
    float presentationOpacity=
        presentation ? presentation.opacity : -1.0f;

    SSPLog(@"TABBAR_STATE reason=%@ class=%@ ptr=%p frameWindow=%@ bounds=%@ center=%@ alpha=%.4f hidden=%d transform=%@ presentationFrame=%@ presentationOpacity=%.4f super=%@ path=%@",
           reason ?: @"-",
           NSStringFromClass(bar.class),
           bar,
           NSStringFromCGRect(frame),
           NSStringFromCGRect(bar.bounds),
           NSStringFromCGPoint(bar.center),
           bar.alpha,
           bar.hidden,
           SSPTransform(bar.transform),
           NSStringFromCGRect(presentationFrame),
           presentationOpacity,
           bar.superview ? NSStringFromClass(bar.superview.class) : @"nil",
           SSPViewPath(bar,window));
}

static NSArray<UIScrollView *> *SSPRelevantScrollViews(UIWindow *window) {
    if (!window) return @[];

    NSArray<UIView *> *all=
        SSPSubviewsMatching(window,^BOOL(UIView *view) {
            return [view isKindOfClass:UIScrollView.class];
        });

    NSMutableArray<UIScrollView *> *result=[NSMutableArray array];

    for (UIScrollView *scroll in all) {
        if (!SSPIsVisibleView(scroll,window)) continue;

        CGRect frame=[scroll convertRect:scroll.bounds toView:window];

        BOOL meaningful =
            scroll.isDragging ||
            scroll.isDecelerating ||
            CGRectGetHeight(frame)>250.0 ||
            CGRectGetWidth(frame)>250.0;

        if (!meaningful) continue;
        [result addObject:scroll];
    }

    return result;
}

static void SSPLogScrollViewState(UIScrollView *scroll,
                                  UIWindow *window,
                                  NSString *reason) {
    if (!scroll || !window) return;

    CGRect frame=[scroll convertRect:scroll.bounds toView:window];
    UIPanGestureRecognizer *pan=scroll.panGestureRecognizer;

    CGPoint velocity=CGPointZero;
    CGPoint translation=CGPointZero;
    if (pan) {
        velocity=[pan velocityInView:window];
        translation=[pan translationInView:window];
    }

    id delegate=scroll.delegate;

    SSPLog(@"SCROLL_STATE reason=%@ class=%@ ptr=%p frame=%@ contentOffset=%@ contentSize=%@ inset=%@ adjustedInset=%@ dragging=%d decelerating=%d tracking=%d panState=%ld velocity=(%.1f,%.1f) translation=(%.1f,%.1f) delegate=%@ delegatePtr=%p path=%@",
           reason ?: @"-",
           NSStringFromClass(scroll.class),
           scroll,
           NSStringFromCGRect(frame),
           NSStringFromCGPoint(scroll.contentOffset),
           NSStringFromCGSize(scroll.contentSize),
           NSStringFromUIEdgeInsets(scroll.contentInset),
           NSStringFromUIEdgeInsets(scroll.adjustedContentInset),
           scroll.isDragging,
           scroll.isDecelerating,
           scroll.isTracking,
           (long)pan.state,
           velocity.x,velocity.y,
           translation.x,translation.y,
           delegate ? NSStringFromClass([delegate class]) : @"nil",
           delegate,
           SSPViewPath(scroll,window));

    if (delegate) SSPDumpRuntimeClassOnce([delegate class]);
}

static void SSPSampleGestureState(UIWindow *window,
                                  NSString *reason,
                                  CGPoint touchPoint) {
    if (!window) return;

    SSPLog(@"GESTURE_SAMPLE serial=%lu reason=%@ touch=(%.1f,%.1f) screen=%@",
           (unsigned long)gSSPGestureSerial,
           reason ?: @"-",
           touchPoint.x,touchPoint.y,
           SSPScreenSignature(window));

    NSArray<UIView *> *bars=
        SSPSubviewsNamed(window,@"XNavigation.TabBarView");

    if (bars.count==0) {
        SSPLog(@"TABBAR_STATE reason=%@ none-found",reason ?: @"-");
    }

    for (UIView *bar in bars) {
        SSPLogTabBarViewState(bar,window,reason);
        SSPDumpRuntimeClassOnce(bar.class);
    }

    Class tabControllerClass=NSClassFromString(@"XNavigation.TabBarController");
    SSPDumpRuntimeClassOnce(tabControllerClass);

    Class appNavClass=
        NSClassFromString(@"T1TwitterSwift.XTabbedAppNavigationViewController");
    SSPDumpRuntimeClassOnce(appNavClass);

    for (UIScrollView *scroll in SSPRelevantScrollViews(window)) {
        SSPLogScrollViewState(scroll,window,reason);
    }

    SSPDumpVisibleControllerRuntimeClasses(window);
}

static void SSPScheduleGestureTail(UIWindow *window,
                                   NSUInteger serial,
                                   CGPoint point) {
    NSArray<NSNumber *> *delays=@[@0.08,@0.25,@0.60];

    for (NSNumber *number in delays) {
        NSTimeInterval delay=number.doubleValue;
        __weak UIWindow *weakWindow=window;

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay*NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (serial!=gSSPGestureSerial) return;
                UIWindow *strongWindow=weakWindow;
                if (!strongWindow) return;

                SSPSampleGestureState(
                    strongWindow,
                    [NSString stringWithFormat:
                        @"tail+%.0fms",delay*1000.0],
                    point);
            });
    }
}

#pragma mark - Tab Bar mutation hooks

static BOOL SSPShouldLogTabBarMutation(id self) {
    return gSSPGestureActive &&
           [self isKindOfClass:UIView.class] &&
           [NSStringFromClass([self class])
               isEqualToString:@"XNavigation.TabBarView"];
}

static void SSPTabBarLayout(id self, SEL cmd) {
    if (gSSPOrigTabBarLayout) {
        ((void(*)(id,SEL))gSSPOrigTabBarLayout)(self,cmd);
    }

    if (SSPShouldLogTabBarMutation(self)) {
        UIView *view=(UIView *)self;
        UIWindow *window=view.window ?: SSPBestWindow();
        if (window) SSPLogTabBarViewState(view,window,@"hook-layout");
    }
}

static void SSPTabBarSetFrame(id self, SEL cmd, CGRect frame) {
    if (SSPShouldLogTabBarMutation(self)) {
        SSPLog(@"TABBAR_MUTATION selector=setFrame: requested=%@ ptr=%p",
               NSStringFromCGRect(frame),self);
    }

    if (gSSPOrigTabBarSetFrame) {
        ((void(*)(id,SEL,CGRect))gSSPOrigTabBarSetFrame)(self,cmd,frame);
    }
}

static void SSPTabBarSetCenter(id self, SEL cmd, CGPoint center) {
    if (SSPShouldLogTabBarMutation(self)) {
        SSPLog(@"TABBAR_MUTATION selector=setCenter: requested=%@ ptr=%p",
               NSStringFromCGPoint(center),self);
    }

    if (gSSPOrigTabBarSetCenter) {
        ((void(*)(id,SEL,CGPoint))gSSPOrigTabBarSetCenter)(
            self,cmd,center);
    }
}

static void SSPTabBarSetTransform(id self,
                                  SEL cmd,
                                  CGAffineTransform transform) {
    if (SSPShouldLogTabBarMutation(self)) {
        SSPLog(@"TABBAR_MUTATION selector=setTransform: requested=%@ ptr=%p",
               SSPTransform(transform),self);

        if ([self isKindOfClass:UIView.class]) {
            SSPLogTabBarTransformCallStack(
                (UIView *)self,
                transform);
        }
    }

    if (gSSPOrigTabBarSetTransform) {
        ((void(*)(id,SEL,CGAffineTransform))
            gSSPOrigTabBarSetTransform)(
                self,cmd,transform);
    }
}

static void SSPTabBarSetAlpha(id self, SEL cmd, CGFloat alpha) {
    if (SSPShouldLogTabBarMutation(self)) {
        SSPLog(@"TABBAR_MUTATION selector=setAlpha: requested=%.4f ptr=%p",
               alpha,self);
    }

    if (gSSPOrigTabBarSetAlpha) {
        ((void(*)(id,SEL,CGFloat))gSSPOrigTabBarSetAlpha)(
            self,cmd,alpha);
    }
}

static void SSPTabBarSetHidden(id self, SEL cmd, BOOL hidden) {
    if (SSPShouldLogTabBarMutation(self)) {
        SSPLog(@"TABBAR_MUTATION selector=setHidden: requested=%d ptr=%p",
               hidden,self);
    }

    if (gSSPOrigTabBarSetHidden) {
        ((void(*)(id,SEL,BOOL))gSSPOrigTabBarSetHidden)(
            self,cmd,hidden);
    }
}

static void SSPInstallTabBarHooks(void) {
    Class cls=NSClassFromString(@"XNavigation.TabBarView");
    if (!cls) return;

    if (!gSSPOrigTabBarLayout) {
        SSPHookInstanceMethod(
            cls,@selector(layoutSubviews),
            (IMP)SSPTabBarLayout,
            &gSSPOrigTabBarLayout);
    }

    if (!gSSPOrigTabBarSetFrame) {
        SSPHookInstanceMethod(
            cls,@selector(setFrame:),
            (IMP)SSPTabBarSetFrame,
            &gSSPOrigTabBarSetFrame);
    }

    if (!gSSPOrigTabBarSetCenter) {
        SSPHookInstanceMethod(
            cls,@selector(setCenter:),
            (IMP)SSPTabBarSetCenter,
            &gSSPOrigTabBarSetCenter);
    }

    if (!gSSPOrigTabBarSetTransform) {
        SSPHookInstanceMethod(
            cls,@selector(setTransform:),
            (IMP)SSPTabBarSetTransform,
            &gSSPOrigTabBarSetTransform);
    }

    if (!gSSPOrigTabBarSetAlpha) {
        SSPHookInstanceMethod(
            cls,@selector(setAlpha:),
            (IMP)SSPTabBarSetAlpha,
            &gSSPOrigTabBarSetAlpha);
    }

    if (!gSSPOrigTabBarSetHidden) {
        SSPHookInstanceMethod(
            cls,@selector(setHidden:),
            (IMP)SSPTabBarSetHidden,
            &gSSPOrigTabBarSetHidden);
    }
}

#pragma mark - Touch / gesture capture

static BOOL SSPShouldIgnoreTouch(UITouch *touch) {
    UIView *view=touch.view;
    if (!view) return YES;

    if (SSPResponderContains(view,@"SurfaceScrollProbe")) return YES;
    if (SSPResponderContains(view,@"ModernSettingsViewController")) return YES;
    if (SSPResponderContains(view,@"UIAlertController")) return YES;
    if (SSPResponderContains(view,@"XNavigation.TabBarView")) return YES;

    return touch.window==nil;
}

static UIScrollView *SSPScrollViewForTouch(UITouch *touch) {
    if (!touch || !touch.view) return nil;

    UIView *cursor=touch.view;
    for (NSUInteger depth=0; cursor && depth<80;
         depth++, cursor=cursor.superview) {

        if ([cursor isKindOfClass:UIScrollView.class]) {
            UIScrollView *scroll=(UIScrollView *)cursor;
            if (scroll.scrollEnabled &&
                scroll.userInteractionEnabled &&
                !scroll.hidden &&
                scroll.alpha>0.01) {
                return scroll;
            }
        }
    }

    return nil;
}

static UITouch *SSPPrimaryTouch(UIEvent *event) {
    for (UITouch *touch in event.allTouches ?: [NSSet set]) {
        if (SSPShouldIgnoreTouch(touch)) continue;
        return touch;
    }
    return nil;
}

static void SSPUIApplicationSendEvent(id self,
                                      SEL cmd,
                                      UIEvent *event) {
    UITouch *touch=nil;
    if (event.type==UIEventTypeTouches) {
        touch=SSPPrimaryTouch(event);
    }

    UIScrollView *armedScroll=nil;
    BOOL startGesture=NO;

    if (gSSPGestureArmed &&
        !gSSPGestureActive &&
        touch &&
        touch.phase==UITouchPhaseMoved) {

        armedScroll=SSPScrollViewForTouch(touch);
        startGesture=(armedScroll!=nil);
    }

    if (startGesture) {
        gSSPGestureArmed=NO;
        gSSPGestureActive=YES;
        gSSPGestureSerial++;
        gSSPLastGestureSample=0;

        UIWindow *window=touch.window;
        CGPoint point=[touch locationInView:window];

        SSPLog(@"========== GESTURE_BEGIN serial=%lu ==========",
               (unsigned long)gSSPGestureSerial);
        SSPLog(@"GESTURE_SCROLL_BEGIN touchClass=%@ touchPtr=%p scrollClass=%@ scrollPtr=%p point=(%.1f,%.1f) responderPath=%@",
               touch.view ? NSStringFromClass(touch.view.class) : @"nil",
               touch.view,
               NSStringFromClass(armedScroll.class),
               armedScroll,
               point.x,point.y,
               touch.view ? SSPResponderPath(touch.view) : @"-");

        SSPLogScrollViewState(
            armedScroll,
            window,
            @"armed-target-before-original");

        SSPDumpNativeCollapseContext(
            window,
            @"gesture-begin-before-original");

        SSPSampleGestureState(window,@"begin-before-original",point);
    }

    if (gSSPOrigUIApplicationSendEvent) {
        ((void(*)(id,SEL,UIEvent *))
            gSSPOrigUIApplicationSendEvent)(self,cmd,event);
    }

    if (touch && gSSPGestureActive) {
        UIWindow *window=touch.window ?: SSPBestWindow();
        CGPoint point=window ? [touch locationInView:window] : CGPointZero;

        if (touch.phase==UITouchPhaseMoved) {
            NSTimeInterval now=CACurrentMediaTime();
            if (now-gSSPLastGestureSample>=0.055) {
                gSSPLastGestureSample=now;
                SSPSampleGestureState(window,@"move",point);
            }
        }

        if (touch.phase==UITouchPhaseEnded ||
            touch.phase==UITouchPhaseCancelled) {

            SSPSampleGestureState(
                window,
                touch.phase==UITouchPhaseEnded ? @"end" : @"cancel",
                point);

            NSUInteger serial=gSSPGestureSerial;
            SSPScheduleGestureTail(window,serial,point);

            gSSPGestureActive=NO;

            SSPLog(@"========== GESTURE_END serial=%lu phase=%ld ==========",
                   (unsigned long)serial,
                   (long)touch.phase);
        }
    }

    if (touch && touch.phase==UITouchPhaseEnded) {
        SSPScheduleScreenChangeCheck();
    }
}

static void SSPInstallRuntimeHooks(void) {
    if (!gSSPOrigUIApplicationSendEvent) {
        SSPHookInstanceMethod(
            UIApplication.class,
            @selector(sendEvent:),
            (IMP)SSPUIApplicationSendEvent,
            &gSSPOrigUIApplicationSendEvent);
    }

    SSPInstallTabBarHooks();

    SSPLog(@"HOOK_STATUS sendEvent=%d tabLayout=%d setFrame=%d setCenter=%d setTransform=%d setAlpha=%d setHidden=%d",
           gSSPOrigUIApplicationSendEvent!=NULL,
           gSSPOrigTabBarLayout!=NULL,
           gSSPOrigTabBarSetFrame!=NULL,
           gSSPOrigTabBarSetCenter!=NULL,
           gSSPOrigTabBarSetTransform!=NULL,
           gSSPOrigTabBarSetAlpha!=NULL,
           gSSPOrigTabBarSetHidden!=NULL);
}

#pragma mark - NFB UI

@interface XLiquidGlassSurfaceScrollProbeViewController : UITableViewController
@end

@implementation XLiquidGlassSurfaceScrollProbeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"2.1 Native Collapse Probe";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section==0 ? 4 : 3;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section==0 ? @"Captura" : @"Relatório";
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    (void)tableView;

    if (section==0) {
        return @"Arme um gesto na Home e faça um scroll que esconda a Tab Bar. Depois arme novamente e repita em uma tela onde ela não esconde. Compare NATIVE_COLLAPSE_CONTEXT e TABBAR_TRANSFORM_CALLSTACK.";
    }
    return @"O probe apenas observa. Registra collapseEngine, capacidades tfn_* e a call stack do primeiro setTransform da Tab Bar. Não altera a Tab Bar.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    static NSString *identifier=@"SSPCell";
    UITableViewCell *cell=
        [tableView dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {
        cell=[[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
          reuseIdentifier:identifier];
    }

    cell.textLabel.text=nil;
    cell.detailTextLabel.text=nil;
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle=UITableViewCellSelectionStyleDefault;

    if (indexPath.section==0) {
        if (indexPath.row==0) {
            cell.textLabel.text=@"Estado";
            cell.detailTextLabel.text=
                [NSString stringWithFormat:
                    @"Telas: %@ · Gesto: %@",
                    gSSPScreenMonitorEnabled ? @"monitorando" : @"desativado",
                    gSSPGestureArmed
                        ? @"armado"
                        : (gSSPGestureActive ? @"gravando" : @"pronto")];
            cell.accessoryType=UITableViewCellAccessoryNone;
            cell.selectionStyle=UITableViewCellSelectionStyleNone;
        } else if (indexPath.row==1) {
            cell.textLabel.text=
                gSSPScreenMonitorEnabled
                    ? @"Parar de monitorar telas"
                    : @"Monitorar telas";
            cell.detailTextLabel.text=
                @"Registra blur/material quando a tela visível muda.";
        } else if (indexPath.row==2) {
            cell.textLabel.text=@"Gravar próximo gesto de scroll";
            cell.detailTextLabel.text=
                @"Só começa ao detectar movimento real dentro de um UIScrollView.";
        } else {
            cell.textLabel.text=@"Snapshot agora";
            cell.detailTextLabel.text=
                @"Mapeia blur/material da tela atualmente visível.";
        }
    } else {
        if (indexPath.row==0) {
            cell.textLabel.text=@"Nova sessão";
            cell.detailTextLabel.text=
                @"Limpa o log e reinicia os marcadores.";
        } else if (indexPath.row==1) {
            cell.textLabel.text=@"Copiar relatório";
            cell.detailTextLabel.text=kSSPLogFileName;
        } else {
            cell.textLabel.text=@"Limpar relatório";
            cell.detailTextLabel.text=
                @"Apaga o relatório sem iniciar nova sessão.";
        }
    }

    return cell;
}

- (void)showInfo:(NSString *)message {
    UIAlertController *alert=
        [UIAlertController
            alertControllerWithTitle:@"2.1 Native Collapse Probe"
                             message:message
                      preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:
        [UIAlertAction actionWithTitle:@"OK"
                                 style:UIAlertActionStyleDefault
                               handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)reloadState {
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {

    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section==0) {
        if (indexPath.row==0) return;

        if (indexPath.row==1) {
            gSSPScreenMonitorEnabled=!gSSPScreenMonitorEnabled;
            gSSPLastScreenSignature=nil;

            SSPLog(@"SCREEN_MONITOR enabled=%d",
                   gSSPScreenMonitorEnabled);

            if (gSSPScreenMonitorEnabled) {
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(0.15*NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        SSPCheckScreenChange();
                    });
            }

            [self reloadState];
            return;
        }

        if (indexPath.row==2) {
            gSSPGestureArmed=YES;
            gSSPGestureActive=NO;
            gSSPGestureSerial++;

            SSPLog(@"GESTURE_ARMED serialSeed=%lu",
                   (unsigned long)gSSPGestureSerial);

            [self reloadState];
            [self showInfo:
                @"Gesto armado. Faça um scroll vertical. Primeiro capture a Home, onde o hide é nativo; depois arme novamente e capture uma tela sem hide."];
            return;
        }

        SSPSnapshotCurrentScreen(@"manual-NFB");
        return;
    }

    if (indexPath.row==0) {
        gSSPScreenMonitorEnabled=NO;
        gSSPGestureArmed=NO;
        gSSPGestureActive=NO;
        gSSPGestureSerial++;
        gSSPLastScreenSignature=nil;
        gSSPLastTransformStackSerial=NSNotFound;
        [gSSPDumpedRuntimeClasses removeAllObjects];
        [gSSPDumpedCollapseClasses removeAllObjects];

        [[NSFileManager defaultManager]
            removeItemAtPath:SSPLogPath()
                       error:nil];

        SSPLog(@"========== NEW SESSION ==========");
        SSPLog(@"logPath=%@",SSPLogPath());
        SSPLog(@"INSTRUCTION record-home-native-collapse-then-target-without-hide");

        [self reloadState];
        [self showInfo:
            @"Nova sessão iniciada. Grave um gesto na Home e depois outro em uma tela onde a Tab Bar não esconde."];
        return;
    }

    if (indexPath.row==1) {
        NSString *report=
            [NSString stringWithContentsOfFile:SSPLogPath()
                                      encoding:NSUTF8StringEncoding
                                         error:nil] ?: @"";

        UIPasteboard.generalPasteboard.string=report;

        [self showInfo:
            [NSString stringWithFormat:
                @"Relatório copiado (%lu caracteres).",
                (unsigned long)report.length]];
        return;
    }

    gSSPScreenMonitorEnabled=NO;
    gSSPGestureArmed=NO;
    gSSPGestureActive=NO;
    gSSPGestureSerial++;
    gSSPLastScreenSignature=nil;

    [[NSFileManager defaultManager]
        removeItemAtPath:SSPLogPath()
                   error:nil];

    SSPLog(@"LOG RESET");
    [self reloadState];
}

@end

static BOOL SSPSectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"action"]
                isEqualToString:@"showXLiquidGlassSurfaceScrollProbe"]) {
            return YES;
        }
    }
    return NO;
}

static void SSPInjectNFBSection(id controller) {
    NSArray *sections=nil;

    @try {
        sections=[controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        return;
    }

    if (![sections isKindOfClass:NSArray.class] ||
        SSPSectionsContainEntry(sections)) {
        return;
    }

    NSMutableArray *updated=[sections mutableCopy];
    [updated addObject:@{
        @"title": @"2.1 Native Collapse Probe",
        @"subtitle": @"Descobre o collapseEngine nativo da Tab Bar.",
        @"icon": @"waveform.path.ecg",
        @"action": @"showXLiquidGlassSurfaceScrollProbe"
    }];

    @try {
        [controller setValue:[updated copy] forKey:@"sections"];
    } @catch (__unused NSException *exception) {
    }
}

static void SSPNFBSetupSections(id self, SEL cmd) {
    if (gSSPOrigNFBSetupSections) {
        ((void(*)(id,SEL))gSSPOrigNFBSetupSections)(self,cmd);
    }
    SSPInjectNFBSection(self);
}

static void SSPNFBViewWillAppear(id self,
                                 SEL cmd,
                                 BOOL animated) {
    if (gSSPOrigNFBViewWillAppear) {
        ((void(*)(id,SEL,BOOL))
            gSSPOrigNFBViewWillAppear)(self,cmd,animated);
    }

    SSPInjectNFBSection(self);

    UITableView *tableView=nil;
    @try {
        tableView=[self valueForKey:@"tableView"];
    } @catch (__unused NSException *exception) {
    }
    [tableView reloadData];
}

static void SSPShowSettings(id self, SEL cmd) {
    (void)cmd;
    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassSurfaceScrollProbeViewController *vc=
        [XLiquidGlassSurfaceScrollProbeViewController new];

    UINavigationController *nav=
        ((UIViewController *)self).navigationController;

    if (nav) {
        [nav pushViewController:vc animated:YES];
    } else {
        UINavigationController *wrapper=
            [[UINavigationController alloc]
                initWithRootViewController:vc];
        [(UIViewController *)self
            presentViewController:wrapper
                         animated:YES
                       completion:nil];
    }
}

static void SSPInstallNFBIntegration(void) {
    Class cls=NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;

    class_addMethod(
        cls,
        NSSelectorFromString(@"showXLiquidGlassSurfaceScrollProbe"),
        (IMP)SSPShowSettings,
        "v@:");

    if (!gSSPOrigNFBSetupSections) {
        SSPHookInstanceMethod(
            cls,
            NSSelectorFromString(@"setupSections"),
            (IMP)SSPNFBSetupSections,
            &gSSPOrigNFBSetupSections);
    }

    if (!gSSPOrigNFBViewWillAppear) {
        SSPHookInstanceMethod(
            cls,
            @selector(viewWillAppear:),
            (IMP)SSPNFBViewWillAppear,
            &gSSPOrigNFBViewWillAppear);
    }
}

#pragma mark - Install

static void SSPInstallAll(void) {
    SSPInstallRuntimeHooks();
    SSPInstallNFBIntegration();
}

static void SSPRetry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(delay*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            SSPInstallAll();
        });
}

__attribute__((constructor))
static void XLiquidGlassSurfaceScrollProbeInit(void) {
    @autoreleasepool {
        if (!gSSPDumpedRuntimeClasses) {
            gSSPDumpedRuntimeClasses=[NSMutableSet set];
        }

        SSPLog(@"========== XLiquidGlass 2.1 Native Collapse Probe 0.4.0 loaded ==========");
        SSPLog(@"logPath=%@",SSPLogPath());

        SSPInstallAll();

        SSPRetry(0.05);
        SSPRetry(0.20);
        SSPRetry(0.50);
        SSPRetry(1.00);
        SSPRetry(2.00);
        SSPRetry(4.00);
    }
}
