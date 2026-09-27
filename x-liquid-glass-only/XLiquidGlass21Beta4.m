#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>

#pragma mark - XLiquidGlass 2.1 Beta 4 Search owned native collapse

static NSString *const kXLG21B4LogName = @"XLiquidGlass21Beta4.log";

static BOOL gXLG21B4Installed = NO;
static IMP gXLG21B4OrigSearchViewDidAppear = NULL;
static IMP gXLG21B4OrigNFBSetupSections = NULL;
static IMP gXLG21B4OrigNFBViewWillAppear = NULL;

static NSString *XLG21B4LogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kXLG21B4LogName];
}

static void XLG21B4Log(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *stamp = [formatter stringFromDate:[NSDate date]] ?: @"-";

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", stamp, message ?: @""];
    NSLog(@"[XLiquidGlass 2.1 Beta 4] %@", message ?: @"");

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = XLG21B4LogPath();

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;

    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (__unused NSException *exception) {
    }

    @try {
        [handle closeFile];
    } @catch (__unused NSException *exception) {
    }
}

static NSString *XLG21B4SymbolForIMP(IMP imp) {
    if (!imp) return @"-";

    Dl_info info = {0};
    if (dladdr((const void *)imp, &info) == 0) return @"-";

    NSString *image = info.dli_fname
        ? [NSString stringWithUTF8String:info.dli_fname]
        : @"-";
    NSString *symbol = info.dli_sname
        ? [NSString stringWithUTF8String:info.dli_sname]
        : @"-";

    return [NSString stringWithFormat:@"%@ | %@", image, symbol];
}

static BOOL XLG21B4ClassDeclaresSelector(Class cls, SEL sel) {
    if (!cls || !sel) return NO;

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

static BOOL XLG21B4ClassDeclaresProperty(Class cls, const char *name) {
    if (!cls || !name) return NO;

    unsigned int count = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &count);
    BOOL found = NO;

    for (unsigned int i = 0; i < count; i++) {
        const char *propertyName = property_getName(properties[i]);
        if (propertyName && strcmp(propertyName, name) == 0) {
            found = YES;
            break;
        }
    }

    free(properties);
    return found;
}

static BOOL XLG21B4AddReadonlyBoolProperty(Class cls, const char *name) {
    if (!cls || !name) return NO;

    if (XLG21B4ClassDeclaresProperty(cls, name)) return YES;

    objc_property_attribute_t attrs[] = {
        {"T", "B"},
        {"N", ""},
        {"R", ""}
    };

    BOOL added = class_addProperty(cls, name, attrs, 3);
    BOOL directNow = XLG21B4ClassDeclaresProperty(cls, name);

    XLG21B4Log(@"PROPERTY_DECLARE class=%@ name=%s added=%d directNow=%d",
               NSStringFromClass(cls), name, added, directNow);

    return directNow;
}

static NSString *XLG21B4ImageForClass(Class cls) {
    if (!cls) return @"-";
    const char *image = class_getImageName(cls);
    return image ? [NSString stringWithUTF8String:image] : @"-";
}

static BOOL XLG21B4ClassBelongsToApp(Class cls) {
    NSString *image = XLG21B4ImageForClass(cls);
    if (!image.length) return NO;

    return [image containsString:@"/Twitter.app/"] ||
           [image containsString:@"/Frameworks/"];
}

static BOOL XLG21B4CopyHomeCapabilityToClass(
    Class home,
    Class target,
    NSString *selectorName) {

    if (!home || !target || !selectorName.length) return NO;

    SEL sel = NSSelectorFromString(selectorName);
    Method homeMethod = class_getInstanceMethod(home, sel);
    Method targetMethod = class_getInstanceMethod(target, sel);

    if (!homeMethod || !targetMethod) {
        XLG21B4Log(@"CAPABILITY_SKIP class=%@ selector=%@ reason=method-missing home=%p target=%p",
                   NSStringFromClass(target),
                   selectorName,
                   homeMethod,
                   targetMethod);
        return NO;
    }

    const char *homeTypes = method_getTypeEncoding(homeMethod);
    const char *targetTypes = method_getTypeEncoding(targetMethod);

    if (!homeTypes || !targetTypes || strcmp(homeTypes, targetTypes) != 0) {
        XLG21B4Log(@"CAPABILITY_SKIP class=%@ selector=%@ reason=encoding-mismatch homeTypes=%s targetTypes=%s",
                   NSStringFromClass(target),
                   selectorName,
                   homeTypes ?: "-",
                   targetTypes ?: "-");
        return NO;
    }

    IMP homeIMP = method_getImplementation(homeMethod);
    IMP beforeIMP = class_getMethodImplementation(target, sel);
    BOOL directBefore = XLG21B4ClassDeclaresSelector(target, sel);

    if (directBefore) {
        XLG21B4Log(@"CAPABILITY_KEEP class=%@ selector=%@ reason=already-direct imp=%p symbol=%@",
                   NSStringFromClass(target),
                   selectorName,
                   beforeIMP,
                   XLG21B4SymbolForIMP(beforeIMP));
        return YES;
    }

    BOOL added = class_addMethod(target, sel, homeIMP, homeTypes);
    IMP afterIMP = class_getMethodImplementation(target, sel);
    BOOL directAfter = XLG21B4ClassDeclaresSelector(target, sel);
    BOOL success = added && directAfter && afterIMP == homeIMP;

    XLG21B4Log(@"CAPABILITY_APPLY class=%@ selector=%@ success=%d inheritedIMP=%p homeIMP=%p finalIMP=%p homeSymbol=%@",
               NSStringFromClass(target),
               selectorName,
               success,
               beforeIMP,
               homeIMP,
               afterIMP,
               XLG21B4SymbolForIMP(homeIMP));

    return success;
}

static NSArray<UIViewController *> *XLG21B4OwnedControllers(id controller) {
    NSMutableArray<UIViewController *> *result = [NSMutableArray array];
    if (!controller) return result;

    SEL ownedSel = NSSelectorFromString(@"tfn_ownedViewControllers");
    if ([controller respondsToSelector:ownedSel]) {
        id owned = ((id(*)(id,SEL))objc_msgSend)(controller, ownedSel);

        if ([owned isKindOfClass:NSArray.class]) {
            for (id obj in (NSArray *)owned) {
                if ([obj isKindOfClass:UIViewController.class]) {
                    [result addObject:obj];
                }
            }
        } else if ([owned isKindOfClass:NSSet.class]) {
            for (id obj in (NSSet *)owned) {
                if ([obj isKindOfClass:UIViewController.class]) {
                    [result addObject:obj];
                }
            }
        }
    }

    if ([controller isKindOfClass:UIViewController.class]) {
        UIViewController *vc = (UIViewController *)controller;
        for (UIViewController *child in vc.childViewControllers) {
            if (child) [result addObject:child];
        }

        if (vc.presentedViewController) {
            [result addObject:vc.presentedViewController];
        }
    }

    return result;
}

static NSArray<UIViewController *> *XLG21B4SearchControllerTree(
    UIViewController *root) {

    if (!root) return @[];

    NSMutableArray<UIViewController *> *queue = [NSMutableArray arrayWithObject:root];
    NSMutableArray<UIViewController *> *result = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];

    for (NSUInteger i = 0; i < queue.count && i < 160; i++) {
        UIViewController *vc = queue[i];
        NSValue *token = [NSValue valueWithNonretainedObject:vc];
        if ([visited containsObject:token]) continue;
        [visited addObject:token];

        [result addObject:vc];

        for (UIViewController *owned in XLG21B4OwnedControllers(vc)) {
            if (owned) [queue addObject:owned];
        }
    }

    return result;
}

static void XLG21B4RequestNativeConfigurationRefresh(id controller) {
    if (!controller) return;

    SEL xnav = NSSelectorFromString(@"xnav_setNeedsNavigationConfigurationUpdateAnimated:");
    if ([controller respondsToSelector:xnav]) {
        ((void(*)(id,SEL,BOOL))objc_msgSend)(controller, xnav, NO);
        XLG21B4Log(@"REFRESH object=%p class=%@ selector=%@",
                   controller,
                   NSStringFromClass([controller class]),
                   NSStringFromSelector(xnav));
    }

    SEL tabStyle = NSSelectorFromString(@"tfn_setNeedsTabBarStyleOverridesUpdate");
    if ([controller respondsToSelector:tabStyle]) {
        ((void(*)(id,SEL))objc_msgSend)(controller, tabStyle);
        XLG21B4Log(@"REFRESH object=%p class=%@ selector=%@",
                   controller,
                   NSStringFromClass([controller class]),
                   NSStringFromSelector(tabStyle));
    }

    SEL navExpansion = NSSelectorFromString(@"tfn_setNeedsNavigationBarExpansionUpdate");
    if ([controller respondsToSelector:navExpansion]) {
        ((void(*)(id,SEL))objc_msgSend)(controller, navExpansion);
        XLG21B4Log(@"REFRESH object=%p class=%@ selector=%@",
                   controller,
                   NSStringFromClass([controller class]),
                   NSStringFromSelector(navExpansion));
    }
}

static void XLG21B4ApplyToSearchTree(UIViewController *searchRoot, NSString *reason) {
    if (!searchRoot) return;

    Class home = NSClassFromString(
        @"TwitterHomeFeatureImplementation.HomeTimelineContainerViewController");
    if (!home) {
        XLG21B4Log(@"TREE_APPLY reason=%@ home=nil", reason ?: @"-");
        return;
    }

    NSArray<NSString *> *selectors = @[
        @"tfn_supportsTabBarCollapsing",
        @"tfn_prefersTabBarPinned",
        @"tfn_preferManualNavBarCollapse"
    ];

    NSArray<UIViewController *> *controllers =
        XLG21B4SearchControllerTree(searchRoot);

    XLG21B4Log(@"========== TREE_APPLY_BEGIN reason=%@ root=%p class=%@ count=%lu ==========",
               reason ?: @"-",
               searchRoot,
               NSStringFromClass(searchRoot.class),
               (unsigned long)controllers.count);

    for (UIViewController *vc in controllers) {
        Class cls = vc.class;
        NSString *image = XLG21B4ImageForClass(cls);

        XLG21B4Log(@"TREE_NODE object=%p class=%@ image=%@ parent=%@ nav=%@",
                   vc,
                   NSStringFromClass(cls),
                   image,
                   vc.parentViewController
                       ? NSStringFromClass(vc.parentViewController.class)
                       : @"-",
                   vc.navigationController
                       ? NSStringFromClass(vc.navigationController.class)
                       : @"-");

        if (!XLG21B4ClassBelongsToApp(cls)) {
            XLG21B4Log(@"TREE_NODE_SKIP class=%@ reason=non-app-image",
                       NSStringFromClass(cls));
            continue;
        }

        BOOL responds =
            [vc respondsToSelector:NSSelectorFromString(@"tfn_supportsTabBarCollapsing")];

        if (!responds) {
            XLG21B4Log(@"TREE_NODE_SKIP class=%@ reason=no-collapse-capability",
                       NSStringFromClass(cls));
            continue;
        }

        BOOL methodsOK = YES;
        for (NSString *selectorName in selectors) {
            methodsOK &=
                XLG21B4CopyHomeCapabilityToClass(home, cls, selectorName);
        }

        BOOL propertiesOK = YES;
        propertiesOK &= XLG21B4AddReadonlyBoolProperty(
            cls, "tfn_supportsTabBarCollapsing");
        propertiesOK &= XLG21B4AddReadonlyBoolProperty(
            cls, "tfn_prefersTabBarPinned");
        propertiesOK &= XLG21B4AddReadonlyBoolProperty(
            cls, "tfn_preferManualNavBarCollapse");

        XLG21B4Log(@"TREE_NODE_RESULT class=%@ methods=%d properties=%d",
                   NSStringFromClass(cls),
                   methodsOK,
                   propertiesOK);

        XLG21B4RequestNativeConfigurationRefresh(vc);
    }

    XLG21B4Log(@"========== TREE_APPLY_END reason=%@ ==========",
               reason ?: @"-");
}

static Ivar XLG21B4FindIvarInHierarchy(Class cls, const char *name) {
    for (Class cursor = cls; cursor; cursor = class_getSuperclass(cursor)) {
        Ivar ivar = class_getInstanceVariable(cursor, name);
        if (ivar) return ivar;
    }
    return NULL;
}

static uint64_t XLG21B4ReadRaw64(id object, const char *name) {
    if (!object || !name) return 0;

    Ivar ivar = XLG21B4FindIvarInHierarchy(object_getClass(object), name);
    if (!ivar) return 0;

    ptrdiff_t offset = ivar_getOffset(ivar);
    uint64_t value = 0;
    const uint8_t *base =
        (const uint8_t *)(__bridge const void *)object;

    memcpy(&value, base + offset, sizeof(value));
    return value;
}

static double XLG21B4DoubleFromRaw(uint64_t raw) {
    double value = 0.0;
    memcpy(&value, &raw, sizeof(value));
    return value;
}

static id XLG21B4CollapseEngineForController(UIViewController *controller) {
    if (!controller) return nil;
    if (![NSStringFromClass(controller.class)
          isEqualToString:@"XNavigation.NavigationController"]) {
        return nil;
    }

    Ivar ivar = XLG21B4FindIvarInHierarchy(
        controller.class,
        "$__lazy_storage_$_collapseEngine");

    if (!ivar) return nil;

    @try {
        return object_getIvar(controller, ivar);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *XLG21B4LabelForRawController(
    UIWindow *window,
    uint64_t raw) {

    if (!window || raw == 0 || !window.rootViewController) return @"-";

    NSMutableArray<UIViewController *> *queue =
        [NSMutableArray arrayWithObject:window.rootViewController];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];

    for (NSUInteger i = 0; i < queue.count && i < 300; i++) {
        UIViewController *vc = queue[i];
        NSValue *token = [NSValue valueWithNonretainedObject:vc];
        if ([visited containsObject:token]) continue;
        [visited addObject:token];

        if ((uint64_t)(uintptr_t)(__bridge void *)vc == raw) {
            return [NSString stringWithFormat:@"%@[%@]@%p",
                    NSStringFromClass(vc.class),
                    vc.title ?: @"-",
                    vc];
        }

        if (vc.presentedViewController) {
            [queue addObject:vc.presentedViewController];
        }
        [queue addObjectsFromArray:vc.childViewControllers ?: @[]];
    }

    return @"-";
}

static UIWindow *XLG21B4BestWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;

        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (!window.hidden && window.alpha > 0.01 &&
                window.windowLevel == UIWindowLevelNormal) {
                return window;
            }
        }
    }
    return nil;
}

static void XLG21B4SnapshotCollapseState(NSString *reason) {
    UIWindow *window = XLG21B4BestWindow();
    if (!window || !window.rootViewController) {
        XLG21B4Log(@"SNAPSHOT reason=%@ window=nil", reason ?: @"-");
        return;
    }

    NSMutableArray<UIViewController *> *queue =
        [NSMutableArray arrayWithObject:window.rootViewController];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];

    XLG21B4Log(@"========== SNAPSHOT_BEGIN reason=%@ ==========",
               reason ?: @"-");

    for (NSUInteger i = 0; i < queue.count && i < 300; i++) {
        UIViewController *vc = queue[i];
        NSValue *token = [NSValue valueWithNonretainedObject:vc];
        if ([visited containsObject:token]) continue;
        [visited addObject:token];

        BOOL visible =
            vc == window.rootViewController ||
            (vc.isViewLoaded && vc.view.window == window);

        if (visible) {
            XLG21B4Log(@"VISIBLE_CONTROLLER object=%p class=%@ title=%@",
                       vc,
                       NSStringFromClass(vc.class),
                       vc.title ?: @"-");

            id engine = XLG21B4CollapseEngineForController(vc);
            if (engine) {
                uint64_t governed = XLG21B4ReadRaw64(engine, "governedScreen");
                uint64_t lastUndeclared =
                    XLG21B4ReadRaw64(engine, "lastLoggedUndeclaredScreen");
                uint64_t pendingUndeclared =
                    XLG21B4ReadRaw64(engine, "pendingUndeclaredVerdict");
                uint64_t progress = XLG21B4ReadRaw64(engine, "collapseProgress");
                uint64_t hidden = XLG21B4ReadRaw64(engine, "hiddenBarTravel");

                XLG21B4Log(
                    @"COLLAPSE_STATE engine=%p governed=0x%016llx governedLabel=%@ lastUndeclared=0x%016llx lastUndeclaredLabel=%@ pendingUndeclared=0x%016llx pendingUndeclaredLabel=%@ hiddenBarTravel=%.6f collapseProgress=%.6f",
                    engine,
                    (unsigned long long)governed,
                    XLG21B4LabelForRawController(window, governed),
                    (unsigned long long)lastUndeclared,
                    XLG21B4LabelForRawController(window, lastUndeclared),
                    (unsigned long long)pendingUndeclared,
                    XLG21B4LabelForRawController(window, pendingUndeclared),
                    XLG21B4DoubleFromRaw(hidden),
                    XLG21B4DoubleFromRaw(progress));
            }
        }

        if (vc.presentedViewController) {
            [queue addObject:vc.presentedViewController];
        }
        [queue addObjectsFromArray:vc.childViewControllers ?: @[]];
    }

    XLG21B4Log(@"========== SNAPSHOT_END reason=%@ ==========",
               reason ?: @"-");
}

static UIViewController *XLG21B4VisibleSearchController(void) {
    UIWindow *window = XLG21B4BestWindow();
    if (!window || !window.rootViewController) return nil;

    Class searchClass = NSClassFromString(@"TTSSearchContainerViewControllerV2");
    if (!searchClass) return nil;

    NSMutableArray<UIViewController *> *queue =
        [NSMutableArray arrayWithObject:window.rootViewController];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];

    for (NSUInteger i = 0; i < queue.count && i < 300; i++) {
        UIViewController *vc = queue[i];
        NSValue *token = [NSValue valueWithNonretainedObject:vc];
        if ([visited containsObject:token]) continue;
        [visited addObject:token];

        if ([vc isKindOfClass:searchClass] &&
            vc.isViewLoaded &&
            vc.view.window == window) {
            return vc;
        }

        if (vc.presentedViewController) {
            [queue addObject:vc.presentedViewController];
        }
        [queue addObjectsFromArray:vc.childViewControllers ?: @[]];
    }

    return nil;
}

static void XLG21B4SearchViewDidAppear(id self, SEL cmd, BOOL animated) {
    if (gXLG21B4OrigSearchViewDidAppear) {
        ((void(*)(id,SEL,BOOL))gXLG21B4OrigSearchViewDidAppear)(
            self, cmd, animated);
    }

    XLG21B4Log(@"SEARCH_APPEARED object=%p class=%@",
               self,
               NSStringFromClass([self class]));

    XLG21B4ApplyToSearchTree(
        (UIViewController *)self,
        @"search-viewDidAppear");

    XLG21B4SnapshotCollapseState(@"search-viewDidAppear-immediate");

    NSArray<NSNumber *> *delays = @[@0.10, @0.35, @0.80];
    for (NSNumber *delay in delays) {
        NSTimeInterval seconds = delay.doubleValue;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(seconds * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                XLG21B4ApplyToSearchTree(
                    (UIViewController *)self,
                    [NSString stringWithFormat:
                        @"search-viewDidAppear-%.2fs", seconds]);
                XLG21B4SnapshotCollapseState(
                    [NSString stringWithFormat:
                        @"search-viewDidAppear-%.2fs", seconds]);
            });
    }
}

static BOOL XLG21B4InstallSearchHook(Class search) {
    SEL sel = @selector(viewDidAppear:);
    Method method = class_getInstanceMethod(search, sel);
    if (!method) return NO;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    IMP current = class_getMethodImplementation(search, sel);
    if (current == (IMP)XLG21B4SearchViewDidAppear) return YES;

    gXLG21B4OrigSearchViewDidAppear = current;

    BOOL direct = XLG21B4ClassDeclaresSelector(search, sel);
    BOOL success = NO;

    if (direct) {
        class_replaceMethod(
            search,
            sel,
            (IMP)XLG21B4SearchViewDidAppear,
            types);
        success =
            class_getMethodImplementation(search, sel) ==
            (IMP)XLG21B4SearchViewDidAppear;
    } else {
        success = class_addMethod(
            search,
            sel,
            (IMP)XLG21B4SearchViewDidAppear,
            types);
    }

    XLG21B4Log(@"VIEW_HOOK class=%@ success=%d original=%p",
               NSStringFromClass(search),
               success,
               current);

    return success;
}

#pragma mark - Probe UI inside settings

@interface XLiquidGlassBeta4ProbeViewController : UITableViewController
@end

@implementation XLiquidGlassBeta4ProbeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"2.1 Beta 4 Probe";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 3 : 3;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? @"Correção" : @"Relatório";
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    (void)tableView;

    if (section == 0) {
        return @"A Beta 4 aplica as capabilities nativas da Home somente à árvore de controllers da Busca. Não move a Tab Bar manualmente.";
    }

    return @"Use Copiar relatório e cole o conteúdo no chat. Não é necessário buscar o arquivo em Documents.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    static NSString *identifier = @"XLG21B4Cell";
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
          reuseIdentifier:identifier];
    }

    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Estado";
            cell.detailTextLabel.text =
                gXLG21B4Installed
                    ? @"Beta 4 instalada"
                    : @"Aguardando classes do X";
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Aplicar novamente na Busca";
            cell.detailTextLabel.text =
                @"Reaplica a declaração somente se a Busca estiver visível.";
        } else {
            cell.textLabel.text = @"Snapshot agora";
            cell.detailTextLabel.text =
                @"Registra governedScreen e estado do collapseEngine.";
        }
    } else {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Nova sessão";
            cell.detailTextLabel.text =
                @"Limpa o relatório e reinicia o diagnóstico.";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Copiar relatório";
            cell.detailTextLabel.text = kXLG21B4LogName;
        } else {
            cell.textLabel.text = @"Limpar relatório";
            cell.detailTextLabel.text =
                @"Apaga o relatório atual.";
        }
    }

    return cell;
}

- (void)showInfo:(NSString *)message {
    UIAlertController *alert =
        [UIAlertController
            alertControllerWithTitle:@"2.1 Beta 4 Probe"
                             message:message
                      preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:
        [UIAlertAction actionWithTitle:@"OK"
                                 style:UIAlertActionStyleDefault
                               handler:nil]];

    [self presentViewController:alert
                       animated:YES
                     completion:nil];
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {

    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0) {
        if (indexPath.row == 0) return;

        if (indexPath.row == 1) {
            UIViewController *search = XLG21B4VisibleSearchController();
            if (!search) {
                [self showInfo:
                    @"A Busca não está visível agora. Abra a Busca, faça o teste e volte para copiar o relatório."];
                return;
            }

            XLG21B4ApplyToSearchTree(search, @"manual-settings");
            XLG21B4SnapshotCollapseState(@"manual-settings");

            [self showInfo:
                @"Correção reaplicada à árvore visível da Busca."];
            return;
        }

        XLG21B4SnapshotCollapseState(@"manual-settings-snapshot");
        [self showInfo:@"Snapshot registrado."];
        return;
    }

    if (indexPath.row == 0) {
        [[NSFileManager defaultManager]
            removeItemAtPath:XLG21B4LogPath()
                       error:nil];

        XLG21B4Log(@"========== NEW SESSION ==========");
        XLG21B4Log(@"VERSION XLiquidGlass 2.1 Beta 4");
        XLG21B4Log(@"MODE corrective-search-owned-tree + settings-copy-probe");

        [self showInfo:
            @"Nova sessão iniciada. Abra a Busca, role para baixo e depois volte aqui para copiar o relatório."];
        return;
    }

    if (indexPath.row == 1) {
        NSString *report =
            [NSString stringWithContentsOfFile:XLG21B4LogPath()
                                      encoding:NSUTF8StringEncoding
                                         error:nil] ?: @"";

        UIPasteboard.generalPasteboard.string = report;

        [self showInfo:
            [NSString stringWithFormat:
                @"Relatório copiado (%lu caracteres).",
                (unsigned long)report.length]];
        return;
    }

    [[NSFileManager defaultManager]
        removeItemAtPath:XLG21B4LogPath()
                   error:nil];

    [self showInfo:@"Relatório limpo."];
}

@end

static BOOL XLG21B4SectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"action"] isEqualToString:@"showXLiquidGlassBeta4Probe"]) {
            return YES;
        }
    }
    return NO;
}

static void XLG21B4InjectNFBSection(id controller) {
    NSArray *sections = nil;

    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        return;
    }

    if (![sections isKindOfClass:NSArray.class] ||
        XLG21B4SectionsContainEntry(sections)) {
        return;
    }

    NSMutableArray *updated = [sections mutableCopy];
    [updated addObject:@{
        @"title": @"2.1 Beta 4 Probe",
        @"subtitle": @"Correção da Busca + relatório copiável.",
        @"icon": @"waveform.path.ecg",
        @"action": @"showXLiquidGlassBeta4Probe"
    }];

    @try {
        [controller setValue:[updated copy] forKey:@"sections"];
    } @catch (__unused NSException *exception) {
    }
}

static void XLG21B4NFBSetupSections(id self, SEL cmd) {
    if (gXLG21B4OrigNFBSetupSections) {
        ((void(*)(id,SEL))gXLG21B4OrigNFBSetupSections)(self, cmd);
    }
    XLG21B4InjectNFBSection(self);
}

static void XLG21B4NFBViewWillAppear(
    id self,
    SEL cmd,
    BOOL animated) {

    if (gXLG21B4OrigNFBViewWillAppear) {
        ((void(*)(id,SEL,BOOL))
            gXLG21B4OrigNFBViewWillAppear)(self, cmd, animated);
    }

    XLG21B4InjectNFBSection(self);

    UITableView *tableView = nil;
    @try {
        tableView = [self valueForKey:@"tableView"];
    } @catch (__unused NSException *exception) {
    }

    [tableView reloadData];
}

static void XLG21B4ShowProbe(id self, SEL cmd) {
    (void)cmd;

    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassBeta4ProbeViewController *vc =
        [XLiquidGlassBeta4ProbeViewController new];

    UINavigationController *nav =
        ((UIViewController *)self).navigationController;

    if (nav) {
        [nav pushViewController:vc animated:YES];
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

static BOOL XLG21B4HookInstanceMethod(
    Class cls,
    SEL sel,
    IMP replacement,
    IMP *original) {

    if (!cls || !sel || !replacement || !original || *original) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    IMP current = class_getMethodImplementation(cls, sel);
    *original = current;

    BOOL direct = XLG21B4ClassDeclaresSelector(cls, sel);

    if (direct) {
        class_replaceMethod(cls, sel, replacement, types);
        return class_getMethodImplementation(cls, sel) == replacement;
    }

    return class_addMethod(cls, sel, replacement, types);
}

static void XLG21B4InstallSettingsIntegration(void) {
    Class cls = NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;

    class_addMethod(
        cls,
        NSSelectorFromString(@"showXLiquidGlassBeta4Probe"),
        (IMP)XLG21B4ShowProbe,
        "v@:");

    if (!gXLG21B4OrigNFBSetupSections) {
        XLG21B4HookInstanceMethod(
            cls,
            NSSelectorFromString(@"setupSections"),
            (IMP)XLG21B4NFBSetupSections,
            &gXLG21B4OrigNFBSetupSections);
    }

    if (!gXLG21B4OrigNFBViewWillAppear) {
        XLG21B4HookInstanceMethod(
            cls,
            @selector(viewWillAppear:),
            (IMP)XLG21B4NFBViewWillAppear,
            &gXLG21B4OrigNFBViewWillAppear);
    }
}

static void XLG21B4Install(void) {
    Class search = NSClassFromString(@"TTSSearchContainerViewControllerV2");
    Class home = NSClassFromString(
        @"TwitterHomeFeatureImplementation.HomeTimelineContainerViewController");

    XLG21B4InstallSettingsIntegration();

    if (gXLG21B4Installed) return;

    if (!search || !home) {
        XLG21B4Log(@"INSTALL_WAIT search=%p home=%p", search, home);
        return;
    }

    BOOL hookOK = XLG21B4InstallSearchHook(search);

    NSArray<NSString *> *selectors = @[
        @"tfn_supportsTabBarCollapsing",
        @"tfn_prefersTabBarPinned",
        @"tfn_preferManualNavBarCollapse"
    ];

    BOOL rootMethodsOK = YES;
    for (NSString *selectorName in selectors) {
        rootMethodsOK &=
            XLG21B4CopyHomeCapabilityToClass(
                home,
                search,
                selectorName);
    }

    BOOL rootPropertiesOK = YES;
    rootPropertiesOK &= XLG21B4AddReadonlyBoolProperty(
        search, "tfn_supportsTabBarCollapsing");
    rootPropertiesOK &= XLG21B4AddReadonlyBoolProperty(
        search, "tfn_prefersTabBarPinned");
    rootPropertiesOK &= XLG21B4AddReadonlyBoolProperty(
        search, "tfn_preferManualNavBarCollapse");

    gXLG21B4Installed =
        hookOK &&
        rootMethodsOK &&
        rootPropertiesOK;

    XLG21B4Log(@"INSTALL_RESULT success=%d hook=%d rootMethods=%d rootProperties=%d search=%@ home=%@",
               gXLG21B4Installed,
               hookOK,
               rootMethodsOK,
               rootPropertiesOK,
               NSStringFromClass(search),
               NSStringFromClass(home));
}

static void XLG21B4Retry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            XLG21B4Install();
        });
}

__attribute__((constructor))
static void XLiquidGlass21Beta4Init(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager]
            removeItemAtPath:XLG21B4LogPath()
                       error:nil];

        XLG21B4Log(@"========== XLiquidGlass 2.1 Beta 4 Search Owned Native Collapse ==========");
        XLG21B4Log(@"BASE commit=622de1df3306264894ff5ce9f31a9e882fa34e98");
        XLG21B4Log(@"TARGET root=TTSSearchContainerViewControllerV2 + owned-controller-tree");
        XLG21B4Log(@"SOURCE policy=TwitterHomeFeatureImplementation.HomeTimelineContainerViewController");
        XLG21B4Log(@"PROBE in-settings copy-report enabled");
        XLG21B4Log(@"GUARD no-tabbar-transform-writes no-collapse-engine-ivar-writes no-manual-animation");

        XLG21B4Install();

        XLG21B4Retry(0.05);
        XLG21B4Retry(0.20);
        XLG21B4Retry(0.50);
        XLG21B4Retry(1.00);
        XLG21B4Retry(2.00);
        XLG21B4Retry(4.00);
    }
}
