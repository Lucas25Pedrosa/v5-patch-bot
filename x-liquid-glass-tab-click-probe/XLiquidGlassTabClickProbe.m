#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kTCPLogFileName = @"XLiquidGlassTabClickProbe.log";
static const NSUInteger kTCPMaxLogBytes = 4 * 1024 * 1024;

static BOOL gCaptureArmed = NO;
static BOOL gCaptureWindow = NO;
static NSUInteger gCaptureSerial = 0;

static IMP gOrigUIApplicationSendEvent = NULL;
static IMP gOrigBarLayoutSubviews = NULL;
static IMP gOrigItemLayoutSubviews = NULL;
static IMP gOrigBarSetTintColor = NULL;
static IMP gOrigItemSetTintColor = NULL;
static IMP gOrigBarSetSelectedIndex = NULL;
static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;

#pragma mark - Log

static NSString *TCPLogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kTCPLogFileName];
}

static NSString *TCPStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:NSDate.date];
}

static NSString *TCPText(id value) {
    if (!value || value == NSNull.null) return @"-";
    NSString *text = [value description] ?: @"-";
    if (text.length > 1200) {
        text = [[text substringToIndex:1200] stringByAppendingString:@"…"];
    }
    return text.length ? text : @"-";
}

static void TCPTrimLog(void) {
    NSString *path = TCPLogPath();
    NSDictionary *attrs =
        [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size <= kTCPMaxLogBytes) return;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length <= kTCPMaxLogBytes) return;

    NSUInteger keep = kTCPMaxLogBytes / 2;
    NSData *tail = [data subdataWithRange:NSMakeRange(data.length - keep, keep)];
    [tail writeToFile:path atomically:YES];
}

static void TCPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void TCPLog(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"[%@] %@\n", TCPStamp(), body ?: @""];
    NSLog(@"[XLiquidGlassTabClickProbe] %@", body ?: @"");

    @synchronized(NSFileManager.defaultManager) {
        NSString *path = TCPLogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [@"" writeToFile:path atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
        TCPTrimLog();
    }
}

#pragma mark - Safe helpers

static id TCPSafeValue(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static Class TCPClass(NSString *demangled, NSString *mangled) {
    Class cls = NSClassFromString(demangled);
    if (!cls && mangled.length) cls = NSClassFromString(mangled);
    if (!cls && mangled.length) cls = objc_getClass(mangled.UTF8String);
    return cls;
}

static BOOL TCPHookInstanceMethod(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (!cls || !sel || !replacement) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP current = class_getMethodImplementation(cls, sel);
    if (current == replacement) return YES;
    if (original && !*original) *original = current;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    class_replaceMethod(cls, sel, replacement, types);
    return class_getMethodImplementation(cls, sel) == replacement;
}

static UIView *TCPAncestorMatching(UIView *view, NSString *needle) {
    for (UIView *cursor = view; cursor; cursor = cursor.superview) {
        if ([NSStringFromClass(cursor.class) containsString:needle]) return cursor;
    }
    return nil;
}

static NSArray<UIView *> *TCPFindViewsNamed(NSString *needle) {
    NSMutableArray<UIView *> *result = [NSMutableArray array];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;

        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) {
            if (![window isKindOfClass:UIWindow.class] || window.hidden) continue;

            NSMutableArray<UIView *> *queue =
                [NSMutableArray arrayWithObject:window];

            for (NSUInteger i=0; i<queue.count && i<4096; i++) {
                UIView *view = queue[i];
                if ([NSStringFromClass(view.class) containsString:needle]) {
                    [result addObject:view];
                }
                [queue addObjectsFromArray:view.subviews ?: @[]];
            }
        }
    }

    return result;
}

static NSString *TCPColor(UIColor *color) {
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

    return TCPText(color);
}

static NSInteger TCPSelectedIndex(UIView *bar) {
    id value = TCPSafeValue(bar, @"selectedIndex");
    return [value respondsToSelector:@selector(integerValue)]
        ? [value integerValue]
        : NSNotFound;
}

static NSArray *TCPItemViews(UIView *bar) {
    id value = TCPSafeValue(bar, @"itemViews");
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

static NSInteger TCPIndexOfItem(UIView *bar, UIView *item) {
    NSArray *items = TCPItemViews(bar);
    if (!items || !item) return NSNotFound;
    NSUInteger index = [items indexOfObjectIdenticalTo:item];
    return index == NSNotFound ? NSNotFound : (NSInteger)index;
}

#pragma mark - Snapshot

static void TCPLogImageViews(UIView *root, NSInteger itemIndex) {
    if (!root) return;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger imageIndex = 0;
    NSUInteger labelIndex = 0;

    for (NSUInteger i=0; i<queue.count && i<256; i++) {
        UIView *view = queue[i];

        if ([view isKindOfClass:UIImageView.class]) {
            UIImageView *iv = (UIImageView *)view;
            TCPLog(@"IMAGE item=%ld n=%lu class=%@ ptr=%p tint=%@ alpha=%.3f hidden=%d renderingMode=%ld image=%p",
                   (long)itemIndex,
                   (unsigned long)imageIndex++,
                   NSStringFromClass(iv.class),
                   iv,
                   TCPColor(iv.tintColor),
                   iv.alpha,
                   iv.hidden,
                   (long)iv.image.renderingMode,
                   iv.image);
        } else if ([view isKindOfClass:UILabel.class]) {
            UILabel *label = (UILabel *)view;
            TCPLog(@"LABEL item=%ld n=%lu class=%@ ptr=%p text=%@ color=%@ alpha=%.3f hidden=%d",
                   (long)itemIndex,
                   (unsigned long)labelIndex++,
                   NSStringFromClass(label.class),
                   label,
                   TCPText(label.text),
                   TCPColor(label.textColor),
                   label.alpha,
                   label.hidden);
        }

        [queue addObjectsFromArray:view.subviews ?: @[]];
    }
}

static void TCPSnapshotBar(UIView *bar, NSString *reason) {
    if (!bar) {
        TCPLog(@"SNAPSHOT_BAR reason=%@ bar=nil", reason ?: @"-");
        return;
    }

    NSArray *items = TCPItemViews(bar);
    NSInteger selected = TCPSelectedIndex(bar);

    TCPLog(@"SNAPSHOT_BAR reason=%@ class=%@ ptr=%p selectedIndex=%@ itemCount=%lu tint=%@ bg=%@ alpha=%.3f hidden=%d frame=%@",
           reason ?: @"-",
           NSStringFromClass(bar.class),
           bar,
           selected == NSNotFound ? @"?" : [NSString stringWithFormat:@"%ld",(long)selected],
           (unsigned long)items.count,
           TCPColor(bar.tintColor),
           TCPColor(bar.backgroundColor),
           bar.alpha,
           bar.hidden,
           NSStringFromCGRect(bar.frame));

    for (NSUInteger i=0; i<items.count; i++) {
        id object = items[i];
        if (![object isKindOfClass:UIView.class]) {
            TCPLog(@"ITEM index=%lu class=%@ nonUIView=%@",
                   (unsigned long)i,
                   NSStringFromClass([object class]),
                   TCPText(object));
            continue;
        }

        UIView *item = (UIView *)object;
        id onTap = TCPSafeValue(item, @"onTap");
        id onActivate = TCPSafeValue(item, @"onActivate");

        TCPLog(@"ITEM index=%lu selectedByIndex=%d class=%@ ptr=%p label=%@ traits=0x%llx tint=%@ bg=%@ alpha=%.3f hidden=%d frame=%@ onTapClass=%@ onActivateClass=%@",
               (unsigned long)i,
               selected != NSNotFound && selected == (NSInteger)i,
               NSStringFromClass(item.class),
               item,
               TCPText(item.accessibilityLabel),
               (unsigned long long)item.accessibilityTraits,
               TCPColor(item.tintColor),
               TCPColor(item.backgroundColor),
               item.alpha,
               item.hidden,
               NSStringFromCGRect(item.frame),
               onTap ? NSStringFromClass([onTap class]) : @"nil",
               onActivate ? NSStringFromClass([onActivate class]) : @"nil");

        TCPLogImageViews(item, (NSInteger)i);
    }

    TCPLog(@"BAR_SUBVIEWS reason=%@ classes=%@",
           reason ?: @"-",
           [[bar.subviews valueForKey:@"class"] valueForKey:@"description"]);
}

static void TCPSnapshotAll(NSString *reason) {
    NSArray<UIView *> *bars = TCPFindViewsNamed(@"XNavigation.TabBarView");
    TCPLog(@"========== SNAPSHOT %@ bars=%lu ==========",
           reason ?: @"-",
           (unsigned long)bars.count);

    for (UIView *bar in bars) {
        TCPSnapshotBar(bar, reason);
    }
}

#pragma mark - Runtime dump

static BOOL TCPInterestingMethodName(NSString *name) {
    NSString *lower = name.lowercaseString ?: @"";
    return [lower containsString:@"tap"] ||
           [lower containsString:@"activ"] ||
           [lower containsString:@"select"] ||
           [lower containsString:@"index"] ||
           [lower containsString:@"layout"] ||
           [lower containsString:@"tint"] ||
           [lower containsString:@"highlight"] ||
           [lower containsString:@"update"] ||
           [lower containsString:@"state"];
}

static void TCPDumpClass(Class cls) {
    if (!cls) return;

    NSString *className = NSStringFromClass(cls);
    TCPLog(@"RUNTIME_CLASS_BEGIN class=%@ ptr=%p", className, cls);

    unsigned int propertyCount = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &propertyCount);
    for (unsigned int i=0; i<propertyCount; i++) {
        const char *name = property_getName(properties[i]);
        const char *attrs = property_getAttributes(properties[i]);
        TCPLog(@"PROPERTY class=%@ name=%s attrs=%s",
               className, name ?: "-", attrs ?: "-");
    }
    free(properties);

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned int i=0; i<methodCount; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        if (!TCPInterestingMethodName(name)) continue;

        TCPLog(@"METHOD class=%@ selector=%@ encoding=%s imp=%p",
               className,
               name,
               method_getTypeEncoding(methods[i]) ?: "-",
               method_getImplementation(methods[i]));
    }
    free(methods);

    TCPLog(@"RUNTIME_CLASS_END class=%@", className);
}

static void TCPRuntimeProbe(void) {
    TCPLog(@"========== RUNTIME_PROBE ==========");
    TCPDumpClass(TCPClass(@"XNavigation.TabBarView",
                          @"_TtC11XNavigation10TabBarView"));
    TCPDumpClass(TCPClass(@"XNavigation.TabBarItemView",
                          @"_TtC11XNavigation14TabBarItemView"));
}

#pragma mark - Event / layout hooks

static void TCPSchedulePostTapSnapshots(NSUInteger serial) {
    NSArray<NSNumber *> *delays = @[@0.01,@0.05,@0.15,@0.50,@1.00];

    for (NSNumber *number in delays) {
        NSTimeInterval delay = number.doubleValue;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (serial != gCaptureSerial) return;
                TCPSnapshotAll(
                    [NSString stringWithFormat:@"tap+%.0fms",delay*1000.0]);
            });
    }

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.20*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (serial != gCaptureSerial) return;
            gCaptureWindow = NO;
            TCPLog(@"========== CAPTURE_END serial=%lu ==========",
                   (unsigned long)serial);
        });
}

static void TCPUIApplicationSendEvent(id self, SEL cmd, UIEvent *event) {
    UIView *hitItem = nil;
    UIView *hitBar = nil;
    UITouch *hitTouch = nil;

    if (gCaptureArmed && event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches ?: [NSSet set]) {
            if (touch.phase != UITouchPhaseEnded) continue;

            UIView *view = touch.view;
            UIView *item = TCPAncestorMatching(view, @"XNavigation.TabBarItemView");
            UIView *bar = TCPAncestorMatching(view, @"XNavigation.TabBarView");

            if (item && bar) {
                hitTouch = touch;
                hitItem = item;
                hitBar = bar;
                break;
            }
        }
    }

    if (hitItem && hitBar) {
        gCaptureArmed = NO;
        gCaptureWindow = YES;
        NSUInteger serial = ++gCaptureSerial;

        CGPoint point = [hitTouch locationInView:hitBar];
        TCPLog(@"========== TAB_TOUCH_BEGIN serial=%lu ==========",
               (unsigned long)serial);
        TCPLog(@"TOUCH_PRE serial=%lu touchedClass=%@ touchedPtr=%p itemClass=%@ itemPtr=%p itemIndex=%ld selectedIndex=%ld point=(%.1f,%.1f)",
               (unsigned long)serial,
               NSStringFromClass(hitTouch.view.class),
               hitTouch.view,
               NSStringFromClass(hitItem.class),
               hitItem,
               (long)TCPIndexOfItem(hitBar, hitItem),
               (long)TCPSelectedIndex(hitBar),
               point.x, point.y);
        TCPSnapshotBar(hitBar, @"touch-pre");

        if (gOrigUIApplicationSendEvent) {
            ((void(*)(id,SEL,UIEvent *))gOrigUIApplicationSendEvent)(
                self, cmd, event);
        }

        TCPLog(@"TOUCH_POST_SYNC serial=%lu itemIndex=%ld selectedIndex=%ld",
               (unsigned long)serial,
               (long)TCPIndexOfItem(hitBar, hitItem),
               (long)TCPSelectedIndex(hitBar));
        TCPSnapshotBar(hitBar, @"touch-post-sync");
        TCPSchedulePostTapSnapshots(serial);
        return;
    }

    if (gOrigUIApplicationSendEvent) {
        ((void(*)(id,SEL,UIEvent *))gOrigUIApplicationSendEvent)(self, cmd, event);
    }
}

static void TCPBarLayoutSubviews(id self, SEL cmd) {
    if (gCaptureWindow) {
        TCPLog(@"BAR_LAYOUT_BEFORE ptr=%p selectedIndex=%ld tint=%@",
               self,
               [self isKindOfClass:UIView.class] ? (long)TCPSelectedIndex(self) : -1L,
               [self isKindOfClass:UIView.class]
                    ? TCPColor(((UIView *)self).tintColor) : @"-");
    }

    if (gOrigBarLayoutSubviews) {
        ((void(*)(id,SEL))gOrigBarLayoutSubviews)(self, cmd);
    }

    if (gCaptureWindow && [self isKindOfClass:UIView.class]) {
        TCPLog(@"BAR_LAYOUT_AFTER ptr=%p selectedIndex=%ld tint=%@",
               self,
               (long)TCPSelectedIndex(self),
               TCPColor(((UIView *)self).tintColor));
    }
}

static void TCPItemLayoutSubviews(id self, SEL cmd) {
    UIView *item = [self isKindOfClass:UIView.class] ? self : nil;
    UIView *bar = item ? TCPAncestorMatching(item, @"XNavigation.TabBarView") : nil;

    if (gCaptureWindow) {
        TCPLog(@"ITEM_LAYOUT_BEFORE ptr=%p index=%ld label=%@ tint=%@",
               self,
               (long)TCPIndexOfItem(bar,item),
               TCPText(item.accessibilityLabel),
               TCPColor(item.tintColor));
    }

    if (gOrigItemLayoutSubviews) {
        ((void(*)(id,SEL))gOrigItemLayoutSubviews)(self, cmd);
    }

    if (gCaptureWindow && item) {
        TCPLog(@"ITEM_LAYOUT_AFTER ptr=%p index=%ld label=%@ tint=%@",
               self,
               (long)TCPIndexOfItem(bar,item),
               TCPText(item.accessibilityLabel),
               TCPColor(item.tintColor));
    }
}

static void TCPBarSetTintColor(id self, SEL cmd, UIColor *color) {
    if (gCaptureWindow && [self isKindOfClass:UIView.class]) {
        TCPLog(@"BAR_SET_TINT ptr=%p before=%@ incoming=%@",
               self,
               TCPColor(((UIView *)self).tintColor),
               TCPColor(color));
    }

    if (gOrigBarSetTintColor) {
        ((void(*)(id,SEL,UIColor *))gOrigBarSetTintColor)(self, cmd, color);
    }
}

static void TCPItemSetTintColor(id self, SEL cmd, UIColor *color) {
    UIView *item = [self isKindOfClass:UIView.class] ? self : nil;
    UIView *bar = item ? TCPAncestorMatching(item, @"XNavigation.TabBarView") : nil;

    if (gCaptureWindow) {
        TCPLog(@"ITEM_SET_TINT ptr=%p index=%ld label=%@ before=%@ incoming=%@",
               self,
               (long)TCPIndexOfItem(bar,item),
               TCPText(item.accessibilityLabel),
               TCPColor(item.tintColor),
               TCPColor(color));
    }

    if (gOrigItemSetTintColor) {
        ((void(*)(id,SEL,UIColor *))gOrigItemSetTintColor)(self, cmd, color);
    }
}

static void TCPBarSetSelectedIndex(id self, SEL cmd, NSInteger value) {
    NSInteger before =
        [self isKindOfClass:UIView.class] ? TCPSelectedIndex(self) : NSNotFound;

    if (gCaptureWindow || gCaptureArmed) {
        TCPLog(@"SET_SELECTED_INDEX_BEFORE ptr=%p before=%ld incoming=%ld",
               self, (long)before, (long)value);
    }

    if (gOrigBarSetSelectedIndex) {
        ((void(*)(id,SEL,NSInteger))gOrigBarSetSelectedIndex)(self, cmd, value);
    }

    if (gCaptureWindow || gCaptureArmed) {
        TCPLog(@"SET_SELECTED_INDEX_AFTER ptr=%p now=%ld",
               self,
               [self isKindOfClass:UIView.class]
                    ? (long)TCPSelectedIndex(self) : -1L);
    }
}

static void TCPInstallRuntimeHooks(void) {
    TCPHookInstanceMethod(
        UIApplication.class,
        @selector(sendEvent:),
        (IMP)TCPUIApplicationSendEvent,
        &gOrigUIApplicationSendEvent);

    Class barClass = TCPClass(@"XNavigation.TabBarView",
                              @"_TtC11XNavigation10TabBarView");
    Class itemClass = TCPClass(@"XNavigation.TabBarItemView",
                               @"_TtC11XNavigation14TabBarItemView");

    if (barClass) {
        TCPHookInstanceMethod(barClass,
                              @selector(layoutSubviews),
                              (IMP)TCPBarLayoutSubviews,
                              &gOrigBarLayoutSubviews);
        TCPHookInstanceMethod(barClass,
                              @selector(setTintColor:),
                              (IMP)TCPBarSetTintColor,
                              &gOrigBarSetTintColor);

        SEL setSelectedIndexSEL = NSSelectorFromString(@"setSelectedIndex:");
        Method m = class_getInstanceMethod(barClass, setSelectedIndexSEL);
        if (m) {
            NSMethodSignature *sig =
                [NSMethodSignature signatureWithObjCTypes:
                    method_getTypeEncoding(m)];
            const char *arg =
                sig.numberOfArguments == 3
                    ? [sig getArgumentTypeAtIndex:2]
                    : NULL;

            if (arg && strchr("qQiIlLsScCB", arg[0]) != NULL) {
                TCPHookInstanceMethod(barClass,
                                      setSelectedIndexSEL,
                                      (IMP)TCPBarSetSelectedIndex,
                                      &gOrigBarSetSelectedIndex);
                TCPLog(@"HOOK setSelectedIndex installed encoding=%s",
                       method_getTypeEncoding(m));
            } else {
                TCPLog(@"HOOK setSelectedIndex skipped encoding=%s",
                       method_getTypeEncoding(m) ?: "-");
            }
        } else {
            TCPLog(@"HOOK setSelectedIndex unavailable");
        }
    }

    if (itemClass) {
        TCPHookInstanceMethod(itemClass,
                              @selector(layoutSubviews),
                              (IMP)TCPItemLayoutSubviews,
                              &gOrigItemLayoutSubviews);
        TCPHookInstanceMethod(itemClass,
                              @selector(setTintColor:),
                              (IMP)TCPItemSetTintColor,
                              &gOrigItemSetTintColor);
    }

    TCPLog(@"HOOK_STATUS sendEvent=%d barClass=%@ itemClass=%@ barLayout=%d itemLayout=%d barTint=%d itemTint=%d selectedIndex=%d",
           gOrigUIApplicationSendEvent != NULL,
           barClass ? NSStringFromClass(barClass) : @"nil",
           itemClass ? NSStringFromClass(itemClass) : @"nil",
           gOrigBarLayoutSubviews != NULL,
           gOrigItemLayoutSubviews != NULL,
           gOrigBarSetTintColor != NULL,
           gOrigItemSetTintColor != NULL,
           gOrigBarSetSelectedIndex != NULL);
}

#pragma mark - NFB UI

@interface XLiquidGlassTabClickProbeViewController : UITableViewController
@end

@implementation XLiquidGlassTabClickProbeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Tab Click Probe";
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 5;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return @"Arme a captura, volte ao X e toque uma única vez em uma aba da Tab Bar. Depois retorne e copie o relatório.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"TCProbeCell";
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
          reuseIdentifier:identifier];
    }

    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (indexPath.row == 0) {
        cell.textLabel.text = @"Estado";
        cell.detailTextLabel.text =
            gCaptureArmed ? @"Aguardando próximo toque na Tab Bar"
                          : (gCaptureWindow ? @"Capturando pós-toque"
                                            : @"Pronto");
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"Capturar próximo toque";
        cell.detailTextLabel.text = @"Limpa o log e captura um único toque.";
    } else if (indexPath.row == 2) {
        cell.textLabel.text = @"Snapshot agora";
        cell.detailTextLabel.text = @"Registra o estado atual da Tab Bar.";
    } else if (indexPath.row == 3) {
        cell.textLabel.text = @"Copiar relatório";
        cell.detailTextLabel.text = kTCPLogFileName;
    } else {
        cell.textLabel.text = @"Limpar relatório";
        cell.detailTextLabel.text = @"Apaga a captura atual.";
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.row == 0) {
        [tableView reloadData];
        return;
    }

    if (indexPath.row == 1) {
        [[NSFileManager defaultManager] removeItemAtPath:TCPLogPath() error:nil];

        gCaptureWindow = NO;
        gCaptureArmed = YES;
        gCaptureSerial++;

        TCPLog(@"========== LOG RESET FROM NFB ==========");
        TCPLog(@"========== Tab Click Probe armed ==========");
        TCPRuntimeProbe();
        TCPSnapshotAll(@"armed");

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"Tab Click Probe"
                                 message:@"Captura armada. Volte ao X e toque uma única vez na aba que faz a cor atualizar."
                          preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        [tableView reloadData];
        return;
    }

    if (indexPath.row == 2) {
        TCPSnapshotAll(@"manual-NFB");
        [tableView reloadData];
        return;
    }

    if (indexPath.row == 3) {
        NSString *report =
            [NSString stringWithContentsOfFile:TCPLogPath()
                                      encoding:NSUTF8StringEncoding
                                         error:nil] ?: @"";

        UIPasteboard.generalPasteboard.string = report;

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"Tab Click Probe"
                                 message:
                    [NSString stringWithFormat:
                        @"Relatório copiado (%lu caracteres).",
                        (unsigned long)report.length]
                          preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    gCaptureArmed = NO;
    gCaptureWindow = NO;
    gCaptureSerial++;

    [[NSFileManager defaultManager] removeItemAtPath:TCPLogPath() error:nil];
    TCPLog(@"LOG RESET");
    [tableView reloadData];
}

@end

static BOOL TCPSectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"action"] isEqualToString:@"showXLiquidGlassTabClickProbe"]) {
            return YES;
        }
    }
    return NO;
}

static void TCPInjectNFBSection(id controller) {
    NSArray *sections = nil;

    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        return;
    }

    if (![sections isKindOfClass:NSArray.class] ||
        TCPSectionsContainEntry(sections)) {
        return;
    }

    NSMutableArray *updated = [sections mutableCopy];
    [updated addObject:@{
        @"title": @"Tab Click Probe",
        @"subtitle": @"Captura o toque que atualiza a Tab Bar.",
        @"icon": @"cursorarrow.click",
        @"action": @"showXLiquidGlassTabClickProbe"
    }];

    @try {
        [controller setValue:[updated copy] forKey:@"sections"];
    } @catch (__unused NSException *exception) {
    }
}

static void TCPNFBSetupSections(id self, SEL cmd) {
    if (gOrigNFBSetupSections) {
        ((void(*)(id,SEL))gOrigNFBSetupSections)(self, cmd);
    }

    TCPInjectNFBSection(self);
}

static void TCPNFBViewWillAppear(id self, SEL cmd, BOOL animated) {
    if (gOrigNFBViewWillAppear) {
        ((void(*)(id,SEL,BOOL))gOrigNFBViewWillAppear)(self, cmd, animated);
    }

    TCPInjectNFBSection(self);

    UITableView *tableView = nil;
    @try {
        tableView = [self valueForKey:@"tableView"];
    } @catch (__unused NSException *exception) {
    }
    [tableView reloadData];
}

static void TCPShowSettings(id self, SEL cmd) {
    (void)cmd;
    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassTabClickProbeViewController *vc =
        [XLiquidGlassTabClickProbeViewController new];

    UINavigationController *nav =
        ((UIViewController *)self).navigationController;

    if (nav) {
        [nav pushViewController:vc animated:YES];
    } else {
        UINavigationController *wrapper =
            [[UINavigationController alloc] initWithRootViewController:vc];
        [(UIViewController *)self
            presentViewController:wrapper
                         animated:YES
                       completion:nil];
    }
}

static void TCPInstallNFBIntegration(void) {
    Class cls = NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;

    class_addMethod(
        cls,
        NSSelectorFromString(@"showXLiquidGlassTabClickProbe"),
        (IMP)TCPShowSettings,
        "v@:");

    if (!gOrigNFBSetupSections) {
        TCPHookInstanceMethod(cls,
                              NSSelectorFromString(@"setupSections"),
                              (IMP)TCPNFBSetupSections,
                              &gOrigNFBSetupSections);
    }

    if (!gOrigNFBViewWillAppear) {
        TCPHookInstanceMethod(cls,
                              @selector(viewWillAppear:),
                              (IMP)TCPNFBViewWillAppear,
                              &gOrigNFBViewWillAppear);
    }
}

#pragma mark - Install

static void TCPInstallAll(void) {
    TCPInstallRuntimeHooks();
    TCPInstallNFBIntegration();
}

static void TCPRetry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            TCPInstallAll();
        });
}

__attribute__((constructor))
static void XLiquidGlassTabClickProbeInit(void) {
    @autoreleasepool {
        TCPLog(@"========== XLiquidGlass Tab Click Probe 0.1.0 loaded ==========");
        TCPLog(@"logPath=%@", TCPLogPath());

        TCPInstallAll();

        TCPRetry(0.05);
        TCPRetry(0.20);
        TCPRetry(0.50);
        TCPRetry(1.00);
        TCPRetry(2.00);
        TCPRetry(4.00);

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.5*NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                TCPRuntimeProbe();
            });
    }
}
