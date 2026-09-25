#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kXBPLogFileName = @"XLiquidGlassBadgeProbe.log";
static const NSUInteger kXBPMaxLogBytes = 4 * 1024 * 1024;

#pragma mark - Original IMPs

static IMP gOrigT1SetBadgeCount = NULL;
static IMP gOrigT1SetBadgeCountAnimated = NULL;
static IMP gOrigT1UpdateBadgeContent = NULL;
static IMP gOrigT1SizeBadge = NULL;
static IMP gOrigT1LayoutBadge = NULL;
static IMP gOrigT1LayoutBadgeMax = NULL;
static IMP gOrigT1LayoutBadgeMin = NULL;

static IMP gOrigXNavItemLayout = NULL;
static IMP gOrigXNavItemDidMoveToWindow = NULL;
static IMP gOrigXNavItemSetA11yLabel = NULL;
static IMP gOrigXNavItemSetA11yValue = NULL;

static IMP gOrigXNavBarLayout = NULL;
static IMP gOrigXNavControllerLayout = NULL;

static IMP gOrigUITabBarItemSetBadgeValue = NULL;

static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;

#pragma mark - State

static BOOL gT1HooksInstalled = NO;
static BOOL gXNavItemHooksInstalled = NO;
static BOOL gXNavBarHooksInstalled = NO;
static BOOL gXNavControllerHooksInstalled = NO;
static BOOL gUITabBarItemHookInstalled = NO;
static BOOL gNFBHookInstalled = NO;

static NSUInteger gCaptureCount = 0;
static char kXBPLastItemSignatureKey;
static char kXBPLastBarSignatureKey;

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
    if (s.length > 500) s = [[s substringToIndex:500] stringByAppendingString:@"…"];
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
    NSLog(@"[XLiquidGlassBadgeProbe] %@", body ?: @"");

    @synchronized([NSFileManager defaultManager]) {
        NSString *path = XBPLogPath();
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [@"" writeToFile:path
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:nil];
        }

        NSFileHandle *handle =
            [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }

        XBPTrimLogIfNeeded();
    }
}

#pragma mark - Runtime helpers

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

static Class XBPClassByAnyName(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (cls) return cls;
    }

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;

    Class *classes =
        (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);

    Class result = Nil;
    for (int i = 0; i < count && !result; i++) {
        NSString *actual = NSStringFromClass(classes[i]);
        for (NSString *candidate in names) {
            if ([actual isEqualToString:candidate]) {
                result = classes[i];
                break;
            }
        }
    }

    free(classes);
    return result;
}

static NSArray<Class> *XBPClassesWithNameFragments(NSArray<NSString *> *fragments) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return @[];

    Class *classes =
        (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);

    NSMutableArray *result = [NSMutableArray array];

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls);
        NSString *lower = name.lowercaseString;

        BOOL match = NO;
        for (NSString *fragment in fragments) {
            if ([lower containsString:fragment.lowercaseString]) {
                match = YES;
                break;
            }
        }

        if (match) [result addObject:cls];
    }

    free(classes);
    return result;
}

static void XBPDumpClassMetadata(Class cls, BOOL includeAllMethods) {
    if (!cls) return;

    NSString *name = NSStringFromClass(cls);
    XBPLog(@"CLASS_DUMP_BEGIN %@", name);

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *ivarName = ivar_getName(ivars[i]);
        const char *type = ivar_getTypeEncoding(ivars[i]);
        ptrdiff_t offset = ivar_getOffset(ivars[i]);

        XBPLog(@"IVAR %@ name=%s type=%s offset=%td",
               name,
               ivarName ?: "-",
               type ?: "-",
               offset);
    }
    free(ivars);

    unsigned int propertyCount = 0;
    objc_property_t *properties =
        class_copyPropertyList(cls, &propertyCount);

    for (unsigned int i = 0; i < propertyCount; i++) {
        const char *propertyName = property_getName(properties[i]);
        const char *attributes = property_getAttributes(properties[i]);
        XBPLog(@"PROPERTY %@ name=%s attrs=%s",
               name,
               propertyName ?: "-",
               attributes ?: "-");
    }
    free(properties);

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);

    for (unsigned int i = 0; i < methodCount; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *selectorName = NSStringFromSelector(sel);
        NSString *lower = selectorName.lowercaseString;

        BOOL interesting =
            [lower containsString:@"badge"] ||
            [lower containsString:@"count"] ||
            [lower containsString:@"item"] ||
            [lower containsString:@"tab"] ||
            [lower containsString:@"model"] ||
            [lower containsString:@"state"] ||
            [lower containsString:@"update"] ||
            [lower containsString:@"configure"] ||
            [lower containsString:@"layout"] ||
            [lower containsString:@"accessibility"] ||
            [lower containsString:@"selected"] ||
            [lower containsString:@"notification"] ||
            [lower containsString:@"unread"] ||
            [lower containsString:@"value"];

        if (!includeAllMethods && !interesting) continue;

        const char *types = method_getTypeEncoding(methods[i]);
        XBPLog(@"METHOD %@ selector=%@ types=%s",
               name,
               selectorName,
               types ?: "-");
    }

    free(methods);
    XBPLog(@"CLASS_DUMP_END %@", name);
}

static void XBPDumpObjectIvars(id object, NSString *label) {
    if (!object) {
        XBPLog(@"OBJECT_IVARS %@ object=nil", label);
        return;
    }

    Class cls = object_getClass(object);
    XBPLog(@"OBJECT_IVARS_BEGIN %@ ptr=%p class=%@",
           label,
           object,
           NSStringFromClass(cls));

    for (Class current = cls;
         current && current != NSObject.class;
         current = class_getSuperclass(current)) {

        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);

        for (unsigned int i = 0; i < count; i++) {
            Ivar ivar = ivars[i];
            const char *name = ivar_getName(ivar);
            const char *type = ivar_getTypeEncoding(ivar);

            if (type && type[0] == '@') {
                id value = nil;
                @try {
                    value = object_getIvar(object, ivar);
                } @catch (__unused NSException *exception) {
                }

                XBPLog(@"OBJECT_IVAR %@ owner=%@ name=%s type=%s valueClass=%@ value=%@",
                       label,
                       NSStringFromClass(current),
                       name ?: "-",
                       type ?: "-",
                       value ? NSStringFromClass([value class]) : @"nil",
                       XBPText(value));
            } else {
                XBPLog(@"OBJECT_IVAR %@ owner=%@ name=%s type=%s value=<scalar>",
                       label,
                       NSStringFromClass(current),
                       name ?: "-",
                       type ?: "-");
            }
        }

        free(ivars);
    }

    XBPLog(@"OBJECT_IVARS_END %@", label);
}

#pragma mark - Window / controller traversal

static NSArray<UIWindow *> *XBPAllWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;

        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window) [windows addObject:window];
        }
    }

    return windows;
}

static UIWindow *XBPActiveWindow(void) {
    UIWindow *fallback = nil;

    for (UIWindow *window in XBPAllWindows()) {
        if (!fallback && !window.hidden) fallback = window;
        if (window.isKeyWindow) return window;
    }

    return fallback;
}

static NSArray<UIViewController *> *XBPControllerHierarchy(void) {
    NSMutableArray<UIViewController *> *queue = [NSMutableArray array];

    for (UIWindow *window in XBPAllWindows()) {
        if (window.rootViewController)
            [queue addObject:window.rootViewController];
    }

    NSMutableArray<UIViewController *> *result = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];

    for (NSUInteger i = 0; i < queue.count && i < 768; i++) {
        UIViewController *vc = queue[i];
        if (!vc) continue;

        NSValue *key = [NSValue valueWithNonretainedObject:vc];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [result addObject:vc];

        if (vc.presentedViewController)
            [queue addObject:vc.presentedViewController];
        if (vc.presentingViewController)
            [queue addObject:vc.presentingViewController];
        if (vc.parentViewController)
            [queue addObject:vc.parentViewController];

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

static BOOL XBPControllerLooksRelevant(UIViewController *vc) {
    if (!vc) return NO;

    NSString *name = NSStringFromClass(vc.class);
    NSString *lower = name.lowercaseString;

    if ([lower containsString:@"liquid"] ||
        [lower containsString:@"tabbar"] ||
        [lower containsString:@"xnavigation"]) {
        return YES;
    }

    return [vc respondsToSelector:NSSelectorFromString(@"tabBar")] ||
           [vc respondsToSelector:NSSelectorFromString(@"tabViews")] ||
           [vc respondsToSelector:NSSelectorFromString(@"syncBadges")] ||
           [vc respondsToSelector:NSSelectorFromString(@"_t1_syncTabBarItems")];
}

static void XBPDumpControllerHierarchy(void) {
    NSArray<UIViewController *> *controllers = XBPControllerHierarchy();

    XBPLog(@"VC_SCAN_BEGIN count=%lu", (unsigned long)controllers.count);

    NSUInteger index = 0;
    for (UIViewController *vc in controllers) {
        if (!XBPControllerLooksRelevant(vc)) {
            index++;
            continue;
        }

        XBPLog(@"VC[%lu] class=%@ ptr=%p loaded=%d parent=%@ nav=%@ presented=%@ selectors(tabBar=%d tabViews=%d syncBadges=%d syncItems=%d)",
               (unsigned long)index,
               NSStringFromClass(vc.class),
               vc,
               vc.isViewLoaded,
               NSStringFromClass(vc.parentViewController.class),
               NSStringFromClass(vc.navigationController.class),
               NSStringFromClass(vc.presentedViewController.class),
               [vc respondsToSelector:NSSelectorFromString(@"tabBar")],
               [vc respondsToSelector:NSSelectorFromString(@"tabViews")],
               [vc respondsToSelector:NSSelectorFromString(@"syncBadges")],
               [vc respondsToSelector:NSSelectorFromString(@"_t1_syncTabBarItems")]);

        index++;
    }

    XBPLog(@"VC_SCAN_END");
}

static UIViewController *XBPFindPrimaryTabController(void) {
    NSArray<UIViewController *> *controllers = XBPControllerHierarchy();

    Class xnav = XBPClassByAnyName(@[
        @"_TtC11XNavigation16TabBarController",
        @"XNavigation.TabBarController"
    ]);

    for (UIViewController *vc in controllers) {
        if (xnav && [vc isKindOfClass:xnav]) return vc;
    }

    Class legacy = NSClassFromString(@"T1TabBarViewController");
    for (UIViewController *vc in controllers) {
        if (legacy && [vc isKindOfClass:legacy]) return vc;
    }

    for (UIViewController *vc in controllers) {
        if ([vc respondsToSelector:NSSelectorFromString(@"tabBar")] ||
            [vc respondsToSelector:NSSelectorFromString(@"tabViews")]) {
            return vc;
        }
    }

    return nil;
}

#pragma mark - View traversal / snapshots

static UIView *XBPFindViewByClassNames(UIView *root,
                                       NSArray<NSString *> *classNames) {
    if (!root) return nil;

    NSMutableArray<UIView *> *queue =
        [NSMutableArray arrayWithObject:root];

    for (NSUInteger i = 0; i < queue.count && i < 4096; i++) {
        UIView *view = queue[i];
        NSString *name = NSStringFromClass(view.class);

        for (NSString *candidate in classNames) {
            if ([name isEqualToString:candidate]) return view;
        }

        [queue addObjectsFromArray:view.subviews ?: @[]];
    }

    return nil;
}

static NSArray<UIView *> *XBPFindViewsMatching(UIView *root,
                                               BOOL (^predicate)(UIView *view)) {
    if (!root || !predicate) return @[];

    NSMutableArray<UIView *> *result = [NSMutableArray array];
    NSMutableArray<UIView *> *queue =
        [NSMutableArray arrayWithObject:root];

    for (NSUInteger i = 0; i < queue.count && i < 4096; i++) {
        UIView *view = queue[i];

        if (predicate(view)) [result addObject:view];
        [queue addObjectsFromArray:view.subviews ?: @[]];
    }

    return result;
}

static NSString *XBPSubviewSignature(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    for (UIView *subview in view.subviews ?: @[]) {
        [parts addObject:
            [NSString stringWithFormat:@"%@:%@:%d:%.2f",
             NSStringFromClass(subview.class),
             NSStringFromCGRect(subview.frame),
             subview.hidden,
             subview.alpha]];
    }

    return [parts componentsJoinedByString:@"|"];
}

static void XBPDumpSingleView(UIView *view,
                              UIView *root,
                              NSString *path) {
    if (!view) return;

    CGRect frame = [view convertRect:view.bounds toView:root ?: view];

    NSMutableArray<NSString *> *extra = [NSMutableArray array];

    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        [extra addObject:
            [NSString stringWithFormat:@"text=%@ font=%.2f color=%@",
             XBPText(label.text),
             label.font.pointSize,
             XBPText(label.textColor)]];
    }

    if ([view isKindOfClass:UIImageView.class]) {
        UIImageView *image = (UIImageView *)view;
        [extra addObject:
            [NSString stringWithFormat:@"image=%@ tint=%@ mode=%ld",
             XBPText(image.image),
             XBPText(image.tintColor),
             (long)image.image.renderingMode]];
    }

    if ([view isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)view;
        [extra addObject:
            [NSString stringWithFormat:@"selected=%d highlighted=%d enabled=%d",
             control.selected,
             control.highlighted,
             control.enabled]];
    }

    XBPLog(@"VIEW %@ ptr=%p class=%@ frame=%@ hidden=%d alpha=%.3f a11yLabel=%@ a11yValue=%@ a11yId=%@ traits=%llu corner=%.2f %@",
           path,
           view,
           NSStringFromClass(view.class),
           NSStringFromCGRect(frame),
           view.hidden,
           view.alpha,
           XBPText(view.accessibilityLabel),
           XBPText(view.accessibilityValue),
           XBPText(view.accessibilityIdentifier),
           (unsigned long long)view.accessibilityTraits,
           view.layer.cornerRadius,
           extra.count ? [extra componentsJoinedByString:@" "] : @"");
}

static void XBPDumpViewTree(UIView *view,
                            UIView *root,
                            NSUInteger depth,
                            NSString *path,
                            NSUInteger *nodeCount) {
    if (!view || depth > 12 || !nodeCount || *nodeCount > 2500) return;

    (*nodeCount)++;
    XBPDumpSingleView(view, root, path);

    NSUInteger index = 0;
    for (UIView *subview in view.subviews ?: @[]) {
        XBPDumpViewTree(subview,
                        root,
                        depth + 1,
                        [path stringByAppendingFormat:@"/%lu",
                         (unsigned long)index++],
                        nodeCount);
    }
}

static void XBPDumpT1TabViewSnapshot(id tabView, NSString *event) {
    if (!tabView) return;

    NSUInteger badgeCount = 0;
    SEL badgeCountSEL = NSSelectorFromString(@"badgeCount");
    if ([tabView respondsToSelector:badgeCountSEL]) {
        badgeCount =
            ((NSUInteger(*)(id,SEL))objc_msgSend)(tabView, badgeCountSEL);
    }

    id badgeView = nil;
    SEL badgeViewSEL = NSSelectorFromString(@"badgeView");
    if ([tabView respondsToSelector:badgeViewSEL]) {
        badgeView = ((id(*)(id,SEL))objc_msgSend)(tabView, badgeViewSEL);
    }

    XBPLog(@"T1_SNAPSHOT event=%@ ptr=%p class=%@ a11yLabel=%@ a11yId=%@ badgeCount=%lu badgeViewClass=%@ badgeFrame=%@ badgeHidden=%@ badgeAlpha=%@",
           event,
           tabView,
           NSStringFromClass([tabView class]),
           XBPText([tabView accessibilityLabel]),
           XBPText([tabView accessibilityIdentifier]),
           (unsigned long)badgeCount,
           badgeView ? NSStringFromClass([badgeView class]) : @"nil",
           [badgeView isKindOfClass:UIView.class]
                ? NSStringFromCGRect(((UIView *)badgeView).frame) : @"-",
           [badgeView isKindOfClass:UIView.class]
                ? (((UIView *)badgeView).hidden ? @"1" : @"0") : @"-",
           [badgeView isKindOfClass:UIView.class]
                ? [NSString stringWithFormat:@"%.3f", ((UIView *)badgeView).alpha] : @"-");
}

static void XBPDumpXNavItemSnapshot(UIView *item, NSString *event) {
    if (!item) return;

    XBPLog(@"XNAV_ITEM event=%@ ptr=%p class=%@ frame=%@ label=%@ value=%@ id=%@ traits=%llu subviews=%lu signature=%@",
           event,
           item,
           NSStringFromClass(item.class),
           NSStringFromCGRect(item.frame),
           XBPText(item.accessibilityLabel),
           XBPText(item.accessibilityValue),
           XBPText(item.accessibilityIdentifier),
           (unsigned long long)item.accessibilityTraits,
           (unsigned long)item.subviews.count,
           XBPSubviewSignature(item));

    NSUInteger index = 0;
    for (UIView *subview in item.subviews ?: @[]) {
        XBPDumpSingleView(subview,
                          item.superview ?: item,
                          [NSString stringWithFormat:@"xnavItem/%lu",
                           (unsigned long)index++]);
    }
}

static void XBPDumpVisibleTabInfrastructure(NSString *event) {
    XBPLog(@"TAB_INFRA_BEGIN event=%@", event);

    NSUInteger windowIndex = 0;
    for (UIWindow *window in XBPAllWindows()) {
        XBPLog(@"WINDOW[%lu] ptr=%p class=%@ key=%d hidden=%d alpha=%.3f frame=%@ root=%@",
               (unsigned long)windowIndex++,
               window,
               NSStringFromClass(window.class),
               window.isKeyWindow,
               window.hidden,
               window.alpha,
               NSStringFromCGRect(window.frame),
               NSStringFromClass(window.rootViewController.class));

        NSArray<UIView *> *matches =
            XBPFindViewsMatching(window, ^BOOL(UIView *view) {
                NSString *name = NSStringFromClass(view.class);
                return [name isEqualToString:@"XNavigation.TabBarView"] ||
                       [name isEqualToString:@"XNavigation.TabBarItemView"] ||
                       [name isEqualToString:@"XNavigation.TabBarPill"] ||
                       [name isEqualToString:@"T1TabView"] ||
                       [name isEqualToString:@"TFNBadgeView"] ||
                       [name isEqualToString:@"TFNCustomTabBar"];
            });

        for (UIView *view in matches) {
            XBPLog(@"INFRA_MATCH ptr=%p class=%@ frameInWindow=%@ hidden=%d alpha=%.3f label=%@ value=%@ id=%@",
                   view,
                   NSStringFromClass(view.class),
                   NSStringFromCGRect([view convertRect:view.bounds toView:window]),
                   view.hidden,
                   view.alpha,
                   XBPText(view.accessibilityLabel),
                   XBPText(view.accessibilityValue),
                   XBPText(view.accessibilityIdentifier));

            if ([NSStringFromClass(view.class) isEqualToString:@"T1TabView"]) {
                XBPDumpT1TabViewSnapshot(view, event);
            }

            if ([NSStringFromClass(view.class)
                    isEqualToString:@"XNavigation.TabBarItemView"]) {
                XBPDumpXNavItemSnapshot(view, event);
            }
        }
    }

    XBPLog(@"TAB_INFRA_END event=%@", event);
}

#pragma mark - Focused runtime scan

static void XBPDumpFocusedRuntime(void) {
    NSArray<Class> *classes =
        XBPClassesWithNameFragments(@[
            @"xnavigation",
            @"t1tab",
            @"tfnbadge",
            @"customtab",
            @"liquidglass"
        ]);

    XBPLog(@"FOCUSED_RUNTIME_BEGIN classes=%lu",
           (unsigned long)classes.count);

    for (Class cls in classes) {
        NSString *name = NSStringFromClass(cls);
        NSString *lower = name.lowercaseString;

        BOOL allMethods =
            [lower containsString:@"xnavigation.tabbaritemview"] ||
            [lower containsString:@"xnavigation.tabbarview"] ||
            [lower containsString:@"xnavigation.tabbarcontroller"] ||
            [lower isEqualToString:@"t1tabview"] ||
            [lower isEqualToString:@"tfnbadgeview"];

        XBPDumpClassMetadata(cls, allMethods);
    }

    XBPLog(@"FOCUSED_RUNTIME_END");
}

#pragma mark - T1TabView hooks

static void XBPT1SetBadgeCount(id self, SEL cmd, NSUInteger count) {
    NSUInteger old = 0;
    if ([self respondsToSelector:NSSelectorFromString(@"badgeCount")]) {
        old = ((NSUInteger(*)(id,SEL))objc_msgSend)(
            self, NSSelectorFromString(@"badgeCount"));
    }

    XBPLog(@"T1_SET_BADGE_COUNT ptr=%p id=%@ label=%@ old=%lu new=%lu",
           self,
           XBPText([self accessibilityIdentifier]),
           XBPText([self accessibilityLabel]),
           (unsigned long)old,
           (unsigned long)count);

    if (gOrigT1SetBadgeCount) {
        ((void(*)(id,SEL,NSUInteger))gOrigT1SetBadgeCount)(
            self, cmd, count);
    }

    XBPDumpT1TabViewSnapshot(self, @"setBadgeCount:after");
}

static void XBPT1SetBadgeCountAnimated(id self,
                                       SEL cmd,
                                       NSUInteger count,
                                       BOOL animated) {
    NSUInteger old = 0;
    if ([self respondsToSelector:NSSelectorFromString(@"badgeCount")]) {
        old = ((NSUInteger(*)(id,SEL))objc_msgSend)(
            self, NSSelectorFromString(@"badgeCount"));
    }

    XBPLog(@"T1_SET_BADGE_COUNT_ANIMATED ptr=%p id=%@ label=%@ old=%lu new=%lu animated=%d",
           self,
           XBPText([self accessibilityIdentifier]),
           XBPText([self accessibilityLabel]),
           (unsigned long)old,
           (unsigned long)count,
           animated);

    if (gOrigT1SetBadgeCountAnimated) {
        ((void(*)(id,SEL,NSUInteger,BOOL))gOrigT1SetBadgeCountAnimated)(
            self, cmd, count, animated);
    }

    XBPDumpT1TabViewSnapshot(self, @"setBadgeCount:animated:after");
}

static void XBPT1UpdateBadgeContent(id self, SEL cmd) {
    if (gOrigT1UpdateBadgeContent)
        ((void(*)(id,SEL))gOrigT1UpdateBadgeContent)(self, cmd);
    XBPDumpT1TabViewSnapshot(self, @"_t1_updateBadgeViewContent");
}

static void XBPT1SizeBadge(id self, SEL cmd) {
    if (gOrigT1SizeBadge)
        ((void(*)(id,SEL))gOrigT1SizeBadge)(self, cmd);
    XBPDumpT1TabViewSnapshot(self, @"_t1_sizeBadgeViewToContent");
}

static void XBPT1LayoutBadge(id self, SEL cmd) {
    if (gOrigT1LayoutBadge)
        ((void(*)(id,SEL))gOrigT1LayoutBadge)(self, cmd);
    XBPDumpT1TabViewSnapshot(self, @"_t1_layoutBadge");
}

static void XBPT1LayoutBadgeMax(id self, SEL cmd) {
    if (gOrigT1LayoutBadgeMax)
        ((void(*)(id,SEL))gOrigT1LayoutBadgeMax)(self, cmd);
    XBPDumpT1TabViewSnapshot(self, @"_t1_layoutBadgeViewMaximized");
}

static void XBPT1LayoutBadgeMin(id self, SEL cmd) {
    if (gOrigT1LayoutBadgeMin)
        ((void(*)(id,SEL))gOrigT1LayoutBadgeMin)(self, cmd);
    XBPDumpT1TabViewSnapshot(self, @"_t1_layoutBadgeViewMinimized");
}

static void XBPInstallT1Hooks(void) {
    if (gT1HooksInstalled) return;

    Class cls = NSClassFromString(@"T1TabView");
    if (!cls) return;

    BOOL any = NO;

    any |= XBPHookMethod(
        cls,
        NSSelectorFromString(@"setBadgeCount:"),
        (IMP)XBPT1SetBadgeCount,
        &gOrigT1SetBadgeCount);

    any |= XBPHookMethod(
        cls,
        NSSelectorFromString(@"setBadgeCount:animated:"),
        (IMP)XBPT1SetBadgeCountAnimated,
        &gOrigT1SetBadgeCountAnimated);

    any |= XBPHookMethod(
        cls,
        NSSelectorFromString(@"_t1_updateBadgeViewContent"),
        (IMP)XBPT1UpdateBadgeContent,
        &gOrigT1UpdateBadgeContent);

    any |= XBPHookMethod(
        cls,
        NSSelectorFromString(@"_t1_sizeBadgeViewToContent"),
        (IMP)XBPT1SizeBadge,
        &gOrigT1SizeBadge);

    any |= XBPHookMethod(
        cls,
        NSSelectorFromString(@"_t1_layoutBadge"),
        (IMP)XBPT1LayoutBadge,
        &gOrigT1LayoutBadge);

    any |= XBPHookMethod(
        cls,
        NSSelectorFromString(@"_t1_layoutBadgeViewMaximized"),
        (IMP)XBPT1LayoutBadgeMax,
        &gOrigT1LayoutBadgeMax);

    any |= XBPHookMethod(
        cls,
        NSSelectorFromString(@"_t1_layoutBadgeViewMinimized"),
        (IMP)XBPT1LayoutBadgeMin,
        &gOrigT1LayoutBadgeMin);

    gT1HooksInstalled = any;

    if (gT1HooksInstalled)
        XBPLog(@"Installed T1TabView badge source hooks.");
}

#pragma mark - XNavigation hooks

static void XBPXNavItemLogIfChanged(UIView *item, NSString *event) {
    if (!item) return;

    NSString *signature =
        [NSString stringWithFormat:@"%@|%@|%@|%@|%@",
         XBPText(item.accessibilityLabel),
         XBPText(item.accessibilityValue),
         NSStringFromCGRect(item.frame),
         @(item.hidden),
         XBPSubviewSignature(item)];

    NSString *previous =
        objc_getAssociatedObject(item, &kXBPLastItemSignatureKey);

    if ([previous isEqualToString:signature]) return;

    objc_setAssociatedObject(item,
                             &kXBPLastItemSignatureKey,
                             signature,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);

    XBPDumpXNavItemSnapshot(item, event);
    XBPDumpObjectIvars(item,
                       [NSString stringWithFormat:@"XNavItem:%@",
                        XBPText(item.accessibilityLabel)]);
}

static void XBPXNavItemLayout(id self, SEL cmd) {
    if (gOrigXNavItemLayout)
        ((void(*)(id,SEL))gOrigXNavItemLayout)(self, cmd);

    if ([self isKindOfClass:UIView.class])
        XBPXNavItemLogIfChanged((UIView *)self, @"layoutSubviews");
}

static void XBPXNavItemDidMoveToWindow(id self, SEL cmd) {
    if (gOrigXNavItemDidMoveToWindow)
        ((void(*)(id,SEL))gOrigXNavItemDidMoveToWindow)(self, cmd);

    if ([self isKindOfClass:UIView.class])
        XBPXNavItemLogIfChanged((UIView *)self, @"didMoveToWindow");
}

static void XBPXNavItemSetA11yLabel(id self, SEL cmd, id value) {
    XBPLog(@"XNAV_ITEM_SET_A11Y_LABEL ptr=%p old=%@ new=%@",
           self,
           XBPText([self accessibilityLabel]),
           XBPText(value));

    if (gOrigXNavItemSetA11yLabel)
        ((void(*)(id,SEL,id))gOrigXNavItemSetA11yLabel)(
            self, cmd, value);

    if ([self isKindOfClass:UIView.class])
        XBPXNavItemLogIfChanged((UIView *)self, @"setAccessibilityLabel:");
}

static void XBPXNavItemSetA11yValue(id self, SEL cmd, id value) {
    XBPLog(@"XNAV_ITEM_SET_A11Y_VALUE ptr=%p label=%@ old=%@ new=%@",
           self,
           XBPText([self accessibilityLabel]),
           XBPText([self accessibilityValue]),
           XBPText(value));

    if (gOrigXNavItemSetA11yValue)
        ((void(*)(id,SEL,id))gOrigXNavItemSetA11yValue)(
            self, cmd, value);

    if ([self isKindOfClass:UIView.class])
        XBPXNavItemLogIfChanged((UIView *)self, @"setAccessibilityValue:");
}

static void XBPInstallXNavItemHooks(void) {
    if (gXNavItemHooksInstalled) return;

    Class cls = XBPClassByAnyName(@[
        @"_TtC11XNavigation14TabBarItemView",
        @"XNavigation.TabBarItemView"
    ]);

    if (!cls) return;

    BOOL any = NO;

    any |= XBPHookMethod(
        cls,
        @selector(layoutSubviews),
        (IMP)XBPXNavItemLayout,
        &gOrigXNavItemLayout);

    any |= XBPHookMethod(
        cls,
        @selector(didMoveToWindow),
        (IMP)XBPXNavItemDidMoveToWindow,
        &gOrigXNavItemDidMoveToWindow);

    any |= XBPHookMethod(
        cls,
        @selector(setAccessibilityLabel:),
        (IMP)XBPXNavItemSetA11yLabel,
        &gOrigXNavItemSetA11yLabel);

    any |= XBPHookMethod(
        cls,
        @selector(setAccessibilityValue:),
        (IMP)XBPXNavItemSetA11yValue,
        &gOrigXNavItemSetA11yValue);

    gXNavItemHooksInstalled = any;

    if (gXNavItemHooksInstalled) {
        XBPLog(@"Installed XNavigation.TabBarItemView observation hooks.");
        XBPDumpClassMetadata(cls, YES);
    }
}

static void XBPXNavBarLayout(id self, SEL cmd) {
    if (gOrigXNavBarLayout)
        ((void(*)(id,SEL))gOrigXNavBarLayout)(self, cmd);

    if (![self isKindOfClass:UIView.class]) return;

    UIView *bar = (UIView *)self;
    NSString *signature = XBPSubviewSignature(bar);
    NSString *previous =
        objc_getAssociatedObject(bar, &kXBPLastBarSignatureKey);

    if ([previous isEqualToString:signature]) return;

    objc_setAssociatedObject(bar,
                             &kXBPLastBarSignatureKey,
                             signature,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);

    XBPLog(@"XNAV_BAR_LAYOUT ptr=%p frame=%@ subviews=%lu signature=%@",
           bar,
           NSStringFromCGRect(bar.frame),
           (unsigned long)bar.subviews.count,
           signature);

    NSUInteger nodeCount = 0;
    XBPDumpViewTree(bar, bar, 0, @"XNavigation.TabBarView", &nodeCount);
    XBPDumpObjectIvars(bar, @"XNavigation.TabBarView");
}

static void XBPInstallXNavBarHooks(void) {
    if (gXNavBarHooksInstalled) return;

    Class cls = XBPClassByAnyName(@[
        @"_TtC11XNavigation10TabBarView",
        @"XNavigation.TabBarView"
    ]);

    if (!cls) return;

    gXNavBarHooksInstalled =
        XBPHookMethod(cls,
                      @selector(layoutSubviews),
                      (IMP)XBPXNavBarLayout,
                      &gOrigXNavBarLayout);

    if (gXNavBarHooksInstalled) {
        XBPLog(@"Installed XNavigation.TabBarView observation hook.");
        XBPDumpClassMetadata(cls, YES);
    }
}

static void XBPXNavControllerLayout(id self, SEL cmd) {
    if (gOrigXNavControllerLayout)
        ((void(*)(id,SEL))gOrigXNavControllerLayout)(self, cmd);

    if (![self isKindOfClass:UIViewController.class]) return;

    UIViewController *vc = (UIViewController *)self;
    if (!vc.isViewLoaded) return;

    UIView *bar =
        XBPFindViewByClassNames(vc.view, @[@"XNavigation.TabBarView"]);

    if (bar) {
        XBPLog(@"XNAV_CONTROLLER_LAYOUT ptr=%p bar=%p frame=%@",
               self,
               bar,
               NSStringFromCGRect(bar.frame));
    }
}

static void XBPInstallXNavControllerHooks(void) {
    if (gXNavControllerHooksInstalled) return;

    Class cls = XBPClassByAnyName(@[
        @"_TtC11XNavigation16TabBarController",
        @"XNavigation.TabBarController"
    ]);

    if (!cls) return;

    gXNavControllerHooksInstalled =
        XBPHookMethod(cls,
                      @selector(viewDidLayoutSubviews),
                      (IMP)XBPXNavControllerLayout,
                      &gOrigXNavControllerLayout);

    if (gXNavControllerHooksInstalled) {
        XBPLog(@"Installed XNavigation.TabBarController observation hook.");
        XBPDumpClassMetadata(cls, YES);
    }
}

#pragma mark - UITabBarItem bridge hook

static void XBPUITabBarItemSetBadgeValue(UITabBarItem *self,
                                          SEL cmd,
                                          NSString *value) {
    XBPLog(@"UITABBARITEM_SET_BADGE ptr=%p title=%@ old=%@ new=%@",
           self,
           XBPText(self.title),
           XBPText(self.badgeValue),
           XBPText(value));

    if (gOrigUITabBarItemSetBadgeValue) {
        ((void(*)(id,SEL,id))gOrigUITabBarItemSetBadgeValue)(
            self, cmd, value);
    }
}

static void XBPInstallUITabBarItemHook(void) {
    if (gUITabBarItemHookInstalled) return;

    gUITabBarItemHookInstalled =
        XBPHookMethod(UITabBarItem.class,
                      @selector(setBadgeValue:),
                      (IMP)XBPUITabBarItemSetBadgeValue,
                      &gOrigUITabBarItemSetBadgeValue);

    if (gUITabBarItemHookInstalled)
        XBPLog(@"Installed UITabBarItem badge bridge hook.");
}

#pragma mark - Full capture

static void XBPCapturePrimaryController(NSString *event) {
    UIViewController *controller = XBPFindPrimaryTabController();

    XBPLog(@"PRIMARY_CONTROLLER event=%@ class=%@ ptr=%p",
           event,
           controller ? NSStringFromClass(controller.class) : @"nil",
           controller);

    if (!controller || !controller.isViewLoaded) return;

    XBPDumpObjectIvars(controller,
                       [NSString stringWithFormat:@"Controller:%@",
                        NSStringFromClass(controller.class)]);

    UIView *xnavBar =
        XBPFindViewByClassNames(controller.view,
                               @[@"XNavigation.TabBarView"]);

    if (xnavBar) {
        NSUInteger nodeCount = 0;
        XBPDumpViewTree(xnavBar,
                        xnavBar,
                        0,
                        @"primary.XNavigation.TabBarView",
                        &nodeCount);
    }

    SEL tabBarSEL = NSSelectorFromString(@"tabBar");
    if ([controller respondsToSelector:tabBarSEL]) {
        id tabBar =
            ((id(*)(id,SEL))objc_msgSend)(controller, tabBarSEL);

        XBPLog(@"PRIMARY_TABBAR_OBJECT class=%@ ptr=%p",
               tabBar ? NSStringFromClass([tabBar class]) : @"nil",
               tabBar);

        if ([tabBar isKindOfClass:UIView.class]) {
            NSUInteger nodeCount = 0;
            XBPDumpViewTree((UIView *)tabBar,
                            (UIView *)tabBar,
                            0,
                            @"primary.tabBar",
                            &nodeCount);
        }
    }

    SEL tabViewsSEL = NSSelectorFromString(@"tabViews");
    if ([controller respondsToSelector:tabViewsSEL]) {
        id tabViews =
            ((id(*)(id,SEL))objc_msgSend)(controller, tabViewsSEL);

        XBPLog(@"PRIMARY_TABVIEWS class=%@ value=%@",
               tabViews ? NSStringFromClass([tabViews class]) : @"nil",
               XBPText(tabViews));
    }
}

static void XBPFullCapture(NSString *event) {
    gCaptureCount++;

    XBPLog(@"================ FULL_CAPTURE #%lu %@ ================",
           (unsigned long)gCaptureCount,
           event);

    XBPDumpControllerHierarchy();
    XBPDumpVisibleTabInfrastructure(event);
    XBPCapturePrimaryController(event);
    XBPDumpFocusedRuntime();

    XBPLog(@"================ END_FULL_CAPTURE #%lu ================",
           (unsigned long)gCaptureCount);
}

#pragma mark - NFB menu

@interface XLiquidGlassBadgeProbeViewController : UITableViewController
@end

@implementation XLiquidGlassBadgeProbeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Badge Probe";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return @"Probe completo: monitora a origem do contador em T1TabView e o destino XNavigation.TabBarItemView. Não altera badge, layout, cor ou visibilidade.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"XBPCell";

    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {
        cell =
            [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleSubtitle
              reuseIdentifier:identifier];
    }

    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (indexPath.row == 0) {
        cell.textLabel.text = @"Captura completa";
        cell.detailTextLabel.text =
            [NSString stringWithFormat:@"Capturas: %lu",
             (unsigned long)gCaptureCount];
    } else if (indexPath.row == 1) {
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
        XBPFullCapture(@"manual");
        [tableView reloadData];
        return;
    }

    if (indexPath.row == 1) {
        NSString *report =
            [NSString stringWithContentsOfFile:XBPLogPath()
                                      encoding:NSUTF8StringEncoding
                                         error:nil] ?: @"";

        UIPasteboard.generalPasteboard.string = report;

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"Badge Probe"
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
    [tableView reloadData];
}

@end

static BOOL XBPSectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;

        if ([entry[@"action"]
                isEqualToString:@"showXLiquidGlassBadgeProbe"]) {
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
        @"title": @"Badge Probe",
        @"subtitle": @"Diagnóstico completo da Tab Bar.",
        @"icon": @"flask",
        @"action": @"showXLiquidGlassBadgeProbe"
    }];

    @try {
        [controller setValue:[updated copy]
                      forKey:@"sections"];
    } @catch (__unused NSException *exception) {
    }
}

static void XBPNFBSetupSections(id self, SEL cmd) {
    if (gOrigNFBSetupSections)
        ((void(*)(id,SEL))gOrigNFBSetupSections)(self, cmd);

    XBPInjectNFBSection(self);
}

static void XBPNFBViewWillAppear(id self,
                                 SEL cmd,
                                 BOOL animated) {
    if (gOrigNFBViewWillAppear) {
        ((void(*)(id,SEL,BOOL))gOrigNFBViewWillAppear)(
            self, cmd, animated);
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

    XLiquidGlassBadgeProbeViewController *vc =
        [XLiquidGlassBadgeProbeViewController new];

    UINavigationController *navigation =
        ((UIViewController *)self).navigationController;

    if (navigation) {
        [navigation pushViewController:vc animated:YES];
    } else {
        UINavigationController *wrapper =
            [[UINavigationController alloc]
                initWithRootViewController:vc];

        [(UIViewController *)self
            presentViewController:wrapper
                         animated:YES
                       completion:nil];
    }
}

static void XBPInstallNFBIntegration(void) {
    if (gNFBHookInstalled) return;

    Class cls =
        NSClassFromString(@"ModernSettingsViewController");

    if (!cls) return;

    class_addMethod(
        cls,
        NSSelectorFromString(@"showXLiquidGlassBadgeProbe"),
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

    if (gNFBHookInstalled)
        XBPLog(@"Installed optional NeoFreeBird Badge Probe menu.");
}

#pragma mark - Install / constructor

static void XBPInstallAll(void) {
    XBPInstallT1Hooks();
    XBPInstallXNavItemHooks();
    XBPInstallXNavBarHooks();
    XBPInstallXNavControllerHooks();
    XBPInstallUITabBarItemHook();
    XBPInstallNFBIntegration();
}

static void XBPScheduleInstall(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            XBPInstallAll();
        });
}

__attribute__((constructor))
static void XLiquidGlassBadgeProbeInit(void) {
    @autoreleasepool {
        XBPLog(@"========== XLiquidGlass Badge Probe 1.0.2 loaded ==========");
        XBPLog(@"logPath=%@", XBPLogPath());
        XBPLog(@"Probe is read-only for badge/layout/theme state.");

        XBPInstallAll();

        XBPScheduleInstall(0.05);
        XBPScheduleInstall(0.20);
        XBPScheduleInstall(0.50);
        XBPScheduleInstall(1.00);
        XBPScheduleInstall(2.00);
        XBPScheduleInstall(4.00);

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(2.5 * NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{
                XBPInstallAll();
                XBPLog(@"AUTO_BASELINE_BEGIN");
                XBPDumpVisibleTabInfrastructure(@"auto-baseline");
                XBPLog(@"AUTO_BASELINE_END");
            });
    }
}
