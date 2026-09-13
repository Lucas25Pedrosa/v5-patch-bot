#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// iQFaceSettingsProbe 1.0.0
// Passive runtime probe: logs iQFace settings call flow without modifying settings data.

static dispatch_queue_t IQFSPWriteQueue;
static NSString *IQFSPReportPath;
static NSMutableDictionary<NSString *, NSValue *> *IQFSPOriginalNoArgClassIMPs;
static BOOL IQFSPInstalled = NO;
static NSUInteger IQFSPInstallAttempts = 0;
static NSString *IQFSPLastUISignature;
static dispatch_source_t IQFSPUITimer;

static void IQFSPAppend(NSString *text) {
    if (text.length == 0 || IQFSPReportPath.length == 0) return;
    dispatch_async(IQFSPWriteQueue, ^{
        @autoreleasepool {
            NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:IQFSPReportPath];
            if (!h) return;
            @try {
                [h seekToEndOfFile];
                NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
                if (d) [h writeData:d];
            } @catch (__unused NSException *e) {
            }
            [h closeFile];
        }
    });
}

static NSString *IQFSPNow(void) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"HH:mm:ss.SSS";
    return [f stringFromDate:[NSDate date]];
}

static void IQFSPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void IQFSPLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    IQFSPAppend([NSString stringWithFormat:@"[%@] %@\n", IQFSPNow(), body]);
}

static NSString *IQFSPCString(const char *s) {
    if (!s) return @"(null)";
    NSString *v = [NSString stringWithUTF8String:s];
    return v ?: @"(invalid utf8)";
}

static BOOL IQFSPMethodReturnsObject(Method m) {
    if (!m) return NO;
    char *ret = method_copyReturnType(m);
    BOOL ok = ret && ret[0] == '@';
    if (ret) free(ret);
    return ok;
}

static BOOL IQFSPMethodReturnsVoid(Method m) {
    if (!m) return NO;
    char *ret = method_copyReturnType(m);
    BOOL ok = ret && ret[0] == 'v';
    if (ret) free(ret);
    return ok;
}

static BOOL IQFSPMethodReturnsIntegerLike(Method m) {
    if (!m) return NO;
    char *ret = method_copyReturnType(m);
    BOOL ok = ret && strchr("qQiIlLsScCB", ret[0]) != NULL;
    if (ret) free(ret);
    return ok;
}

static BOOL IQFSPClassImplementsSelector(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

static void IQFSPDumpCallStack(NSString *label) {
    NSArray<NSString *> *stack = [NSThread callStackSymbols];
    IQFSPLog(@"CALL STACK %@ (%lu frames)", label ?: @"", (unsigned long)stack.count);
    NSUInteger limit = MIN((NSUInteger)18, stack.count);
    for (NSUInteger i = 0; i < limit; i++) {
        IQFSPLog(@"  #%02lu %@", (unsigned long)i, stack[i]);
    }
}

static id IQFSPSafeObjectGetter(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0) return nil;
    SEL sel = NSSelectorFromString(selectorName);
    Method m = class_getInstanceMethod([object class], sel);
    if (!m || method_getNumberOfArguments(m) != 2 || !IQFSPMethodReturnsObject(m)) return nil;
    @try {
        typedef id (*Getter)(id, SEL);
        Getter g = (Getter)(void *)objc_msgSend;
        return g(object, sel);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *IQFSPShortDescription(id object) {
    if (!object) return @"nil";
    NSString *d = nil;
    @try { d = [object description]; } @catch (__unused NSException *e) {}
    if (d.length > 300) d = [[d substringToIndex:300] stringByAppendingString:@"…"];
    return d ?: @"(no description)";
}

static void IQFSPDescribeSetting(id setting, NSUInteger indent) {
    if (!setting) return;
    NSString *pad = [@"" stringByPaddingToLength:indent withString:@" " startingAtIndex:0];
    IQFSPLog(@"%@SETTING class=%@ ptr=%p", pad, NSStringFromClass([setting class]), setting);

    NSArray<NSString *> *keys = @[@"title", @"subtitle", @"dynamicSubtitle", @"icon", @"defaultsKey", @"options", @"action", @"viewController", @"navSections"];
    for (NSString *key in keys) {
        id value = IQFSPSafeObjectGetter(setting, key);
        if (value) {
            IQFSPLog(@"%@  %@: class=%@ value=%@", pad, key, NSStringFromClass([value class]), IQFSPShortDescription(value));
        }
    }
}

static void IQFSPDescribeSections(id object, NSString *label) {
    IQFSPLog(@"---- %@ ----", label ?: @"sections");
    if (!object) {
        IQFSPLog(@"nil");
        return;
    }
    IQFSPLog(@"return class=%@ ptr=%p description=%@", NSStringFromClass([object class]), object, IQFSPShortDescription(object));
    if (![object isKindOfClass:[NSArray class]]) return;

    NSArray *sections = (NSArray *)object;
    IQFSPLog(@"section count=%lu", (unsigned long)sections.count);
    for (NSUInteger i = 0; i < sections.count; i++) {
        id section = sections[i];
        IQFSPLog(@"section[%lu] class=%@", (unsigned long)i, NSStringFromClass([section class]));
        if ([section isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = section;
            id header = dict[@"header"];
            id footer = dict[@"footer"];
            id rows = dict[@"rows"];
            IQFSPLog(@"  keys=%@", [dict.allKeys componentsJoinedByString:@", "]);
            IQFSPLog(@"  header=%@", header ?: @"nil");
            if (footer) IQFSPLog(@"  footer=%@", footer);
            IQFSPLog(@"  rows class=%@ count=%lu", rows ? NSStringFromClass([rows class]) : @"nil", [rows respondsToSelector:@selector(count)] ? (unsigned long)[rows count] : 0UL);
            if ([rows isKindOfClass:[NSArray class]]) {
                NSUInteger rowIndex = 0;
                for (id row in (NSArray *)rows) {
                    IQFSPLog(@"  row[%lu]", (unsigned long)rowIndex++);
                    IQFSPDescribeSetting(row, 4);
                }
            }
        } else {
            IQFSPLog(@"  value=%@", IQFSPShortDescription(section));
        }
    }
}

static void IQFSPDumpMethods(Class cls, BOOL classMethods) {
    if (!cls) return;
    Class target = classMethods ? object_getClass(cls) : cls;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count);
    IQFSPLog(@"=== %@ %@ METHODS (%u) ===", NSStringFromClass(cls), classMethods ? @"CLASS" : @"INSTANCE", count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        IQFSPLog(@"  %@%@ | args=%u | types=%@ | imp=%p",
                 classMethods ? @"+" : @"-",
                 NSStringFromSelector(sel),
                 method_getNumberOfArguments(methods[i]),
                 IQFSPCString(types),
                 method_getImplementation(methods[i]));
    }
    free(methods);
}

#pragma mark - IQFTweakSettings no-arg object-return tracing

static BOOL IQFSPCandidateClassSelector(NSString *name) {
    NSString *n = name.lowercaseString;
    return [n containsString:@"section"] ||
           [n containsString:@"setting"] ||
           [n containsString:@"panel"] ||
           [n containsString:@"config"] ||
           [n containsString:@"feature"] ||
           [n containsString:@"appearance"];
}

static id IQFSPNoArgClassTracer(id self, SEL _cmd) {
    NSString *name = NSStringFromSelector(_cmd);
    NSValue *boxed = IQFSPOriginalNoArgClassIMPs[name];
    IMP imp = boxed.pointerValue;
    IQFSPLog(@"ENTER +[%@ %@]", NSStringFromClass((Class)self), name);
    IQFSPDumpCallStack([NSString stringWithFormat:@"+[%@ %@]", NSStringFromClass((Class)self), name]);

    id result = nil;
    if (imp) {
        typedef id (*Fn)(id, SEL);
        result = ((Fn)imp)(self, _cmd);
    }

    IQFSPLog(@"EXIT  +[%@ %@] -> class=%@ ptr=%p", NSStringFromClass((Class)self), name, result ? NSStringFromClass([result class]) : @"nil", result);
    if ([result isKindOfClass:[NSArray class]] || [result isKindOfClass:[NSDictionary class]]) {
        IQFSPDescribeSections(result, [NSString stringWithFormat:@"RETURN +[%@ %@]", NSStringFromClass((Class)self), name]);
    }
    return result;
}

static void IQFSPInstallIQFTweakSettingsTracers(void) {
    Class cls = NSClassFromString(@"IQFTweakSettings");
    if (!cls) return;
    Class meta = object_getClass(cls);
    unsigned int count = 0;
    Method *methods = class_copyMethodList(meta, &count);
    for (unsigned int i = 0; i < count; i++) {
        Method m = methods[i];
        SEL sel = method_getName(m);
        NSString *name = NSStringFromSelector(sel);
        if (!IQFSPCandidateClassSelector(name)) continue;
        if (method_getNumberOfArguments(m) != 2 || !IQFSPMethodReturnsObject(m)) continue;
        IMP original = method_getImplementation(m);
        if (!original || original == (IMP)&IQFSPNoArgClassTracer) continue;
        IQFSPOriginalNoArgClassIMPs[name] = [NSValue valueWithPointer:original];
        method_setImplementation(m, (IMP)&IQFSPNoArgClassTracer);
        IQFSPLog(@"HOOKED +[IQFTweakSettings %@] types=%@ original=%p", name, IQFSPCString(method_getTypeEncoding(m)), original);
    }
    free(methods);
}

#pragma mark - IQFSettingsViewController data-source tracing

static NSInteger (*IQFSPOrigNumberOfSections)(id, SEL, UITableView *);
static NSInteger (*IQFSPOrigRowsInSection)(id, SEL, UITableView *, NSInteger);
static id (*IQFSPOrigCellForRow)(id, SEL, UITableView *, NSIndexPath *);
static id (*IQFSPOrigHeaderTitle)(id, SEL, UITableView *, NSInteger);

static NSInteger IQFSPNumberOfSections(id self, SEL _cmd, UITableView *table) {
    NSInteger value = IQFSPOrigNumberOfSections ? IQFSPOrigNumberOfSections(self, _cmd, table) : 0;
    IQFSPLog(@"CALL -[%@ numberOfSectionsInTableView:] -> %ld dataSource=%@", NSStringFromClass([self class]), (long)value, NSStringFromClass([table.dataSource class]));
    IQFSPDumpCallStack(@"numberOfSectionsInTableView:");
    return value;
}

static NSInteger IQFSPRowsInSection(id self, SEL _cmd, UITableView *table, NSInteger section) {
    NSInteger value = IQFSPOrigRowsInSection ? IQFSPOrigRowsInSection(self, _cmd, table, section) : 0;
    IQFSPLog(@"CALL -[%@ tableView:numberOfRowsInSection:%ld] -> %ld", NSStringFromClass([self class]), (long)section, (long)value);
    return value;
}

static id IQFSPCellForRow(id self, SEL _cmd, UITableView *table, NSIndexPath *indexPath) {
    id cell = IQFSPOrigCellForRow ? IQFSPOrigCellForRow(self, _cmd, table, indexPath) : nil;
    NSString *text = nil;
    if ([cell isKindOfClass:[UITableViewCell class]]) {
        UITableViewCell *c = cell;
        text = c.textLabel.text;
        if (text.length == 0) {
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            for (UIView *v in c.contentView.subviews) {
                if ([v isKindOfClass:[UILabel class]] && ((UILabel *)v).text.length) [parts addObject:((UILabel *)v).text];
            }
            text = [parts componentsJoinedByString:@" | "];
        }
    }
    IQFSPLog(@"CALL cellForRow section=%ld row=%ld -> class=%@ text=%@", (long)indexPath.section, (long)indexPath.row, cell ? NSStringFromClass([cell class]) : @"nil", text ?: @"(none)");
    return cell;
}

static id IQFSPHeaderTitle(id self, SEL _cmd, UITableView *table, NSInteger section) {
    id value = IQFSPOrigHeaderTitle ? IQFSPOrigHeaderTitle(self, _cmd, table, section) : nil;
    IQFSPLog(@"CALL titleForHeader section=%ld -> %@", (long)section, value ?: @"nil");
    return value;
}

static void IQFSPHookDirectInstanceMethod(Class cls, NSString *selectorName, IMP replacement, IMP *outOriginal, BOOL integerReturn, NSUInteger argumentCount) {
    SEL sel = NSSelectorFromString(selectorName);
    if (!IQFSPClassImplementsSelector(cls, sel)) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != argumentCount) return;
    BOOL returnOK = integerReturn ? IQFSPMethodReturnsIntegerLike(m) : IQFSPMethodReturnsObject(m);
    if (!returnOK) return;
    IMP original = method_getImplementation(m);
    if (!original || original == replacement) return;
    if (outOriginal) *outOriginal = original;
    method_setImplementation(m, replacement);
    IQFSPLog(@"HOOKED -[%@ %@] types=%@ original=%p", NSStringFromClass(cls), selectorName, IQFSPCString(method_getTypeEncoding(m)), original);
}

static void IQFSPInstallControllerTracers(void) {
    Class cls = NSClassFromString(@"IQFSettingsViewController");
    if (!cls) return;
    IQFSPHookDirectInstanceMethod(cls, @"numberOfSectionsInTableView:", (IMP)&IQFSPNumberOfSections, (IMP *)&IQFSPOrigNumberOfSections, YES, 3);
    IQFSPHookDirectInstanceMethod(cls, @"tableView:numberOfRowsInSection:", (IMP)&IQFSPRowsInSection, (IMP *)&IQFSPOrigRowsInSection, YES, 4);
    IQFSPHookDirectInstanceMethod(cls, @"tableView:cellForRowAtIndexPath:", (IMP)&IQFSPCellForRow, (IMP *)&IQFSPOrigCellForRow, NO, 4);
    IQFSPHookDirectInstanceMethod(cls, @"tableView:titleForHeaderInSection:", (IMP)&IQFSPHeaderTitle, (IMP *)&IQFSPOrigHeaderTitle, NO, 4);
}

#pragma mark - Passive visible UI snapshot

static UIViewController *IQFSPTopController(UIViewController *vc) {
    if (!vc) return nil;
    UIViewController *current = vc;
    while (YES) {
        UIViewController *next = nil;
        if (current.presentedViewController) {
            next = current.presentedViewController;
        } else if ([current isKindOfClass:[UINavigationController class]]) {
            next = ((UINavigationController *)current).visibleViewController;
        } else if ([current isKindOfClass:[UITabBarController class]]) {
            next = ((UITabBarController *)current).selectedViewController;
        } else if (current.childViewControllers.count == 1) {
            next = current.childViewControllers.firstObject;
        }
        if (!next || next == current) break;
        current = next;
    }
    return current;
}

static UITableView *IQFSPFindTable(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *sub in view.subviews) {
        UITableView *found = IQFSPFindTable(sub);
        if (found) return found;
    }
    return nil;
}

static void IQFSPSnapshotVisibleUI(void) {
    UIWindow *window = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (!w.hidden && w.alpha > 0 && w.rootViewController) {
            if (w.isKeyWindow) { window = w; break; }
            if (!window) window = w;
        }
    }
    UIViewController *top = IQFSPTopController(window.rootViewController);
    if (!top) return;

    NSString *name = NSStringFromClass([top class]);
    NSString *title = top.title ?: top.navigationItem.title ?: @"";
    BOOL relevant = [name hasPrefix:@"IQF"] || [title rangeOfString:@"iQFace" options:NSCaseInsensitiveSearch].location != NSNotFound;
    if (!relevant) return;

    UITableView *table = IQFSPFindTable(top.view);
    NSMutableArray<NSString *> *visible = [NSMutableArray array];
    for (UITableViewCell *cell in table.visibleCells ?: @[]) {
        NSMutableArray<NSString *> *texts = [NSMutableArray array];
        if (cell.textLabel.text.length) [texts addObject:cell.textLabel.text];
        if (cell.detailTextLabel.text.length) [texts addObject:cell.detailTextLabel.text];
        for (UIView *v in cell.contentView.subviews) {
            if ([v isKindOfClass:[UILabel class]] && ((UILabel *)v).text.length) [texts addObject:((UILabel *)v).text];
        }
        [visible addObject:[NSString stringWithFormat:@"%@{%@}", NSStringFromClass([cell class]), [texts componentsJoinedByString:@" | "]]];
    }

    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@", name, title, [visible componentsJoinedByString:@";"]];
    if ([signature isEqualToString:IQFSPLastUISignature]) return;
    IQFSPLastUISignature = signature;

    IQFSPLog(@"=== VISIBLE SETTINGS SNAPSHOT ===");
    IQFSPLog(@"controller=%@ title=%@ ptr=%p", name, title, top);
    IQFSPLog(@"table=%p dataSource=%@ delegate=%@ sections=%ld", table, table.dataSource ? NSStringFromClass([table.dataSource class]) : @"nil", table.delegate ? NSStringFromClass([table.delegate class]) : @"nil", (long)table.numberOfSections);
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        IQFSPLog(@"  section[%ld] rows=%ld", (long)section, (long)[table numberOfRowsInSection:section]);
    }
    for (NSString *item in visible) IQFSPLog(@"  visible %@", item);
}

static void IQFSPStartUITimer(void) {
    IQFSPUITimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(IQFSPUITimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                              (uint64_t)(1.0 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(IQFSPUITimer, ^{
        @autoreleasepool { IQFSPSnapshotVisibleUI(); }
    });
    dispatch_resume(IQFSPUITimer);
}

static void IQFSPInstall(void) {
    if (IQFSPInstalled) return;
    IQFSPInstallAttempts++;

    Class tweakSettings = NSClassFromString(@"IQFTweakSettings");
    Class setting = NSClassFromString(@"IQFSetting");
    Class controller = NSClassFromString(@"IQFSettingsViewController");
    if (!tweakSettings || !setting || !controller) {
        if (IQFSPInstallAttempts < 120) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ IQFSPInstall(); });
        }
        return;
    }

    IQFSPInstalled = YES;
    IQFSPLog(@"FOUND IQFTweakSettings=%p IQFSetting=%p IQFSettingsViewController=%p", tweakSettings, setting, controller);
    IQFSPDumpMethods(tweakSettings, YES);
    IQFSPDumpMethods(tweakSettings, NO);
    IQFSPDumpMethods(setting, YES);
    IQFSPDumpMethods(controller, NO);
    IQFSPInstallIQFTweakSettingsTracers();
    IQFSPInstallControllerTracers();
    IQFSPStartUITimer();
    IQFSPLog(@"Probe armed. Open iQFace and enter a few sections; no settings data will be modified.");
}

__attribute__((constructor))
static void IQFSPInitialize(void) {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleID isEqualToString:@"com.facebook.Facebook"] || [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) return;

        IQFSPWriteQueue = dispatch_queue_create("com.lucas.iqfacesettingsprobe.writer", DISPATCH_QUEUE_SERIAL);
        IQFSPOriginalNoArgClassIMPs = [NSMutableDictionary dictionary];

        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *dir = [docs stringByAppendingPathComponent:@"iQFaceSettingsProbe"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        IQFSPReportPath = [dir stringByAppendingPathComponent:@"iQFaceSettingsProbe.txt"];
        [[NSFileManager defaultManager] createFileAtPath:IQFSPReportPath contents:nil attributes:nil];

        NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
        IQFSPLog(@"=== iQFaceSettingsProbe 1.0.0 ===");
        IQFSPLog(@"Facebook %@ (%@)", info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?");
        IQFSPLog(@"iOS %@", UIDevice.currentDevice.systemVersion ?: @"?");
        IQFSPLog(@"PASSIVE MODE: no sections/rows/defaults are changed by this probe");

        dispatch_async(dispatch_get_main_queue(), ^{ IQFSPInstall(); });
    }
}
