#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <stdint.h>
#import <string.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

static NSString *const kStudyLogName = @"TikTokLiquidGlassHeightOriginStudy.log";
static dispatch_queue_t gLogQueue;
static NSMutableSet<NSString *> *gDumpedClasses;

static NSString *StudyLogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:kStudyLogName];
}

static void StudyLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:NSDate.date], body];

    dispatch_async(gLogQueue, ^{
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSString *path = StudyLogPath();
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [data writeToFile:path atomically:YES];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        }
    });
}

static NSString *RectS(CGRect r) { return NSStringFromCGRect(r); }
static NSString *SizeS(CGSize s) { return NSStringFromCGSize(s); }
static NSString *InsetsS(UIEdgeInsets i) {
    return [NSString stringWithFormat:@"{t=%.1f,l=%.1f,b=%.1f,r=%.1f}", i.top, i.left, i.bottom, i.right];
}
static NSString *ColorS(UIColor *c) { return c ? c.description : @"-"; }

static NSArray<UIWindow *> *ActiveWindows(void) {
    NSMutableArray<UIWindow *> *out = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w) [out addObject:w];
        }
    }
    return out;
}

static BOOL InterestingMethodName(NSString *name) {
    if (!name.length) return NO;
    NSString *s = name.lowercaseString;
    NSArray<NSString *> *keys = @[
        @"liquid", @"glass", @"tab", @"bar", @"height", @"row", @"cell",
        @"page", @"paging", @"layout", @"inset", @"safe", @"scroll",
        @"frame", @"feed", @"container", @"background", @"blur", @"gradient",
        @"mask", @"stable", @"fullscreen", @"fullScreen", @"immersive", @"visible"
    ];
    for (NSString *k in keys) if ([s containsString:k]) return YES;
    return NO;
}

static void DumpClassShape(Class cls, NSString *reason) {
    if (!cls) return;
    NSString *name = NSStringFromClass(cls);
    @synchronized(gDumpedClasses) {
        if ([gDumpedClasses containsObject:name]) return;
        [gDumpedClasses addObject:name];
    }

    StudyLog(@"CLASS_BEGIN reason=%@ class=%@ superclass=%@", reason ?: @"-", name,
             class_getSuperclass(cls) ? NSStringFromClass(class_getSuperclass(cls)) : @"-");

    unsigned int ic = 0;
    Ivar *ivars = class_copyIvarList(cls, &ic);
    for (unsigned int i = 0; i < ic; i++) {
        StudyLog(@"IVAR class=%@ name=%s type=%s offset=%td",
                 name,
                 ivar_getName(ivars[i]) ?: "-",
                 ivar_getTypeEncoding(ivars[i]) ?: "-",
                 ivar_getOffset(ivars[i]));
    }
    free(ivars);

    unsigned int mc = 0;
    Method *methods = class_copyMethodList(cls, &mc);
    for (unsigned int i = 0; i < mc; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *selName = NSStringFromSelector(sel);
        if (!InterestingMethodName(selName)) continue;
        StudyLog(@"METHOD class=%@ scope=instance selector=%@ types=%s imp=%p",
                 name, selName,
                 method_getTypeEncoding(methods[i]) ?: "-",
                 method_getImplementation(methods[i]));
    }
    free(methods);

    Class meta = object_getClass(cls);
    mc = 0;
    methods = class_copyMethodList(meta, &mc);
    for (unsigned int i = 0; i < mc; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *selName = NSStringFromSelector(sel);
        if (!InterestingMethodName(selName)) continue;
        StudyLog(@"METHOD class=%@ scope=class selector=%@ types=%s imp=%p",
                 name, selName,
                 method_getTypeEncoding(methods[i]) ?: "-",
                 method_getImplementation(methods[i]));
    }
    free(methods);

    StudyLog(@"CLASS_END class=%@", name);
}

static void DumpKnownClasses(NSString *reason) {
    NSArray<NSString *> *names = @[
        @"TTKIOS26LiquidGlassSwitch",
        @"TTKABTest",
        @"TTKBizUIComponentDependencyImpl",
        @"TTKTabBarController",
        @"TTKTabBar",
        @"TTKFakeTabBar",
        @"TTKTabBarBlurView",
        @"AWEFeedRootViewController",
        @"AWEFeedContainerViewController",
        @"AWEFeedSlidingViewController",
        @"AWENewFeedTableViewController",
        @"AWEFeedCellViewController",
        @"AWERootNavigationController",
        @"TTKFeedTableViewService",
        @"TTKFeedDescBottomMaskView",
        @"AWENewFeedTableView",
        @"AWEFeedViewCell"
    ];
    for (NSString *n in names) {
        Class cls = NSClassFromString(n);
        StudyLog(@"KNOWN_CLASS reason=%@ requested=%@ resolved=%@ runtime=%@",
                 reason ?: @"-", n, cls ? @"YES" : @"NO", cls ? NSStringFromClass(cls) : @"-");
        if (cls) DumpClassShape(cls, reason);
    }
}

static BOOL RelevantVCName(NSString *name) {
    NSString *s = name.lowercaseString;
    return [s containsString:@"feed"] || [s containsString:@"tab"] ||
           [s containsString:@"root"] || [s containsString:@"scroll"] ||
           [s containsString:@"page"] || [s containsString:@"home"];
}

static void DumpVCTree(UIViewController *vc, NSUInteger depth, NSString *reason) {
    if (!vc || depth > 12) return;
    NSString *name = NSStringFromClass(vc.class);
    UIView *v = vc.viewIfLoaded;
    if (v) {
        StudyLog(@"VC reason=%@ depth=%lu class=%@:%p parent=%@ frame=%@ bounds=%@ safe=%@ additional=%@ clips=%@ bg=%@ children=%lu",
                 reason ?: @"-", (unsigned long)depth, name, vc,
                 vc.parentViewController ? NSStringFromClass(vc.parentViewController.class) : @"-",
                 RectS(v.frame), RectS(v.bounds),
                 InsetsS(v.safeAreaInsets), InsetsS(vc.additionalSafeAreaInsets),
                 v.clipsToBounds ? @"YES" : @"NO",
                 ColorS(v.backgroundColor),
                 (unsigned long)vc.childViewControllers.count);
    } else {
        StudyLog(@"VC reason=%@ depth=%lu class=%@:%p parent=%@ viewLoaded=NO children=%lu",
                 reason ?: @"-", (unsigned long)depth, name, vc,
                 vc.parentViewController ? NSStringFromClass(vc.parentViewController.class) : @"-",
                 (unsigned long)vc.childViewControllers.count);
    }

    if (RelevantVCName(name)) DumpClassShape(vc.class, @"vcTree");

    for (UIViewController *child in vc.childViewControllers) DumpVCTree(child, depth + 1, reason);
    if (vc.presentedViewController) DumpVCTree(vc.presentedViewController, depth + 1, reason);
}

static CGRect FrameInWindow(UIView *v, UIWindow *w) {
    if (!v || !w) return CGRectZero;
    @try {
        return [v convertRect:v.bounds toView:w];
    } @catch (__unused NSException *e) {
        return CGRectZero;
    }
}

static BOOL ViewClassInteresting(UIView *v) {
    NSString *n = NSStringFromClass(v.class).lowercaseString;
    return [n containsString:@"tabbar"] ||
           [n containsString:@"glass"] ||
           [n containsString:@"liquid"] ||
           [n containsString:@"feed"] ||
           [n containsString:@"table"] ||
           [n containsString:@"scroll"] ||
           [n containsString:@"collection"];
}

static void DumpScrollView(UIScrollView *s, UIWindow *w, NSString *reason) {
    CGRect wf = FrameInWindow(s, w);
    StudyLog(@"SCROLL reason=%@ class=%@:%p frame=%@ windowFrame=%@ bounds=%@ contentSize=%@ offset=%@ inset=%@ adjusted=%@ safe=%@ paging=%@ clips=%@ delegate=%@",
             reason ?: @"-",
             NSStringFromClass(s.class), s,
             RectS(s.frame), RectS(wf), RectS(s.bounds),
             SizeS(s.contentSize), NSStringFromCGPoint(s.contentOffset),
             InsetsS(s.contentInset), InsetsS(s.adjustedContentInset), InsetsS(s.safeAreaInsets),
             s.pagingEnabled ? @"YES" : @"NO",
             s.clipsToBounds ? @"YES" : @"NO",
             s.delegate ? NSStringFromClass([s.delegate class]) : @"-");

    if (s.delegate) DumpClassShape([s.delegate class], @"scrollDelegate");

    if ([s isKindOfClass:UITableView.class]) {
        UITableView *t = (UITableView *)s;
        StudyLog(@"TABLE reason=%@ class=%@:%p rowHeight=%.1f estimated=%.1f separatorStyle=%ld visible=%lu delegate=%@ dataSource=%@",
                 reason ?: @"-", NSStringFromClass(t.class), t,
                 t.rowHeight, t.estimatedRowHeight, (long)t.separatorStyle,
                 (unsigned long)t.visibleCells.count,
                 t.delegate ? NSStringFromClass([t.delegate class]) : @"-",
                 t.dataSource ? NSStringFromClass([t.dataSource class]) : @"-");
        if (t.dataSource) DumpClassShape([t.dataSource class], @"tableDataSource");

        for (UITableViewCell *cell in t.visibleCells) {
            NSIndexPath *ip = [t indexPathForCell:cell];
            CGRect cwin = FrameInWindow(cell, w);
            StudyLog(@"CELL reason=%@ index=%@ class=%@:%p frame=%@ windowFrame=%@ bounds=%@ contentFrame=%@ safe=%@ clips=%@ contentClips=%@ bg=%@",
                     reason ?: @"-", ip ?: (id)@"-",
                     NSStringFromClass(cell.class), cell,
                     RectS(cell.frame), RectS(cwin), RectS(cell.bounds),
                     RectS(cell.contentView.frame), InsetsS(cell.safeAreaInsets),
                     cell.clipsToBounds ? @"YES" : @"NO",
                     cell.contentView.clipsToBounds ? @"YES" : @"NO",
                     ColorS(cell.backgroundColor));
        }
    }
}

static void DumpWindowViews(UIWindow *w, NSString *reason) {
    if (!w) return;
    CGFloat h = CGRectGetHeight(w.bounds);
    StudyLog(@"WINDOW reason=%@ class=%@:%p frame=%@ bounds=%@ level=%.1f root=%@ hidden=%@ alpha=%.2f",
             reason ?: @"-", NSStringFromClass(w.class), w,
             RectS(w.frame), RectS(w.bounds), w.windowLevel,
             w.rootViewController ? NSStringFromClass(w.rootViewController.class) : @"-",
             w.hidden ? @"YES" : @"NO", w.alpha);

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:w];
    NSUInteger idx = 0;
    NSUInteger visited = 0;
    NSUInteger bottomHits = 0;

    while (idx < queue.count && visited < 2500) {
        UIView *v = queue[idx++];
        visited++;
        CGRect wf = FrameInWindow(v, w);
        BOOL bottom = CGRectGetMaxY(wf) > h - 140.0 && CGRectGetWidth(wf) > 100.0 && CGRectGetHeight(wf) > 20.0;
        BOOL interesting = ViewClassInteresting(v);

        if ((interesting || bottom) && bottomHits < 220) {
            NSUInteger z = v.superview ? [v.superview.subviews indexOfObjectIdenticalTo:v] : NSNotFound;
            StudyLog(@"VIEW reason=%@ class=%@:%p frame=%@ windowFrame=%@ bounds=%@ alpha=%.2f hidden=%@ clips=%@ bg=%@ super=%@ zIndex=%@ layerMask=%@ corner=%.1f masks=%@",
                     reason ?: @"-", NSStringFromClass(v.class), v,
                     RectS(v.frame), RectS(wf), RectS(v.bounds),
                     v.alpha, v.hidden ? @"YES" : @"NO",
                     v.clipsToBounds ? @"YES" : @"NO",
                     ColorS(v.backgroundColor),
                     v.superview ? NSStringFromClass(v.superview.class) : @"-",
                     z == NSNotFound ? @"-" : [NSString stringWithFormat:@"%lu",(unsigned long)z],
                     v.layer.mask ? NSStringFromClass(v.layer.mask.class) : @"-",
                     v.layer.cornerRadius,
                     v.layer.masksToBounds ? @"YES" : @"NO");
            bottomHits++;
        }

        if ([v isKindOfClass:UIScrollView.class]) DumpScrollView((UIScrollView *)v, w, reason);
        [queue addObjectsFromArray:v.subviews];
    }

    StudyLog(@"WINDOW_SUMMARY reason=%@ visited=%lu interestingOrBottom=%lu",
             reason ?: @"-", (unsigned long)visited, (unsigned long)bottomHits);
}

static void DumpTabRelationship(UIWindow *w, NSString *reason) {
    if (!w) return;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:w];
    NSUInteger idx = 0;
    while (idx < queue.count && idx < 2500) {
        UIView *v = queue[idx++];
        NSString *n = NSStringFromClass(v.class);
        if ([n containsString:@"TTKTabBar"] || [n containsString:@"UITabBarContainer"] ||
            [n containsString:@"UITabBarItemPlatter"] || [n containsString:@"LiquidLens"] ||
            [n containsString:@"ClearGlass"]) {
            NSMutableArray<NSString *> *chain = [NSMutableArray array];
            UIView *cur = v;
            NSUInteger d = 0;
            while (cur && d++ < 12) {
                [chain addObject:[NSString stringWithFormat:@"%@:%p(a=%.2f,h=%@,f=%@)",
                                  NSStringFromClass(cur.class), cur, cur.alpha,
                                  cur.hidden ? @"Y" : @"N", RectS(cur.frame)]];
                cur = cur.superview;
            }
            StudyLog(@"TAB_CHAIN reason=%@ %@", reason ?: @"-", [chain componentsJoinedByString:@" <- "]);
        }
        [queue addObjectsFromArray:v.subviews];
    }
}


static id FindVCByClassName(UIViewController *vc, NSString *target) {
    if (!vc || !target.length) return nil;
    if ([NSStringFromClass(vc.class) isEqualToString:target]) return vc;
    for (UIViewController *child in vc.childViewControllers) {
        id found = FindVCByClassName(child, target);
        if (found) return found;
    }
    if (vc.presentedViewController) {
        id found = FindVCByClassName(vc.presentedViewController, target);
        if (found) return found;
    }
    return nil;
}

static UIView *FindViewByClassSubstring(UIView *root, NSString *needle) {
    if (!root || !needle.length) return nil;
    if ([NSStringFromClass(root.class) containsString:needle]) return root;
    for (UIView *child in root.subviews) {
        UIView *found = FindViewByClassSubstring(child, needle);
        if (found) return found;
    }
    return nil;
}

static void ReadNumericNoArg(id obj, NSString *selectorName, NSString *label, NSString *reason) {
    if (!obj || !selectorName.length) return;
    SEL sel = NSSelectorFromString(selectorName);
    Method m = class_getInstanceMethod([obj class], sel);
    if (!m || ![obj respondsToSelector:sel]) {
        StudyLog(@"HEIGHT_GETTER reason=%@ label=%@ object=%@:%p selector=%@ available=NO",
                 reason ?: @"-", label ?: @"-", NSStringFromClass([obj class]), obj, selectorName);
        return;
    }

    char ret[64] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    @try {
        if (ret[0] == 'd') {
            double v = ((double(*)(id,SEL))objc_msgSend)(obj, sel);
            StudyLog(@"HEIGHT_GETTER reason=%@ label=%@ object=%@:%p selector=%@ type=%s value=%.6f",
                     reason ?: @"-", label ?: @"-", NSStringFromClass([obj class]), obj, selectorName, ret, v);
        } else if (ret[0] == 'f') {
            float v = ((float(*)(id,SEL))objc_msgSend)(obj, sel);
            StudyLog(@"HEIGHT_GETTER reason=%@ label=%@ object=%@:%p selector=%@ type=%s value=%.6f",
                     reason ?: @"-", label ?: @"-", NSStringFromClass([obj class]), obj, selectorName, ret, (double)v);
        } else if (strchr("qQiIlLsScCB", ret[0])) {
            long long v = ((long long(*)(id,SEL))objc_msgSend)(obj, sel);
            StudyLog(@"HEIGHT_GETTER reason=%@ label=%@ object=%@:%p selector=%@ type=%s value=%lld",
                     reason ?: @"-", label ?: @"-", NSStringFromClass([obj class]), obj, selectorName, ret, v);
        } else {
            StudyLog(@"HEIGHT_GETTER reason=%@ label=%@ object=%@:%p selector=%@ type=%s skipped=unsupportedReturnType",
                     reason ?: @"-", label ?: @"-", NSStringFromClass([obj class]), obj, selectorName, ret);
        }
    } @catch (NSException *e) {
        StudyLog(@"HEIGHT_GETTER_EXCEPTION reason=%@ label=%@ selector=%@ exception=%@",
                 reason ?: @"-", label ?: @"-", selectorName, e);
    }
}

static void DumpRawNumericIvar(id obj, NSString *ivarName, NSString *reason) {
    if (!obj || !ivarName.length) return;
    Ivar iv = class_getInstanceVariable([obj class], ivarName.UTF8String);
    if (!iv) {
        StudyLog(@"IVAR_VALUE reason=%@ object=%@:%p ivar=%@ available=NO",
                 reason ?: @"-", NSStringFromClass([obj class]), obj, ivarName);
        return;
    }

    const char *type = ivar_getTypeEncoding(iv);
    ptrdiff_t off = ivar_getOffset(iv);
    const uint8_t *base = (const uint8_t *)(__bridge const void *)obj;
    const void *p = base + off;

    if (type && type[0] == 'd') {
        double v = 0; memcpy(&v, p, sizeof(v));
        StudyLog(@"IVAR_VALUE reason=%@ object=%@:%p ivar=%@ type=%s offset=%td value=%.6f",
                 reason ?: @"-", NSStringFromClass([obj class]), obj, ivarName, type, off, v);
    } else if (type && type[0] == 'f') {
        float v = 0; memcpy(&v, p, sizeof(v));
        StudyLog(@"IVAR_VALUE reason=%@ object=%@:%p ivar=%@ type=%s offset=%td value=%.6f",
                 reason ?: @"-", NSStringFromClass([obj class]), obj, ivarName, type, off, (double)v);
    } else if (type && strchr("qQiIlLsScCB", type[0])) {
        long long v = 0;
        size_t n = 0;
        switch (type[0]) {
            case 'q': case 'Q': n = sizeof(long long); break;
            case 'i': case 'I': n = sizeof(int); break;
            case 'l': case 'L': n = sizeof(long); break;
            case 's': case 'S': n = sizeof(short); break;
            case 'c': case 'C': case 'B': n = sizeof(char); break;
            default: n = 0; break;
        }
        if (n > 0) memcpy(&v, p, n);
        StudyLog(@"IVAR_VALUE reason=%@ object=%@:%p ivar=%@ type=%s offset=%td value=%lld",
                 reason ?: @"-", NSStringFromClass([obj class]), obj, ivarName, type, off, v);
    } else {
        StudyLog(@"IVAR_VALUE reason=%@ object=%@:%p ivar=%@ type=%s offset=%td skipped=nonNumeric",
                 reason ?: @"-", NSStringFromClass([obj class]), obj, ivarName, type ?: "-", off);
    }
}

static NSString *ConstraintItemName(id item) {
    if (!item) return @"-";
    if ([item isKindOfClass:UIView.class]) return [NSString stringWithFormat:@"%@:%p", NSStringFromClass([item class]), item];
    if ([item isKindOfClass:UILayoutGuide.class]) {
        UILayoutGuide *g = item;
        return [NSString stringWithFormat:@"%@:%p(owner=%@:%p)", NSStringFromClass([g class]), g,
                g.owningView ? NSStringFromClass(g.owningView.class) : @"-", g.owningView];
    }
    return [NSString stringWithFormat:@"%@:%p", NSStringFromClass([item class]), item];
}

static BOOL ConstraintTouchesView(NSLayoutConstraint *c, UIView *v) {
    if (!c || !v) return NO;
    if (c.firstItem == v || c.secondItem == v) return YES;
    if ([c.firstItem isKindOfClass:UILayoutGuide.class] && ((UILayoutGuide *)c.firstItem).owningView == v) return YES;
    if ([c.secondItem isKindOfClass:UILayoutGuide.class] && ((UILayoutGuide *)c.secondItem).owningView == v) return YES;
    return NO;
}

static void DumpConstraintsForView(UIView *v, NSString *label, NSString *reason) {
    if (!v) return;
    UIWindow *w = v.window;
    CGRect wf = w ? FrameInWindow(v, w) : CGRectZero;
    StudyLog(@"GEOMETRY reason=%@ label=%@ class=%@:%p frame=%@ windowFrame=%@ bounds=%@ safe=%@ safeLayoutFrame=%@ intrinsic=%@ translatesMask=%@",
             reason ?: @"-", label ?: @"-", NSStringFromClass(v.class), v,
             RectS(v.frame), RectS(wf), RectS(v.bounds), InsetsS(v.safeAreaInsets),
             RectS(v.safeAreaLayoutGuide.layoutFrame), SizeS(v.intrinsicContentSize),
             v.translatesAutoresizingMaskIntoConstraints ? @"YES" : @"NO");

    NSMutableArray<UIView *> *chain = [NSMutableArray array];
    UIView *cur = v;
    for (NSUInteger d = 0; cur && d < 5; d++, cur = cur.superview) [chain addObject:cur];

    NSUInteger emitted = 0;
    for (UIView *owner in chain) {
        for (NSLayoutConstraint *c in owner.constraints) {
            if (!ConstraintTouchesView(c, v) && owner != v) continue;
            StudyLog(@"CONSTRAINT reason=%@ label=%@ owner=%@:%p active=%@ priority=%.1f first=%@ attr1=%ld relation=%ld second=%@ attr2=%ld multiplier=%.4f constant=%.4f id=%@",
                     reason ?: @"-", label ?: @"-", NSStringFromClass(owner.class), owner,
                     c.active ? @"YES" : @"NO", c.priority,
                     ConstraintItemName(c.firstItem), (long)c.firstAttribute, (long)c.relation,
                     ConstraintItemName(c.secondItem), (long)c.secondAttribute,
                     c.multiplier, c.constant, c.identifier ?: @"-");
            if (++emitted >= 120) return;
        }
    }
}

static void DumpRuntimeCandidatesOnce(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);
    NSUInteger hits = 0;
    NSArray<NSString *> *tokens = @[@"FeedTable", @"FeedHeight", @"BottomMask", @"Immersive",
                                     @"FullScreen", @"Fullscreen", @"TabBar", @"LiquidGlass"];
    for (int i = 0; i < count && hits < 100; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        BOOL match = NO;
        for (NSString *t in tokens) {
            if ([name containsString:t]) { match = YES; break; }
        }
        if (!match) continue;
        StudyLog(@"RUNTIME_CANDIDATE class=%@", name);
        DumpClassShape(classes[i], @"runtimeCandidate");
        hits++;
    }
    free(classes);
    StudyLog(@"RUNTIME_CANDIDATE_SUMMARY hits=%lu", (unsigned long)hits);
}

static void DumpFocusedHeightStudy(UIWindow *w, NSString *reason) {
    if (!w) return;

    UIViewController *root = w.rootViewController;
    UIViewController *tabVC = FindVCByClassName(root, @"TTKTabBarController");
    UIViewController *feedVC = FindVCByClassName(root, @"AWENewFeedTableViewController");

    if (tabVC) ReadNumericNoArg(tabVC, @"tabBarHeight", @"TTKTabBarController.tabBarHeight", reason);
    if (feedVC) ReadNumericNoArg(feedVC, @"cellHeight", @"AWENewFeedTableViewController.cellHeight", reason);

    UIView *tableView = FindViewByClassSubstring(w, @"AWENewFeedTableView");
    if (![tableView isKindOfClass:UITableView.class]) {
        StudyLog(@"HEIGHT_FOCUS reason=%@ table=NOT_FOUND", reason ?: @"-");
        return;
    }

    UITableView *table = (UITableView *)tableView;
    id service = table.delegate;
    StudyLog(@"HEIGHT_FOCUS reason=%@ table=%@:%p delegate=%@:%p dataSource=%@:%p frame=%@ contentSize=%@ rowHeight=%.3f estimated=%.3f",
             reason ?: @"-", NSStringFromClass(table.class), table,
             service ? NSStringFromClass([service class]) : @"-", service,
             table.dataSource ? NSStringFromClass([table.dataSource class]) : @"-", table.dataSource,
             RectS(table.frame), SizeS(table.contentSize), table.rowHeight, table.estimatedRowHeight);

    if (service) {
        ReadNumericNoArg(service, @"cellHeight", @"TTKFeedTableViewService.cellHeight", reason);
        ReadNumericNoArg(service, @"lastStableCellHeight", @"TTKFeedTableViewService.lastStableCellHeight", reason);
        DumpRawNumericIvar(service, @"_lastStableCellHeight", reason);

        SEL hsel = NSSelectorFromString(@"tableView:heightForRowAtIndexPath:");
        Method hm = class_getInstanceMethod([service class], hsel);
        if (hm && [service respondsToSelector:hsel]) {
            char ret[32] = {0};
            method_getReturnType(hm, ret, sizeof(ret));
            NSArray<NSIndexPath *> *visible = table.indexPathsForVisibleRows ?: @[];
            for (NSIndexPath *ip in visible) {
                @try {
                    double h = 0;
                    if (ret[0] == 'd') {
                        h = ((double(*)(id,SEL,id,id))objc_msgSend)(service, hsel, table, ip);
                    } else if (ret[0] == 'f') {
                        h = (double)((float(*)(id,SEL,id,id))objc_msgSend)(service, hsel, table, ip);
                    } else {
                        StudyLog(@"ROW_HEIGHT reason=%@ index=%@ type=%s skipped=unsupportedReturnType",
                                 reason ?: @"-", ip, ret);
                        continue;
                    }
                    StudyLog(@"ROW_HEIGHT reason=%@ index=%@ type=%s value=%.6f",
                             reason ?: @"-", ip, ret, h);
                } @catch (NSException *e) {
                    StudyLog(@"ROW_HEIGHT_EXCEPTION reason=%@ index=%@ exception=%@",
                             reason ?: @"-", ip, e);
                }
            }
        }
    }

    DumpConstraintsForView(table, @"AWENewFeedTableView", reason);

    UIView *mask = FindViewByClassSubstring(w, @"TTKFeedDescBottomMaskView");
    if (mask) {
        DumpConstraintsForView(mask, @"TTKFeedDescBottomMaskView", reason);
        DumpClassShape(mask.class, @"bottomMaskInstance");
    } else {
        StudyLog(@"HEIGHT_FOCUS reason=%@ bottomMask=NOT_FOUND", reason ?: @"-");
    }

    UIView *bar = FindViewByClassSubstring(w, @"TTKTabBar");
    if (bar) DumpConstraintsForView(bar, @"TTKTabBar", reason);

    UIView *wrapper = FindViewByClassSubstring(w, @"_UITabBarContainerWrapperView");
    if (wrapper) DumpConstraintsForView(wrapper, @"UIKitTabBarWrapper", reason);

    CGFloat windowH = CGRectGetHeight(w.bounds);
    CGFloat tableH = CGRectGetHeight(table.frame);
    CGFloat barH = bar ? CGRectGetHeight(bar.frame) : 0;
    StudyLog(@"HEIGHT_EQUATION reason=%@ windowH=%.3f tableH=%.3f delta=%.3f tabBarH=%.3f deltaEqualsBar=%@",
             reason ?: @"-", windowH, tableH, windowH-tableH, barH,
             fabs((windowH-tableH)-barH) < 0.5 ? @"YES" : @"NO");
}



static intptr_t SlideForImagePath(const char *path, const struct mach_header **headerOut, uint32_t *indexOut) {
    if (headerOut) *headerOut = NULL;
    if (indexOut) *indexOut = UINT32_MAX;
    if (!path) return 0;

    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strcmp(name, path) == 0) {
            if (headerOut) *headerOut = _dyld_get_image_header(i);
            if (indexOut) *indexOut = i;
            return _dyld_get_image_vmaddr_slide(i);
        }
    }

    const char *last = strrchr(path, '/');
    const char *base = last ? last + 1 : path;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        const char *nl = strrchr(name, '/');
        const char *nb = nl ? nl + 1 : name;
        if (strcmp(nb, base) == 0) {
            if (headerOut) *headerOut = _dyld_get_image_header(i);
            if (indexOut) *indexOut = i;
            return _dyld_get_image_vmaddr_slide(i);
        }
    }
    return 0;
}

static void LogIMPOrigin(Class cls, SEL sel, BOOL classMethod, NSString *label, NSString *reason) {
    if (!cls || !sel) {
        StudyLog(@"IMP_ORIGIN reason=%@ label=%@ available=NO classOrSelectorMissing=YES",
                 reason ?: @"-", label ?: @"-");
        return;
    }

    Method m = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) {
        StudyLog(@"IMP_ORIGIN reason=%@ label=%@ class=%@ scope=%@ selector=%@ available=NO",
                 reason ?: @"-", label ?: @"-", NSStringFromClass(cls),
                 classMethod ? @"class" : @"instance", NSStringFromSelector(sel));
        return;
    }

    IMP imp = method_getImplementation(m);
    Dl_info info = {0};
    int ok = dladdr((const void *)imp, &info);

    const struct mach_header *header = NULL;
    uint32_t imageIndex = UINT32_MAX;
    intptr_t slide = ok ? SlideForImagePath(info.dli_fname, &header, &imageIndex) : 0;

    uintptr_t impAddr = (uintptr_t)imp;
    uintptr_t imageBase = ok ? (uintptr_t)info.dli_fbase : 0;
    uintptr_t imageOffset = imageBase ? (impAddr - imageBase) : 0;
    uintptr_t unslid = slide ? (uintptr_t)((intptr_t)impAddr - slide) : impAddr;
    uintptr_t headerAddr = (uintptr_t)header;

    StudyLog(@"IMP_ORIGIN reason=%@ label=%@ class=%@ scope=%@ selector=%@ types=%s imp=0x%llx dladdr=%@ image=%s symbol=%s symbolAddr=%p imageBase=0x%llx imageOffset=0x%llx imageIndex=%@ header=0x%llx slide=0x%llx unslid=0x%llx",
             reason ?: @"-",
             label ?: @"-",
             NSStringFromClass(cls),
             classMethod ? @"class" : @"instance",
             NSStringFromSelector(sel),
             method_getTypeEncoding(m) ?: "-",
             (unsigned long long)impAddr,
             ok ? @"YES" : @"NO",
             (ok && info.dli_fname) ? info.dli_fname : "-",
             (ok && info.dli_sname) ? info.dli_sname : "-",
             (ok && info.dli_saddr) ? info.dli_saddr : NULL,
             (unsigned long long)imageBase,
             (unsigned long long)imageOffset,
             imageIndex == UINT32_MAX ? @"-" : [NSString stringWithFormat:@"%u", imageIndex],
             (unsigned long long)headerAddr,
             (unsigned long long)slide,
             (unsigned long long)unslid);
}

static void LogMethodOriginsForClass(Class cls, NSArray<NSString *> *selectorNames, NSString *reason) {
    if (!cls) return;
    for (NSString *name in selectorNames) {
        SEL sel = NSSelectorFromString(name);
        LogIMPOrigin(cls, sel, NO,
                     [NSString stringWithFormat:@"%@.%@", NSStringFromClass(cls), name],
                     reason);
        Method cm = class_getClassMethod(cls, sel);
        if (cm) {
            LogIMPOrigin(cls, sel, YES,
                         [NSString stringWithFormat:@"+[%@ %@]", NSStringFromClass(cls), name],
                         reason);
        }
    }
}

static Class FindRuntimeClassContainingAll(NSArray<NSString *> *tokens) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);
    Class found = Nil;
    for (int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        BOOL matches = YES;
        for (NSString *token in tokens) {
            if (![name containsString:token]) { matches = NO; break; }
        }
        if (matches) { found = classes[i]; break; }
    }
    free(classes);
    return found;
}

static void DumpHeightOriginMap(NSString *reason) {
    StudyLog(@"ORIGIN_MAP_BEGIN reason=%@", reason ?: @"-");

    Class feedVC = NSClassFromString(@"AWENewFeedTableViewController");
    LogMethodOriginsForClass(feedVC, @[
        @"cellHeight",
        @"viewDidLoad",
        @"viewWillLayoutSubviews",
        @"viewDidLayoutSubviews"
    ], reason);

    Class service = NSClassFromString(@"TTKFeedTableViewService");
    LogMethodOriginsForClass(service, @[
        @"cellHeight",
        @"lastStableCellHeight",
        @"setLastStableCellHeight:",
        @"tableView:heightForRowAtIndexPath:",
        @"tableView:cellForRowAtIndexPath:",
        @"tableView:willDisplayCell:forRowAtIndexPath:",
        @"scrollViewDidScroll:",
        @"scrollViewWillEndDragging:withVelocity:targetContentOffset:"
    ], reason);

    Class tabController = NSClassFromString(@"TTKTabBarController");
    LogMethodOriginsForClass(tabController, @[
        @"heightForTabBar",
        @"tabBarHeight",
        @"tabBarContentSize",
        @"viewWillLayoutSubviews",
        @"viewDidLayoutSubviews"
    ], reason);

    Class config = NSClassFromString(@"TikTokTabBarImpl.TTKTabBarConfigration");
    if (!config) config = FindRuntimeClassContainingAll(@[@"TTKTabBar", @"Config"]);
    if (config) {
        StudyLog(@"ORIGIN_CONFIG_CLASS reason=%@ class=%@", reason ?: @"-", NSStringFromClass(config));
        DumpClassShape(config, @"originConfig");
        LogMethodOriginsForClass(config, @[
            @"tabBarHeight",
            @"setTabBarHeight:",
            @"contentHeight",
            @"barHeight"
        ], reason);
    } else {
        StudyLog(@"ORIGIN_CONFIG_CLASS reason=%@ class=NOT_FOUND", reason ?: @"-");
    }

    Class mask = NSClassFromString(@"TTKFeedDescBottomMaskView");
    LogMethodOriginsForClass(mask, @[
        @"layoutSubviews",
        @"setFrame:",
        @"setBounds:",
        @"intrinsicContentSize"
    ], reason);

    Class tableClass = NSClassFromString(@"AWENewFeedTableView");
    LogMethodOriginsForClass(tableClass, @[
        @"layoutSubviews",
        @"setFrame:",
        @"setBounds:",
        @"setContentSize:"
    ], reason);

    StudyLog(@"ORIGIN_MAP_END reason=%@", reason ?: @"-");
}

static void DumpLoadedImagesOnce(void) {
    uint32_t count = _dyld_image_count();
    StudyLog(@"DYLD_IMAGES_BEGIN count=%u", count);
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *n = [NSString stringWithUTF8String:name];
        if ([n containsString:@"MusicallyCore"] ||
            [n containsString:@"/TikTok"] ||
            [n containsString:@"TikTokTabBar"] ||
            [n containsString:@"TUX"]) {
            const struct mach_header *h = _dyld_get_image_header(i);
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            StudyLog(@"DYLD_IMAGE index=%u path=%s header=%p slide=0x%llx",
                     i, name, h, (unsigned long long)slide);
        }
    }
    StudyLog(@"DYLD_IMAGES_END");
}


static void DumpAppContext(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    StudyLog(@"========== TikTokLiquidGlass 1.3 Read-Only Height Origin Probe loaded ==========");
    StudyLog(@"logPath=%@", StudyLogPath());
    StudyLog(@"bundle=%@ version=%@ build=%@ executable=%@",
             NSBundle.mainBundle.bundleIdentifier ?: @"-",
             info[@"CFBundleShortVersionString"] ?: @"-",
             info[@"CFBundleVersion"] ?: @"-",
             info[@"CFBundleExecutable"] ?: @"-");
    StudyLog(@"system=%@ UIDesignRequiresCompatibility=%@ DTSDKName=%@ DTPlatformVersion=%@",
             UIDevice.currentDevice.systemVersion ?: @"-",
             info[@"UIDesignRequiresCompatibility"] ?: @"-",
             info[@"DTSDKName"] ?: @"-",
             info[@"DTPlatformVersion"] ?: @"-");
}

static void Snapshot(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<UIWindow *> *windows = ActiveWindows();
        StudyLog(@"SNAPSHOT_BEGIN reason=%@ windows=%lu", reason ?: @"-", (unsigned long)windows.count);

        DumpKnownClasses(reason);
        DumpHeightOriginMap(reason);

        for (UIWindow *w in windows) {
            if (w.rootViewController) DumpVCTree(w.rootViewController, 0, reason);
            DumpWindowViews(w, reason);
            DumpTabRelationship(w, reason);
            DumpFocusedHeightStudy(w, reason);
        }

        StudyLog(@"SNAPSHOT_END reason=%@", reason ?: @"-");
    });
}

__attribute__((constructor))
static void TikTokLiquidGlassStudyInit(void) {
    @autoreleasepool {
        gLogQueue = dispatch_queue_create("com.lucaspedrosa.tlg.studylog", DISPATCH_QUEUE_SERIAL);
        gDumpedClasses = [NSMutableSet set];

        [[NSFileManager defaultManager] removeItemAtPath:StudyLogPath() error:nil];
        DumpAppContext();
        DumpKnownClasses(@"constructor");
        DumpRuntimeCandidatesOnce();
        DumpLoadedImagesOnce();
        DumpHeightOriginMap(@"constructor");

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(__unused NSNotification *note) {
            StudyLog(@"EVENT UIApplicationDidFinishLaunchingNotification");
            Snapshot(@"didFinishLaunching");
        }];

        NSArray<NSNumber *> *delays = @[@0.5, @2.0, @5.0, @10.0, @20.0];
        for (NSNumber *n in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(n.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                Snapshot([NSString stringWithFormat:@"delay-%.1fs", n.doubleValue]);
            });
        }
    }
}
