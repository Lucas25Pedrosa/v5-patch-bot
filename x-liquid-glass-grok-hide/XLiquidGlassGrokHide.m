#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kXLGHideGrokKey = @"XLiquidGlassHideGrokTabEnabled";

static IMP gOrigSetVisibleTabEntriesSwift = NULL;
static IMP gOrigSetVisibleTabEntriesLegacy = NULL;
static IMP gOrigSettingsRows = NULL;
static IMP gOrigSettingsCell = NULL;

static BOOL gSwiftNavigationHookInstalled = NO;
static BOOL gLegacyNavigationHookInstalled = NO;
static BOOL gSettingsHookInstalled = NO;

static char kXLGOriginalVisibleTabEntriesKey;
static char kXLGOriginalShouldShowGrokIMPKey;

static BOOL XLGHideGrokEnabled(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kXLGHideGrokKey];
    return stored ? [stored boolValue] : NO;
}

static BOOL XLGHookInstanceMethod(Class cls, SEL sel, IMP replacement, IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP current = class_getMethodImplementation(cls, sel);
    if (current == replacement) return YES;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    if (originalOut && !*originalOut) {
        *originalOut = current;
    }

    class_replaceMethod(cls, sel, replacement, types);
    return class_getMethodImplementation(cls, sel) == replacement;
}

static BOOL XLGIsGrokTabEntry(id entry) {
    if (!entry) return NO;

    Class exactClass = NSClassFromString(@"_TtC14T1TwitterSwift25GrokAppNavigationTabEntry");
    if (exactClass && [entry isKindOfClass:exactClass]) return YES;

    NSString *className = NSStringFromClass([entry class]);
    return [className containsString:@"GrokAppNavigationTabEntry"];
}

static NSArray *XLGFilteredTabEntries(id entries) {
    if (![entries isKindOfClass:NSArray.class]) return entries;

    NSArray *array = (NSArray *)entries;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:array.count];

    for (id entry in array) {
        if (!XLGIsGrokTabEntry(entry)) {
            [filtered addObject:entry];
        }
    }

    if (filtered.count == array.count) return array;

    NSLog(@"[XLiquidGlass] Grok tab filtered: %lu -> %lu",
          (unsigned long)array.count,
          (unsigned long)filtered.count);

    return [filtered copy];
}

static void XLGSetVisibleTabEntriesSwift(id self, SEL _cmd, id entries) {
    if ([entries isKindOfClass:NSArray.class]) {
        objc_setAssociatedObject(self,
                                 &kXLGOriginalVisibleTabEntriesKey,
                                 [entries copy],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    id forwarded = XLGHideGrokEnabled() ? XLGFilteredTabEntries(entries) : entries;

    if (gOrigSetVisibleTabEntriesSwift) {
        ((void (*)(id, SEL, id))gOrigSetVisibleTabEntriesSwift)(self, _cmd, forwarded);
    }
}

static void XLGSetVisibleTabEntriesLegacy(id self, SEL _cmd, id entries) {
    if ([entries isKindOfClass:NSArray.class]) {
        objc_setAssociatedObject(self,
                                 &kXLGOriginalVisibleTabEntriesKey,
                                 [entries copy],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    id forwarded = XLGHideGrokEnabled() ? XLGFilteredTabEntries(entries) : entries;

    if (gOrigSetVisibleTabEntriesLegacy) {
        ((void (*)(id, SEL, id))gOrigSetVisibleTabEntriesLegacy)(self, _cmd, forwarded);
    }
}

static NSArray *XLGVisibleEntriesForController(id controller) {
    NSArray *stored = objc_getAssociatedObject(controller, &kXLGOriginalVisibleTabEntriesKey);
    if ([stored isKindOfClass:NSArray.class]) return stored;

    SEL getter = NSSelectorFromString(@"visibleTabEntries");
    if ([controller respondsToSelector:getter]) {
        id entries = ((id (*)(id, SEL))objc_msgSend)(controller, getter);
        if ([entries isKindOfClass:NSArray.class]) {
            objc_setAssociatedObject(controller,
                                     &kXLGOriginalVisibleTabEntriesKey,
                                     [entries copy],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return entries;
        }
    }

    @try {
        id entries = [controller valueForKey:@"visibleTabEntries"];
        if ([entries isKindOfClass:NSArray.class]) {
            objc_setAssociatedObject(controller,
                                     &kXLGOriginalVisibleTabEntriesKey,
                                     [entries copy],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return entries;
        }
    } @catch (__unused NSException *exception) {
    }

    return nil;
}

static void XLGApplyToViewControllerTree(UIViewController *controller, Class navigationClass) {
    if (!controller) return;

    if ((navigationClass && [controller isKindOfClass:navigationClass]) ||
        [NSStringFromClass(controller.class) containsString:@"XTabbedAppNavigationViewController"]) {

        NSArray *entries = XLGVisibleEntriesForController(controller);
        SEL setter = NSSelectorFromString(@"setVisibleTabEntries:");

        if (entries.count && [controller respondsToSelector:setter]) {
            ((void (*)(id, SEL, id))objc_msgSend)(controller, setter, entries);
        }
    }

    if (controller.presentedViewController) {
        XLGApplyToViewControllerTree(controller.presentedViewController, navigationClass);
    }

    for (UIViewController *child in controller.childViewControllers ?: @[]) {
        XLGApplyToViewControllerTree(child, navigationClass);
    }
}

static void XLGRefreshVisibleTabControllers(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class navigationClass = NSClassFromString(@"T1TabbedAppNavigationViewController");

        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows ?: @[]) {
                XLGApplyToViewControllerTree(window.rootViewController, navigationClass);
            }
        }
    });
}

static void XLGGrokToggleChanged(id self, SEL _cmd, UISwitch *sender) {
    (void)self;
    (void)_cmd;

    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:kXLGHideGrokKey];
    XLGRefreshVisibleTabControllers();
}

static NSInteger XLGSettingsRows(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSInteger base = 0;
    if (gOrigSettingsRows) {
        base = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))gOrigSettingsRows)(
            self, _cmd, tableView, section);
    }

    return section == 0 ? base + 1 : base;
}

static UITableViewCell *XLGSettingsCell(id self,
                                        SEL _cmd,
                                        UITableView *tableView,
                                        NSIndexPath *indexPath) {
    NSInteger baseRows = 0;
    if (gOrigSettingsRows) {
        baseRows = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))gOrigSettingsRows)(
            self,
            NSSelectorFromString(@"tableView:numberOfRowsInSection:"),
            tableView,
            indexPath.section);
    }

    if (indexPath.section == 0 && indexPath.row == baseRows) {
        static NSString *identifier = @"XLiquidGlassGrokHideCell";
        UITableViewCell *cell =
            [tableView dequeueReusableCellWithIdentifier:identifier];

        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                          reuseIdentifier:identifier];
        }

        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = @"Ocultar Grok na Tab Bar";
        cell.detailTextLabel.text = @"Remove somente a aba do Grok; os outros recursos continuam disponíveis.";
        cell.detailTextLabel.numberOfLines = 2;

        UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
        toggle.on = XLGHideGrokEnabled();
        [toggle addTarget:self
                   action:NSSelectorFromString(@"xlgGrokHideToggleChanged:")
         forControlEvents:UIControlEventValueChanged];

        cell.accessoryView = toggle;
        return cell;
    }

    if (gOrigSettingsCell) {
        return ((UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))gOrigSettingsCell)(
            self, _cmd, tableView, indexPath);
    }

    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                  reuseIdentifier:nil];
}

static BOOL XLGForceNoGrok(id self, SEL _cmd) {
    if (XLGHideGrokEnabled()) return NO;

    NSValue *boxed =
        objc_getAssociatedObject([self class], &kXLGOriginalShouldShowGrokIMPKey);
    IMP original = boxed.pointerValue;

    if (original && original != (IMP)XLGForceNoGrok) {
        return ((BOOL (*)(id, SEL))original)(self, _cmd);
    }

    return YES;
}

static void XLGInstallShouldShowGrokGate(void) {
    SEL gateSEL = NSSelectorFromString(@"shouldShowGrokTab");
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;

    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        Method method = class_getInstanceMethod(cls, gateSEL);
        if (!method) continue;

        const char *types = method_getTypeEncoding(method);
        if (!types || (types[0] != 'B' && types[0] != 'c')) continue;

        NSString *name = NSStringFromClass(cls);
        if (![name containsString:@"Grok"] &&
            ![name containsString:@"Navigation"] &&
            ![name containsString:@"Twitter"]) {
            continue;
        }

        IMP current = class_getMethodImplementation(cls, gateSEL);
        if (current != (IMP)XLGForceNoGrok) {
            objc_setAssociatedObject(
                cls,
                &kXLGOriginalShouldShowGrokIMPKey,
                [NSValue valueWithPointer:current],
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            class_replaceMethod(cls, gateSEL, (IMP)XLGForceNoGrok, types);
            NSLog(@"[XLiquidGlass] Grok gate hooked on %@", name);
        }
    }

    free(classes);
}

static void XLGInstallNavigationHook(void) {
    SEL setter = NSSelectorFromString(@"setVisibleTabEntries:");

    Class swiftCls =
        NSClassFromString(@"_TtC14T1TwitterSwift34XTabbedAppNavigationViewController");
    if (swiftCls &&
        [swiftCls instancesRespondToSelector:setter] &&
        !gSwiftNavigationHookInstalled) {

        if (XLGHookInstanceMethod(swiftCls,
                                  setter,
                                  (IMP)XLGSetVisibleTabEntriesSwift,
                                  &gOrigSetVisibleTabEntriesSwift)) {
            gSwiftNavigationHookInstalled = YES;
            NSLog(@"[XLiquidGlass] 2.0.3 Beta 2 Swift XTabbed Grok filter installed");
        }
    }

    Class legacyCls = NSClassFromString(@"T1TabbedAppNavigationViewController");
    if (legacyCls &&
        [legacyCls instancesRespondToSelector:setter] &&
        !gLegacyNavigationHookInstalled) {

        if (XLGHookInstanceMethod(legacyCls,
                                  setter,
                                  (IMP)XLGSetVisibleTabEntriesLegacy,
                                  &gOrigSetVisibleTabEntriesLegacy)) {
            gLegacyNavigationHookInstalled = YES;
            NSLog(@"[XLiquidGlass] 2.0.3 Beta 2 legacy Grok filter installed");
        }
    }

    XLGInstallShouldShowGrokGate();

    if (gSwiftNavigationHookInstalled || gLegacyNavigationHookInstalled) {
        XLGRefreshVisibleTabControllers();
    }
}

static void XLGInstallSettingsHook(void) {
    if (gSettingsHookInstalled) return;

    Class cls = NSClassFromString(@"XLiquidGlassSettingsViewController");
    if (!cls) return;

    SEL rowsSEL = NSSelectorFromString(@"tableView:numberOfRowsInSection:");
    SEL cellSEL = NSSelectorFromString(@"tableView:cellForRowAtIndexPath:");
    SEL actionSEL = NSSelectorFromString(@"xlgGrokHideToggleChanged:");

    class_addMethod(cls, actionSEL, (IMP)XLGGrokToggleChanged, "v@:@");

    BOOL rowsHooked =
        XLGHookInstanceMethod(cls, rowsSEL, (IMP)XLGSettingsRows, &gOrigSettingsRows);
    BOOL cellHooked =
        XLGHookInstanceMethod(cls, cellSEL, (IMP)XLGSettingsCell, &gOrigSettingsCell);

    gSettingsHookInstalled = rowsHooked && cellHooked;

    if (gSettingsHookInstalled) {
        NSLog(@"[XLiquidGlass] Grok setting integrated into Liquid Glass settings");
    }
}

static void XLGInstallAll(void) {
    XLGInstallNavigationHook();
    XLGInstallSettingsHook();
}

__attribute__((constructor))
static void XLiquidGlassGrokHideInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlass] 2.0.3 Beta 2 companion loaded: Swift XTabbed + Grok visibility gate");

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
            XLGInstallAll();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                XLGInstallAll();
                XLGRefreshVisibleTabControllers();
            });
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            XLGInstallAll();
        });
    }
}
