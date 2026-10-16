#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

// XLiquidGlass Tab Selection Probe 1.0
// Passive diagnostic for X 12.35+ active-tab state.
// It does NOT tint icons and does NOT hook selection/update/layout methods.
// Runtime hooks are limited to the NeoFreeBird settings entry.

static NSString *const kXSPLogFileName = @"XLiquidGlassTabSelectionProbe.log";
static const NSUInteger kXSPMaxLogBytes = 4 * 1024 * 1024;
static const NSTimeInterval kXSPPollInterval = 0.25;

static IMP gXSPOrigNFBSetupSections = NULL;
static IMP gXSPOrigNFBViewWillAppear = NULL;
static BOOL gXSPNFBHookInstalled = NO;

static BOOL gXSPCaptureActive = NO;
static NSUInteger gXSPCaptureGeneration = 0;
static NSUInteger gXSPSnapshotCount = 0;
static NSString *gXSPLastSignature = nil;

#pragma mark - Log

static NSString *XSPLogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kXSPLogFileName];
}

static NSString *XSPStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:NSDate.date];
}

static NSString *XSPText(id value) {
    if (!value || value == NSNull.null) return @"nil";
    NSString *text = [value description] ?: @"nil";
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (text.length > 420) text = [[text substringToIndex:420] stringByAppendingString:@"…"];
    return text.length ? text : @"-";
}

static void XSPTrimLogIfNeeded(void) {
    NSString *path = XSPLogPath();
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size <= kXSPMaxLogBytes) return;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length <= kXSPMaxLogBytes) return;
    NSUInteger keep = kXSPMaxLogBytes / 2;
    NSData *tail = [data subdataWithRange:NSMakeRange(data.length - keep, keep)];
    [tail writeToFile:path atomically:YES];
}

static void XSPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void XSPLog(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", XSPStamp(), body ?: @""];
    NSLog(@"[XLiquidGlassTabSelectionProbe] %@", body ?: @"");

    @synchronized(NSFileManager.defaultManager) {
        NSString *path = XSPLogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
        XSPTrimLogIfNeeded();
    }
}

static NSString *XSPReadLog(void) {
    return [NSString stringWithContentsOfFile:XSPLogPath()
                                      encoding:NSUTF8StringEncoding
                                         error:nil] ?: @"";
}

static void XSPResetLog(void) {
    [NSFileManager.defaultManager removeItemAtPath:XSPLogPath() error:nil];
    gXSPLastSignature = nil;
    gXSPSnapshotCount = 0;
    XSPLog(@"========== LOG RESET ==========");
    XSPLog(@"Read-only probe: no selection/layout/tint method hooks.");
}

#pragma mark - Runtime helpers

static id XSPSafeValueForKey(id object, NSString *key, BOOL *ok) {
    if (ok) *ok = NO;
    if (!object || !key.length) return nil;
    @try {
        id value = [object valueForKey:key];
        if (ok) *ok = YES;
        return value;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL XSPHookMethod(Class cls, SEL sel, IMP replacement, IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    IMP current = class_getMethodImplementation(cls, sel);
    if (current == replacement) return YES;
    if (originalOut && !*originalOut) *originalOut = current;
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    return class_getMethodImplementation(cls, sel) == replacement;
}

static const char *XSPBaseType(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') type++;
    return type;
}

static BOOL XSPInterestingName(NSString *name) {
    NSString *lower = name.lowercaseString ?: @"";
    return [lower containsString:@"select"] ||
           [lower containsString:@"index"] ||
           [lower containsString:@"item"] ||
           [lower containsString:@"tab"] ||
           [lower containsString:@"current"] ||
           [lower containsString:@"active"];
}

static NSString *XSPGetterValue(id object, NSString *selectorName) {
    if (!object) return @"<no-object>";
    SEL sel = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod([object class], sel);
    if (!method || method_getNumberOfArguments(method) != 2 || ![object respondsToSelector:sel]) {
        return @"<unavailable>";
    }

    char *raw = method_copyReturnType(method);
    const char *type = XSPBaseType(raw);
    NSString *result = nil;

    switch (type[0]) {
        case '@':
        case '#': {
            id value = ((id(*)(id,SEL))objc_msgSend)(object, sel);
            result = [NSString stringWithFormat:@"object:%@:%@",
                      value ? NSStringFromClass([value class]) : @"nil", XSPText(value)];
            break;
        }
        case 'B':
        case 'c':
        case 'C': {
            BOOL value = ((BOOL(*)(id,SEL))objc_msgSend)(object, sel);
            result = [NSString stringWithFormat:@"bool:%d", value];
            break;
        }
        case 'q': case 'l': case 'i': case 's': {
            long long value = ((long long(*)(id,SEL))objc_msgSend)(object, sel);
            result = [NSString stringWithFormat:@"signed:%lld", value];
            break;
        }
        case 'Q': case 'L': case 'I': case 'S': {
            unsigned long long value = ((unsigned long long(*)(id,SEL))objc_msgSend)(object, sel);
            result = [NSString stringWithFormat:@"unsigned:%llu", value];
            break;
        }
        default:
            result = [NSString stringWithFormat:@"<return:%s>", type];
            break;
    }

    if (raw) free(raw);
    return result ?: @"<nil>";
}

#pragma mark - View discovery

static BOOL XSPIsTabBarView(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return [name isEqualToString:@"XNavigation.TabBarView"] ||
           [name hasSuffix:@".TabBarView"] || [name hasSuffix:@"TabBarView"];
}

static BOOL XSPIsTabBarItemView(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return [name isEqualToString:@"XNavigation.TabBarItemView"] ||
           [name hasSuffix:@".TabBarItemView"] || [name hasSuffix:@"TabBarItemView"];
}

static void XSPCollectBars(UIView *view, NSMutableArray<UIView *> *bars,
                           NSMutableSet<NSValue *> *seen) {
    if (!view) return;
    if (XSPIsTabBarView(view)) {
        NSValue *key = [NSValue valueWithNonretainedObject:view];
        if (![seen containsObject:key]) {
            [seen addObject:key];
            [bars addObject:view];
        }
    }
    for (UIView *subview in view.subviews ?: @[]) XSPCollectBars(subview, bars, seen);
}

static NSArray<UIView *> *XSPAllTabBars(void) {
    NSMutableArray<UIView *> *bars = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            XSPCollectBars(window, bars, seen);
        }
    }
    return bars;
}

static void XSPCollectItems(UIView *view, NSMutableArray<UIView *> *items) {
    if (!view) return;
    if (XSPIsTabBarItemView(view)) [items addObject:view];
    for (UIView *subview in view.subviews ?: @[]) XSPCollectItems(subview, items);
}

#pragma mark - Metadata

static void XSPDumpClassMetadata(Class cls, NSString *label) {
    if (!cls) return;
    XSPLog(@"CLASS_DUMP_BEGIN %@ class=%@ super=%@",
           label, NSStringFromClass(cls), NSStringFromClass(class_getSuperclass(cls)));

    for (Class current = cls; current && current != NSObject.class; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *rawName = ivar_getName(ivars[i]);
            NSString *name = rawName ? [NSString stringWithUTF8String:rawName] : @"";
            if (XSPInterestingName(name)) {
                XSPLog(@"IVAR owner=%@ name=%@ type=%s offset=%td",
                       NSStringFromClass(current), name,
                       ivar_getTypeEncoding(ivars[i]) ?: "-", ivar_getOffset(ivars[i]));
            }
        }
        free(ivars);

        count = 0;
        objc_property_t *properties = class_copyPropertyList(current, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *rawName = property_getName(properties[i]);
            NSString *name = rawName ? [NSString stringWithUTF8String:rawName] : @"";
            if (XSPInterestingName(name)) {
                XSPLog(@"PROPERTY owner=%@ name=%@ attrs=%s",
                       NSStringFromClass(current), name,
                       property_getAttributes(properties[i]) ?: "-");
            }
        }
        free(properties);

        count = 0;
        Method *methods = class_copyMethodList(current, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if (XSPInterestingName(name)) {
                XSPLog(@"METHOD owner=%@ selector=%@ argc=%u types=%s",
                       NSStringFromClass(current), name,
                       method_getNumberOfArguments(methods[i]),
                       method_getTypeEncoding(methods[i]) ?: "-");
            }
        }
        free(methods);
        if (current == UIView.class) break;
    }
    XSPLog(@"CLASS_DUMP_END %@", label);
}

static NSString *XSPIvarValue(id object, Ivar ivar) {
    const char *type = XSPBaseType(ivar_getTypeEncoding(ivar));
    ptrdiff_t offset = ivar_getOffset(ivar);
    uint8_t *address = (uint8_t *)(__bridge void *)object + offset;

    switch (type[0]) {
        case '@': {
            id value = object_getIvar(object, ivar);
            return [NSString stringWithFormat:@"object:%@:%@",
                    value ? NSStringFromClass([value class]) : @"nil", XSPText(value)];
        }
        case 'B': return [NSString stringWithFormat:@"bool:%d", *(BOOL *)address ? 1 : 0];
        case 'c': return [NSString stringWithFormat:@"char:%d", *(signed char *)address];
        case 'C': return [NSString stringWithFormat:@"uchar:%u", *(unsigned char *)address];
        case 'i': return [NSString stringWithFormat:@"int:%d", *(int *)address];
        case 'I': return [NSString stringWithFormat:@"uint:%u", *(unsigned int *)address];
        case 'q': return [NSString stringWithFormat:@"ll:%lld", *(long long *)address];
        case 'Q': return [NSString stringWithFormat:@"ull:%llu", *(unsigned long long *)address];
        default: return [NSString stringWithFormat:@"<type:%s>", type];
    }
}

static void XSPAppendIvarState(NSMutableArray<NSString *> *lines, id object) {
    for (Class current = [object class]; current && current != NSObject.class; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *rawName = ivar_getName(ivars[i]);
            NSString *name = rawName ? [NSString stringWithUTF8String:rawName] : @"";
            if (!XSPInterestingName(name)) continue;
            [lines addObject:[NSString stringWithFormat:@"IVAR_STATE owner=%@ name=%@ value=%@",
                              NSStringFromClass(current), name, XSPIvarValue(object, ivars[i])]];
        }
        free(ivars);
        if (current == UIView.class) break;
    }
}

#pragma mark - Snapshot

static NSArray<NSString *> *XSPCandidateKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[@"itemViews", @"selectedIndex", @"selectedItemView", @"selectedItem",
                 @"selection", @"selectedTab", @"selectedTabIndex", @"currentIndex",
                 @"currentSelectedIndex", @"activeItem", @"activeIndex", @"tabItems"];
    });
    return keys;
}

static void XSPCaptureSnapshot(NSString *reason, BOOL force) {
    NSArray<UIView *> *bars = XSPAllTabBars();
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSMutableString *signature = [NSMutableString stringWithFormat:@"bars:%lu", (unsigned long)bars.count];

    [lines addObject:[NSString stringWithFormat:@"SNAPSHOT_BEGIN reason=%@ bars=%lu",
                      reason ?: @"unknown", (unsigned long)bars.count]];

    NSUInteger barNumber = 0;
    for (UIView *bar in bars) {
        [lines addObject:[NSString stringWithFormat:
            @"BAR[%lu] ptr=%p class=%@ super=%@ frame=%@ hidden=%d alpha=%.3f window=%p",
            (unsigned long)barNumber, bar, NSStringFromClass(bar.class),
            NSStringFromClass(class_getSuperclass(bar.class)), NSStringFromCGRect(bar.frame),
            bar.hidden, bar.alpha, bar.window]];
        [signature appendFormat:@"|bar:%p:%@", bar, NSStringFromClass(bar.class)];

        for (NSString *key in XSPCandidateKeys()) {
            BOOL ok = NO;
            id value = XSPSafeValueForKey(bar, key, &ok);
            NSString *className = value ? NSStringFromClass([value class]) : @"nil";
            NSString *text = XSPText(value);
            NSString *getter = XSPGetterValue(bar, key);
            [lines addObject:[NSString stringWithFormat:@"KVC key=%@ ok=%d class=%@ value=%@",
                              key, ok, className, text]];
            [lines addObject:[NSString stringWithFormat:@"GETTER selector=%@ value=%@", key, getter]];
            [signature appendFormat:@"|%@:%d:%@:%@:%@", key, ok, className, text, getter];
        }

        XSPAppendIvarState(lines, bar);

        NSMutableArray<UIView *> *items = [NSMutableArray array];
        XSPCollectItems(bar, items);
        [lines addObject:[NSString stringWithFormat:@"ITEM_SCAN count=%lu", (unsigned long)items.count]];
        [signature appendFormat:@"|items:%lu", (unsigned long)items.count];

        BOOL itemViewsOK = NO;
        id itemViewsValue = XSPSafeValueForKey(bar, @"itemViews", &itemViewsOK);
        NSArray *itemViews = [itemViewsValue isKindOfClass:NSArray.class] ? itemViewsValue : nil;

        BOOL selectedIndexOK = NO;
        id selectedIndexValue = XSPSafeValueForKey(bar, @"selectedIndex", &selectedIndexOK);
        BOOL hasSelectedIndex = [selectedIndexValue respondsToSelector:@selector(integerValue)];
        NSInteger selectedIndex = hasSelectedIndex ? [selectedIndexValue integerValue] : -1;

        for (NSUInteger i = 0; i < items.count; i++) {
            UIView *item = items[i];
            NSUInteger arrayIndex = itemViews ? [itemViews indexOfObjectIdenticalTo:item] : NSNotFound;
            BOOL traitSelected = (item.accessibilityTraits & UIAccessibilityTraitSelected) != 0;

            BOOL selectedOK = NO;
            id selected = XSPSafeValueForKey(item, @"selected", &selectedOK);
            BOOL isSelectedOK = NO;
            id isSelected = XSPSafeValueForKey(item, @"isSelected", &isSelectedOK);

            [lines addObject:[NSString stringWithFormat:
                @"ITEM[%lu] ptr=%p class=%@ frame=%@ arrayIndex=%@ traitSelected=%d label=%@ id=%@ value=%@ selectedKVC(ok=%d,value=%@) isSelectedKVC(ok=%d,value=%@)",
                (unsigned long)i, item, NSStringFromClass(item.class), NSStringFromCGRect(item.frame),
                arrayIndex == NSNotFound ? @"NSNotFound" : [NSString stringWithFormat:@"%lu", (unsigned long)arrayIndex],
                traitSelected, XSPText(item.accessibilityLabel), XSPText(item.accessibilityIdentifier),
                XSPText(item.accessibilityValue), selectedOK, XSPText(selected), isSelectedOK, XSPText(isSelected)]];

            [signature appendFormat:@"|item:%p:%lu:%d:%@:%@:%@",
             item, (unsigned long)arrayIndex, traitSelected,
             XSPText(item.accessibilityLabel), XSPText(selected), XSPText(isSelected)];
        }

        if (itemViews && hasSelectedIndex) {
            id selectedObject = (selectedIndex >= 0 && selectedIndex < (NSInteger)itemViews.count)
                ? itemViews[(NSUInteger)selectedIndex] : nil;
            [lines addObject:[NSString stringWithFormat:
                @"DERIVED itemViewsCount=%lu selectedIndex=%ld selectedObject=%p class=%@",
                (unsigned long)itemViews.count, (long)selectedIndex, selectedObject,
                selectedObject ? NSStringFromClass([selectedObject class]) : @"nil"]];
        } else {
            [lines addObject:[NSString stringWithFormat:
                @"DERIVED unavailable itemViewsOK=%d itemViewsClass=%@ selectedIndexOK=%d selectedIndexClass=%@ value=%@",
                itemViewsOK, itemViewsValue ? NSStringFromClass([itemViewsValue class]) : @"nil",
                selectedIndexOK, selectedIndexValue ? NSStringFromClass([selectedIndexValue class]) : @"nil",
                XSPText(selectedIndexValue)]];
        }
        barNumber++;
    }

    [lines addObject:@"SNAPSHOT_END"];
    if (!force && [signature isEqualToString:gXSPLastSignature]) return;

    gXSPLastSignature = [signature copy];
    gXSPSnapshotCount++;
    XSPLog(@"---------- SNAPSHOT #%lu ----------", (unsigned long)gXSPSnapshotCount);
    for (NSString *line in lines) XSPLog(@"%@", line);
}

static void XSPDumpCurrentMetadata(void) {
    NSArray<UIView *> *bars = XSPAllTabBars();
    if (!bars.count) {
        XSPLog(@"METADATA: no XNavigation.TabBarView currently found.");
        return;
    }
    UIView *bar = bars.firstObject;
    XSPDumpClassMetadata(bar.class, @"TabBarView");

    NSMutableArray<UIView *> *items = [NSMutableArray array];
    XSPCollectItems(bar, items);
    if (items.count) XSPDumpClassMetadata(items.firstObject.class, @"TabBarItemView");
}

#pragma mark - Capture loop

static void XSPSchedulePoll(NSUInteger generation) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kXSPPollInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gXSPCaptureActive || generation != gXSPCaptureGeneration) return;
        XSPCaptureSnapshot(@"poll", NO);
        XSPSchedulePoll(generation);
    });
}

static void XSPSetCaptureActive(BOOL active) {
    if (gXSPCaptureActive == active) return;
    gXSPCaptureActive = active;
    gXSPCaptureGeneration++;
    NSUInteger generation = gXSPCaptureGeneration;

    if (active) {
        gXSPLastSignature = nil;
        XSPLog(@"========== CAPTURE START ==========");
        XSPLog(@"pollInterval=%.2fs", kXSPPollInterval);
        XSPDumpCurrentMetadata();
        XSPCaptureSnapshot(@"start", YES);
        XSPSchedulePoll(generation);
    } else {
        XSPCaptureSnapshot(@"stop", YES);
        XSPLog(@"========== CAPTURE STOP snapshots=%lu ==========",
               (unsigned long)gXSPSnapshotCount);
    }
}

#pragma mark - UI

@interface XLiquidGlassTabSelectionProbeViewController : UITableViewController
@end

@implementation XLiquidGlassTabSelectionProbeViewController

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Tab Selection Probe";
    self.tableView.backgroundColor = UIColor.systemBackgroundColor;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; return section == 0 ? 2 : 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return section == 0 ? @"Captura" : @"Relatório";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return @"Ative a captura, volte ao X e alterne entre Home, Pesquisa, Notificações e Mensagens. O probe apenas observa a Tab Bar.";
    }
    return [NSString stringWithFormat:@"Log: %@", XSPLogPath()];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"XLiquidGlassTabSelectionProbeCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 2;

    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.textLabel.text = @"Captura contínua";
        cell.detailTextLabel.text = @"Registra um snapshot somente quando o estado observado muda.";
        UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
        toggle.on = gXSPCaptureActive;
        [toggle addTarget:self action:@selector(xspCaptureChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 0) {
        cell.textLabel.text = @"Capturar estado agora";
        cell.detailTextLabel.text = @"Força metadata + snapshot completo da Tab Bar.";
    } else if (indexPath.row == 0) {
        cell.textLabel.text = @"Limpar log";
        cell.detailTextLabel.text = @"Reinicia o relatório antes do teste.";
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"Copiar relatório";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu caracteres no log.",
                                     (unsigned long)XSPReadLog().length];
    } else {
        cell.textLabel.text = @"Compartilhar .log";
        cell.detailTextLabel.text = @"Compartilha o arquivo bruto do diagnóstico.";
    }
    return cell;
}

- (void)xspCaptureChanged:(UISwitch *)sender {
    XSPSetCaptureActive(sender.isOn);
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0 && indexPath.row == 1) {
        XSPDumpCurrentMetadata();
        XSPCaptureSnapshot(@"manual", YES);
        [tableView reloadData];
        return;
    }

    if (indexPath.section == 1 && indexPath.row == 0) {
        XSPResetLog();
        if (gXSPCaptureActive) XSPCaptureSnapshot(@"after-reset", YES);
        [tableView reloadData];
        return;
    }

    if (indexPath.section == 1 && indexPath.row == 1) {
        NSString *report = XSPReadLog();
        UIPasteboard.generalPasteboard.string = report;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Tab Selection Probe"
                             message:[NSString stringWithFormat:@"Relatório copiado (%lu caracteres).",
                                      (unsigned long)report.length]
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    if (indexPath.section == 1 && indexPath.row == 2) {
        if (![NSFileManager.defaultManager fileExistsAtPath:XSPLogPath()]) XSPResetLog();
        UIActivityViewController *share = [[UIActivityViewController alloc]
            initWithActivityItems:@[[NSURL fileURLWithPath:XSPLogPath()]] applicationActivities:nil];
        if (share.popoverPresentationController) {
            share.popoverPresentationController.sourceView = self.view;
            share.popoverPresentationController.sourceRect = CGRectMake(
                CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        }
        [self presentViewController:share animated:YES completion:nil];
    }
}
@end

#pragma mark - NeoFreeBird menu

static BOOL XSPSectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if ([entry isKindOfClass:NSDictionary.class] &&
            [entry[@"action"] isEqualToString:@"showXLiquidGlassTabSelectionProbe"]) return YES;
    }
    return NO;
}

static void XSPInjectNFBSection(id controller) {
    NSArray *sections = nil;
    @try { sections = [controller valueForKey:@"sections"]; }
    @catch (__unused NSException *exception) { return; }
    if (![sections isKindOfClass:NSArray.class] || XSPSectionsContainEntry(sections)) return;

    NSMutableArray *updated = [sections mutableCopy];
    [updated addObject:@{
        @"title": @"Tab Selection Probe",
        @"subtitle": @"Diagnóstico passivo da aba ativa da Tab Bar.",
        @"icon": @"flask",
        @"action": @"showXLiquidGlassTabSelectionProbe"
    }];
    @try { [controller setValue:[updated copy] forKey:@"sections"]; }
    @catch (__unused NSException *exception) {}
}

static void XSPNFBSetupSections(id self, SEL _cmd) {
    if (gXSPOrigNFBSetupSections) ((void(*)(id,SEL))gXSPOrigNFBSetupSections)(self, _cmd);
    XSPInjectNFBSection(self);
}

static void XSPNFBViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gXSPOrigNFBViewWillAppear) ((void(*)(id,SEL,BOOL))gXSPOrigNFBViewWillAppear)(self, _cmd, animated);
    XSPInjectNFBSection(self);
    UITableView *tableView = nil;
    @try { tableView = [self valueForKey:@"tableView"]; }
    @catch (__unused NSException *exception) {}
    [tableView reloadData];
}

static void XSPShowProbe(id self, SEL _cmd) {
    (void)_cmd;
    if (![self isKindOfClass:UIViewController.class]) return;
    XLiquidGlassTabSelectionProbeViewController *probe = [[XLiquidGlassTabSelectionProbeViewController alloc] init];
    UINavigationController *nav = ((UIViewController *)self).navigationController;
    if (nav) [nav pushViewController:probe animated:YES];
    else {
        UINavigationController *wrapper = [[UINavigationController alloc] initWithRootViewController:probe];
        [(UIViewController *)self presentViewController:wrapper animated:YES completion:nil];
    }
}

static void XSPInstallNFBIntegration(void) {
    if (gXSPNFBHookInstalled) return;
    Class cls = NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;

    SEL showSEL = NSSelectorFromString(@"showXLiquidGlassTabSelectionProbe");
    if (![cls instancesRespondToSelector:showSEL]) class_addMethod(cls, showSEL, (IMP)XSPShowProbe, "v@:");

    BOOL setup = XSPHookMethod(cls, NSSelectorFromString(@"setupSections"),
                               (IMP)XSPNFBSetupSections, &gXSPOrigNFBSetupSections);
    BOOL appear = XSPHookMethod(cls, @selector(viewWillAppear:),
                                (IMP)XSPNFBViewWillAppear, &gXSPOrigNFBViewWillAppear);
    gXSPNFBHookInstalled = setup || appear;
    if (gXSPNFBHookInstalled) XSPLog(@"Installed NeoFreeBird Tab Selection Probe menu.");
}

static void XSPScheduleInstall(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ XSPInstallNFBIntegration(); });
}

__attribute__((constructor))
static void XLiquidGlassTabSelectionProbeInit(void) {
    @autoreleasepool {
        XSPLog(@"========== XLiquidGlass Tab Selection Probe 1.0 loaded ==========");
        XSPLog(@"logPath=%@", XSPLogPath());
        XSPLog(@"Read-only probe: no selection/layout/tint method hooks.");
        XSPInstallNFBIntegration();
        XSPScheduleInstall(0.00);
        XSPScheduleInstall(0.05);
        XSPScheduleInstall(0.20);
        XSPScheduleInstall(0.50);
        XSPScheduleInstall(1.00);
        XSPScheduleInstall(2.00);
        XSPScheduleInstall(4.00);
    }
}
