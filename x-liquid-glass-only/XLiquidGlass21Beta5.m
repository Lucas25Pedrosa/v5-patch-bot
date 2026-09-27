#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>

#pragma mark - XLiquidGlass 2.1 Beta 5 Search direct property declaration

static NSString *const kXLG21B5LogName = @"XLiquidGlass21Beta5.log";

static BOOL gXLG21B5Installed = NO;
static IMP gXLG21B5OrigSearchViewDidAppear = NULL;
static IMP gXLG21B5OrigNFBSetupSections = NULL;
static IMP gXLG21B5OrigNFBViewWillAppear = NULL;

static NSString *XLG21B5LogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kXLG21B5LogName];
}

static void XLG21B5Log(NSString *format, ...) {
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
    NSLog(@"[XLiquidGlass 2.1 Beta 5] %@", message ?: @"");

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = XLG21B5LogPath();

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

static NSString *XLG21B5SymbolForIMP(IMP imp) {
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

static BOOL XLG21B5ClassDeclaresSelector(Class cls, SEL sel) {
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

static BOOL XLG21B5ClassDeclaresProperty(Class cls, const char *name) {
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

static BOOL XLG21B5CopyHomeMethod(
    Class home,
    Class search,
    NSString *selectorName) {

    SEL sel = NSSelectorFromString(selectorName);
    Method homeMethod = class_getInstanceMethod(home, sel);
    Method searchMethod = class_getInstanceMethod(search, sel);

    if (!homeMethod || !searchMethod) {
        XLG21B5Log(@"METHOD_COPY selector=%@ success=0 reason=method-missing home=%p search=%p",
                   selectorName,
                   homeMethod,
                   searchMethod);
        return NO;
    }

    const char *homeTypes = method_getTypeEncoding(homeMethod);
    const char *searchTypes = method_getTypeEncoding(searchMethod);
    IMP homeIMP = method_getImplementation(homeMethod);
    IMP beforeIMP = class_getMethodImplementation(search, sel);

    if (!homeTypes || !searchTypes || strcmp(homeTypes, searchTypes) != 0) {
        XLG21B5Log(@"METHOD_COPY selector=%@ success=0 reason=encoding-mismatch homeTypes=%s searchTypes=%s",
                   selectorName,
                   homeTypes ?: "-",
                   searchTypes ?: "-");
        return NO;
    }

    BOOL directBefore = XLG21B5ClassDeclaresSelector(search, sel);
    BOOL added = NO;

    if (directBefore) {
        class_replaceMethod(search, sel, homeIMP, homeTypes);
    } else {
        added = class_addMethod(search, sel, homeIMP, homeTypes);
        if (!added) {
            class_replaceMethod(search, sel, homeIMP, homeTypes);
        }
    }

    IMP finalIMP = class_getMethodImplementation(search, sel);
    BOOL directAfter = XLG21B5ClassDeclaresSelector(search, sel);
    BOOL success = directAfter && finalIMP == homeIMP;

    XLG21B5Log(
        @"METHOD_COPY selector=%@ success=%d directBefore=%d added=%d directAfter=%d beforeIMP=%p homeIMP=%p finalIMP=%p homeSymbol=%@",
        selectorName,
        success,
        directBefore,
        added,
        directAfter,
        beforeIMP,
        homeIMP,
        finalIMP,
        XLG21B5SymbolForIMP(homeIMP));

    return success;
}

static BOOL XLG21B5CopyHomeProperty(
    Class home,
    Class search,
    const char *propertyName) {

    if (!home || !search || !propertyName) return NO;

    objc_property_t source = class_getProperty(home, propertyName);
    if (!source) {
        XLG21B5Log(@"PROPERTY_COPY name=%s success=0 reason=source-missing",
                   propertyName);
        return NO;
    }

    unsigned int attributeCount = 0;
    objc_property_attribute_t *attributes =
        property_copyAttributeList(source, &attributeCount);

    if (!attributes || attributeCount == 0) {
        XLG21B5Log(@"PROPERTY_COPY name=%s success=0 reason=no-attributes",
                   propertyName);
        free(attributes);
        return NO;
    }

    BOOL directBefore = XLG21B5ClassDeclaresProperty(search, propertyName);
    const char *sourceAttrs = property_getAttributes(source);

    class_replaceProperty(
        search,
        propertyName,
        attributes,
        attributeCount);

    free(attributes);

    BOOL directAfter = XLG21B5ClassDeclaresProperty(search, propertyName);
    objc_property_t finalProperty = class_getProperty(search, propertyName);
    const char *finalAttrs =
        finalProperty ? property_getAttributes(finalProperty) : NULL;

    BOOL success = directAfter && finalProperty != NULL;

    XLG21B5Log(
        @"PROPERTY_COPY name=%s success=%d directBefore=%d directAfter=%d sourceAttrs=%s finalAttrs=%s",
        propertyName,
        success,
        directBefore,
        directAfter,
        sourceAttrs ?: "-",
        finalAttrs ?: "-");

    return success;
}

static void XLG21B5ValidateSearchDeclaration(Class home, Class search) {
    NSArray<NSString *> *names = @[
        @"tfn_supportsTabBarCollapsing",
        @"tfn_prefersTabBarPinned",
        @"tfn_preferManualNavBarCollapse"
    ];

    XLG21B5Log(@"========== DECLARATION_VALIDATE_BEGIN ==========");

    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        const char *propertyName = name.UTF8String;

        IMP homeIMP = class_getMethodImplementation(home, sel);
        IMP searchIMP = class_getMethodImplementation(search, sel);
        BOOL methodDirect = XLG21B5ClassDeclaresSelector(search, sel);
        BOOL propertyDirect =
            XLG21B5ClassDeclaresProperty(search, propertyName);

        objc_property_t property = class_getProperty(search, propertyName);
        const char *attrs = property ? property_getAttributes(property) : NULL;

        XLG21B5Log(
            @"DECLARATION_STATUS name=%@ methodDirect=%d propertyDirect=%d searchIMP=%p homeIMP=%p impMatch=%d propertyAttrs=%s",
            name,
            methodDirect,
            propertyDirect,
            searchIMP,
            homeIMP,
            searchIMP == homeIMP,
            attrs ?: "-");
    }

    XLG21B5Log(@"========== DECLARATION_VALIDATE_END ==========");
}

static void XLG21B5RequestNativeRefresh(id controller) {
    if (!controller) return;

    SEL xnav = NSSelectorFromString(
        @"xnav_setNeedsNavigationConfigurationUpdateAnimated:");
    if ([controller respondsToSelector:xnav]) {
        ((void(*)(id,SEL,BOOL))objc_msgSend)(controller, xnav, NO);
        XLG21B5Log(@"REFRESH object=%p class=%@ selector=%@",
                   controller,
                   NSStringFromClass([controller class]),
                   NSStringFromSelector(xnav));
    }

    SEL tabStyle =
        NSSelectorFromString(@"tfn_setNeedsTabBarStyleOverridesUpdate");
    if ([controller respondsToSelector:tabStyle]) {
        ((void(*)(id,SEL))objc_msgSend)(controller, tabStyle);
        XLG21B5Log(@"REFRESH object=%p class=%@ selector=%@",
                   controller,
                   NSStringFromClass([controller class]),
                   NSStringFromSelector(tabStyle));
    }

    SEL navExpansion =
        NSSelectorFromString(@"tfn_setNeedsNavigationBarExpansionUpdate");
    if ([controller respondsToSelector:navExpansion]) {
        ((void(*)(id,SEL))objc_msgSend)(controller, navExpansion);
        XLG21B5Log(@"REFRESH object=%p class=%@ selector=%@",
                   controller,
                   NSStringFromClass([controller class]),
                   NSStringFromSelector(navExpansion));
    }
}

static BOOL XLG21B5ApplySearchDeclaration(
    UIViewController *searchController,
    NSString *reason) {

    if (!searchController) return NO;

    Class home = NSClassFromString(
        @"TwitterHomeFeatureImplementation.HomeTimelineContainerViewController");
    Class search = NSClassFromString(@"TTSSearchContainerViewControllerV2");

    if (!home || !search) {
        XLG21B5Log(@"APPLY reason=%@ success=0 home=%p search=%p",
                   reason ?: @"-",
                   home,
                   search);
        return NO;
    }

    XLG21B5Log(@"========== APPLY_BEGIN reason=%@ object=%p ==========",
               reason ?: @"-",
               searchController);

    NSArray<NSString *> *names = @[
        @"tfn_supportsTabBarCollapsing",
        @"tfn_prefersTabBarPinned",
        @"tfn_preferManualNavBarCollapse"
    ];

    BOOL methodsOK = YES;
    BOOL propertiesOK = YES;

    for (NSString *name in names) {
        methodsOK &= XLG21B5CopyHomeMethod(home, search, name);
        propertiesOK &=
            XLG21B5CopyHomeProperty(home, search, name.UTF8String);
    }

    XLG21B5ValidateSearchDeclaration(home, search);
    XLG21B5RequestNativeRefresh(searchController);

    BOOL success = methodsOK && propertiesOK;

    XLG21B5Log(
        @"APPLY_RESULT reason=%@ success=%d methods=%d properties=%d",
        reason ?: @"-",
        success,
        methodsOK,
        propertiesOK);

    XLG21B5Log(@"========== APPLY_END reason=%@ ==========",
               reason ?: @"-");

    return success;
}

static Ivar XLG21B5FindIvarInHierarchy(Class cls, const char *name) {
    for (Class cursor = cls; cursor; cursor = class_getSuperclass(cursor)) {
        Ivar ivar = class_getInstanceVariable(cursor, name);
        if (ivar) return ivar;
    }
    return NULL;
}

static uint64_t XLG21B5ReadRaw64(id object, const char *name) {
    if (!object || !name) return 0;

    Ivar ivar = XLG21B5FindIvarInHierarchy(object_getClass(object), name);
    if (!ivar) return 0;

    ptrdiff_t offset = ivar_getOffset(ivar);
    uint64_t value = 0;
    const uint8_t *base =
        (const uint8_t *)(__bridge const void *)object;

    memcpy(&value, base + offset, sizeof(value));
    return value;
}

static double XLG21B5DoubleFromRaw(uint64_t raw) {
    double value = 0.0;
    memcpy(&value, &raw, sizeof(value));
    return value;
}

static id XLG21B5CollapseEngineForController(UIViewController *controller) {
    if (!controller) return nil;

    if (![NSStringFromClass(controller.class)
          isEqualToString:@"XNavigation.NavigationController"]) {
        return nil;
    }

    Ivar ivar = XLG21B5FindIvarInHierarchy(
        controller.class,
        "$__lazy_storage_$_collapseEngine");

    if (!ivar) return nil;

    @try {
        return object_getIvar(controller, ivar);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static UIWindow *XLG21B5BestWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;

        UIWindowScene *windowScene = (UIWindowScene *)scene;

        for (UIWindow *window in windowScene.windows) {
            if (!window.hidden &&
                window.alpha > 0.01 &&
                window.windowLevel == UIWindowLevelNormal) {
                return window;
            }
        }
    }

    return nil;
}

static NSString *XLG21B5LabelForRawController(
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

static void XLG21B5SnapshotCollapseState(NSString *reason) {
    UIWindow *window = XLG21B5BestWindow();

    if (!window || !window.rootViewController) {
        XLG21B5Log(@"SNAPSHOT reason=%@ window=nil", reason ?: @"-");
        return;
    }

    NSMutableArray<UIViewController *> *queue =
        [NSMutableArray arrayWithObject:window.rootViewController];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];

    XLG21B5Log(@"========== SNAPSHOT_BEGIN reason=%@ ==========",
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
            XLG21B5Log(@"VISIBLE_CONTROLLER object=%p class=%@ title=%@",
                       vc,
                       NSStringFromClass(vc.class),
                       vc.title ?: @"-");

            id engine = XLG21B5CollapseEngineForController(vc);

            if (engine) {
                uint64_t governed =
                    XLG21B5ReadRaw64(engine, "governedScreen");
                uint64_t lastUndeclared =
                    XLG21B5ReadRaw64(engine, "lastLoggedUndeclaredScreen");
                uint64_t pendingUndeclared =
                    XLG21B5ReadRaw64(engine, "pendingUndeclaredVerdict");
                uint64_t hidden =
                    XLG21B5ReadRaw64(engine, "hiddenBarTravel");
                uint64_t progress =
                    XLG21B5ReadRaw64(engine, "collapseProgress");

                XLG21B5Log(
                    @"COLLAPSE_STATE engine=%p governed=0x%016llx governedLabel=%@ lastUndeclared=0x%016llx lastUndeclaredLabel=%@ pendingUndeclared=0x%016llx pendingUndeclaredLabel=%@ hiddenBarTravel=%.6f collapseProgress=%.6f",
                    engine,
                    (unsigned long long)governed,
                    XLG21B5LabelForRawController(window, governed),
                    (unsigned long long)lastUndeclared,
                    XLG21B5LabelForRawController(window, lastUndeclared),
                    (unsigned long long)pendingUndeclared,
                    XLG21B5LabelForRawController(window, pendingUndeclared),
                    XLG21B5DoubleFromRaw(hidden),
                    XLG21B5DoubleFromRaw(progress));
            }
        }

        if (vc.presentedViewController) {
            [queue addObject:vc.presentedViewController];
        }

        [queue addObjectsFromArray:vc.childViewControllers ?: @[]];
    }

    XLG21B5Log(@"========== SNAPSHOT_END reason=%@ ==========",
               reason ?: @"-");
}

static UIViewController *XLG21B5VisibleSearchController(void) {
    UIWindow *window = XLG21B5BestWindow();
    if (!window || !window.rootViewController) return nil;

    Class searchClass =
        NSClassFromString(@"TTSSearchContainerViewControllerV2");

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

static void XLG21B5SearchViewDidAppear(
    id self,
    SEL cmd,
    BOOL animated) {

    if (gXLG21B5OrigSearchViewDidAppear) {
        ((void(*)(id,SEL,BOOL))
            gXLG21B5OrigSearchViewDidAppear)(self, cmd, animated);
    }

    XLG21B5Log(@"SEARCH_APPEARED object=%p class=%@",
               self,
               NSStringFromClass([self class]));

    XLG21B5ApplySearchDeclaration(
        (UIViewController *)self,
        @"search-viewDidAppear");

    XLG21B5SnapshotCollapseState(
        @"search-viewDidAppear-immediate");

    NSArray<NSNumber *> *delays = @[@0.10, @0.35, @0.80];

    for (NSNumber *delay in delays) {
        NSTimeInterval seconds = delay.doubleValue;

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(seconds * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{

                XLG21B5ApplySearchDeclaration(
                    (UIViewController *)self,
                    [NSString stringWithFormat:
                        @"search-viewDidAppear-%.2fs",
                        seconds]);

                XLG21B5SnapshotCollapseState(
                    [NSString stringWithFormat:
                        @"search-viewDidAppear-%.2fs",
                        seconds]);
            });
    }
}

static BOOL XLG21B5InstallSearchHook(Class search) {
    SEL sel = @selector(viewDidAppear:);
    Method method = class_getInstanceMethod(search, sel);

    if (!method) return NO;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    IMP current = class_getMethodImplementation(search, sel);

    if (current == (IMP)XLG21B5SearchViewDidAppear) {
        return YES;
    }

    gXLG21B5OrigSearchViewDidAppear = current;

    BOOL direct = XLG21B5ClassDeclaresSelector(search, sel);
    BOOL success = NO;

    if (direct) {
        class_replaceMethod(
            search,
            sel,
            (IMP)XLG21B5SearchViewDidAppear,
            types);

        success =
            class_getMethodImplementation(search, sel) ==
            (IMP)XLG21B5SearchViewDidAppear;
    } else {
        success = class_addMethod(
            search,
            sel,
            (IMP)XLG21B5SearchViewDidAppear,
            types);
    }

    XLG21B5Log(
        @"VIEW_HOOK class=%@ success=%d original=%p",
        NSStringFromClass(search),
        success,
        current);

    return success;
}

#pragma mark - Probe UI inside settings

@interface XLiquidGlassBeta5ProbeViewController : UITableViewController
@end

@implementation XLiquidGlassBeta5ProbeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"2.1 Beta 5 Probe";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {

    (void)tableView;
    return section == 0 ? 4 : 3;
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
        return @"A Beta 5 atua somente no TTSSearchContainerViewControllerV2. O objetivo é obter methodDirect=1 e propertyDirect=1 para as três capabilities da Home.";
    }

    return @"Use Copiar relatório e cole o conteúdo no chat. Não é necessário abrir Documents.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    static NSString *identifier = @"XLG21B5Cell";

    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
          reuseIdentifier:identifier];
    }

    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.accessoryType =
        UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle =
        UITableViewCellSelectionStyleDefault;

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Estado";
            cell.detailTextLabel.text =
                gXLG21B5Installed
                    ? @"Beta 5 instalada"
                    : @"Aguardando classes do X";

            cell.accessoryType =
                UITableViewCellAccessoryNone;
            cell.selectionStyle =
                UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            cell.textLabel.text =
                @"Aplicar novamente na Busca";
            cell.detailTextLabel.text =
                @"Reaplica métodos e propriedades ao container da Busca.";
        } else if (indexPath.row == 2) {
            cell.textLabel.text =
                @"Validar declaração";
            cell.detailTextLabel.text =
                @"Registra methodDirect/propertyDirect das três capabilities.";
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
            cell.detailTextLabel.text = kXLG21B5LogName;
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
            alertControllerWithTitle:@"2.1 Beta 5 Probe"
                             message:message
                      preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:
        [UIAlertAction
            actionWithTitle:@"OK"
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
            UIViewController *search =
                XLG21B5VisibleSearchController();

            if (!search) {
                [self showInfo:
                    @"A Busca não está visível. Abra a Busca, faça o teste e volte para copiar o relatório."];
                return;
            }

            XLG21B5ApplySearchDeclaration(
                search,
                @"manual-settings");

            XLG21B5SnapshotCollapseState(
                @"manual-settings");

            [self showInfo:
                @"Declaração reaplicada ao container da Busca."];
            return;
        }

        if (indexPath.row == 2) {
            Class home = NSClassFromString(
                @"TwitterHomeFeatureImplementation.HomeTimelineContainerViewController");
            Class search = NSClassFromString(
                @"TTSSearchContainerViewControllerV2");

            if (home && search) {
                XLG21B5ValidateSearchDeclaration(home, search);
                [self showInfo:@"Validação registrada."];
            } else {
                [self showInfo:@"Classes ainda não disponíveis."];
            }
            return;
        }

        XLG21B5SnapshotCollapseState(
            @"manual-settings-snapshot");

        [self showInfo:@"Snapshot registrado."];
        return;
    }

    if (indexPath.row == 0) {
        [[NSFileManager defaultManager]
            removeItemAtPath:XLG21B5LogPath()
                       error:nil];

        XLG21B5Log(@"========== NEW SESSION ==========");
        XLG21B5Log(@"VERSION XLiquidGlass 2.1 Beta 5");
        XLG21B5Log(@"MODE corrective-search-direct-method+property + settings-copy-probe");

        [self showInfo:
            @"Nova sessão iniciada. Abra a Busca, role para baixo e depois volte aqui para validar, tirar snapshot e copiar o relatório."];
        return;
    }

    if (indexPath.row == 1) {
        NSString *report =
            [NSString
                stringWithContentsOfFile:XLG21B5LogPath()
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
        removeItemAtPath:XLG21B5LogPath()
                   error:nil];

    [self showInfo:@"Relatório limpo."];
}

@end

static BOOL XLG21B5SectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;

        if ([entry[@"action"]
             isEqualToString:@"showXLiquidGlassBeta5Probe"]) {
            return YES;
        }
    }

    return NO;
}

static void XLG21B5InjectNFBSection(id controller) {
    NSArray *sections = nil;

    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        return;
    }

    if (![sections isKindOfClass:NSArray.class] ||
        XLG21B5SectionsContainEntry(sections)) {
        return;
    }

    NSMutableArray *updated = [sections mutableCopy];

    [updated addObject:@{
        @"title": @"2.1 Beta 5 Probe",
        @"subtitle": @"Busca: método + property direta.",
        @"icon": @"waveform.path.ecg",
        @"action": @"showXLiquidGlassBeta5Probe"
    }];

    @try {
        [controller
            setValue:[updated copy]
              forKey:@"sections"];
    } @catch (__unused NSException *exception) {
    }
}

static void XLG21B5NFBSetupSections(id self, SEL cmd) {
    if (gXLG21B5OrigNFBSetupSections) {
        ((void(*)(id,SEL))
            gXLG21B5OrigNFBSetupSections)(self, cmd);
    }

    XLG21B5InjectNFBSection(self);
}

static void XLG21B5NFBViewWillAppear(
    id self,
    SEL cmd,
    BOOL animated) {

    if (gXLG21B5OrigNFBViewWillAppear) {
        ((void(*)(id,SEL,BOOL))
            gXLG21B5OrigNFBViewWillAppear)(self, cmd, animated);
    }

    XLG21B5InjectNFBSection(self);

    UITableView *tableView = nil;

    @try {
        tableView = [self valueForKey:@"tableView"];
    } @catch (__unused NSException *exception) {
    }

    [tableView reloadData];
}

static void XLG21B5ShowProbe(id self, SEL cmd) {
    (void)cmd;

    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassBeta5ProbeViewController *vc =
        [XLiquidGlassBeta5ProbeViewController new];

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

static BOOL XLG21B5HookInstanceMethod(
    Class cls,
    SEL sel,
    IMP replacement,
    IMP *original) {

    if (!cls || !sel || !replacement ||
        !original || *original) {
        return NO;
    }

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    IMP current = class_getMethodImplementation(cls, sel);
    *original = current;

    BOOL direct =
        XLG21B5ClassDeclaresSelector(cls, sel);

    if (direct) {
        class_replaceMethod(
            cls,
            sel,
            replacement,
            types);

        return
            class_getMethodImplementation(cls, sel) ==
            replacement;
    }

    return class_addMethod(
        cls,
        sel,
        replacement,
        types);
}

static void XLG21B5InstallSettingsIntegration(void) {
    Class cls = NSClassFromString(
        @"ModernSettingsViewController");

    if (!cls) return;

    class_addMethod(
        cls,
        NSSelectorFromString(
            @"showXLiquidGlassBeta5Probe"),
        (IMP)XLG21B5ShowProbe,
        "v@:");

    if (!gXLG21B5OrigNFBSetupSections) {
        XLG21B5HookInstanceMethod(
            cls,
            NSSelectorFromString(@"setupSections"),
            (IMP)XLG21B5NFBSetupSections,
            &gXLG21B5OrigNFBSetupSections);
    }

    if (!gXLG21B5OrigNFBViewWillAppear) {
        XLG21B5HookInstanceMethod(
            cls,
            @selector(viewWillAppear:),
            (IMP)XLG21B5NFBViewWillAppear,
            &gXLG21B5OrigNFBViewWillAppear);
    }
}

static void XLG21B5Install(void) {
    XLG21B5InstallSettingsIntegration();

    if (gXLG21B5Installed) return;

    Class home = NSClassFromString(
        @"TwitterHomeFeatureImplementation.HomeTimelineContainerViewController");
    Class search = NSClassFromString(
        @"TTSSearchContainerViewControllerV2");

    if (!home || !search) {
        XLG21B5Log(
            @"INSTALL_WAIT home=%p search=%p",
            home,
            search);
        return;
    }

    BOOL hookOK =
        XLG21B5InstallSearchHook(search);

    NSArray<NSString *> *names = @[
        @"tfn_supportsTabBarCollapsing",
        @"tfn_prefersTabBarPinned",
        @"tfn_preferManualNavBarCollapse"
    ];

    BOOL methodsOK = YES;
    BOOL propertiesOK = YES;

    for (NSString *name in names) {
        methodsOK &=
            XLG21B5CopyHomeMethod(
                home,
                search,
                name);

        propertiesOK &=
            XLG21B5CopyHomeProperty(
                home,
                search,
                name.UTF8String);
    }

    XLG21B5ValidateSearchDeclaration(
        home,
        search);

    gXLG21B5Installed =
        hookOK &&
        methodsOK &&
        propertiesOK;

    XLG21B5Log(
        @"INSTALL_RESULT success=%d hook=%d methods=%d properties=%d home=%@ search=%@",
        gXLG21B5Installed,
        hookOK,
        methodsOK,
        propertiesOK,
        NSStringFromClass(home),
        NSStringFromClass(search));
}

static void XLG21B5Retry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            XLG21B5Install();
        });
}

__attribute__((constructor))
static void XLiquidGlass21Beta5Init(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager]
            removeItemAtPath:XLG21B5LogPath()
                       error:nil];

        XLG21B5Log(
            @"========== XLiquidGlass 2.1 Beta 5 Search Direct Property ==========");
        XLG21B5Log(
            @"BASE commit=622de1df3306264894ff5ce9f31a9e882fa34e98");
        XLG21B5Log(
            @"TARGET class=TTSSearchContainerViewControllerV2 only");
        XLG21B5Log(
            @"SOURCE methods+properties=TwitterHomeFeatureImplementation.HomeTimelineContainerViewController");
        XLG21B5Log(
            @"REQUIRE methodDirect=1 propertyDirect=1 impMatch=1");
        XLG21B5Log(
            @"PROBE in-settings copy-report enabled");
        XLG21B5Log(
            @"GUARD no-owned-class-modification no-tabbar-transform-writes no-collapse-engine-ivar-writes no-manual-animation");

        XLG21B5Install();

        XLG21B5Retry(0.05);
        XLG21B5Retry(0.20);
        XLG21B5Retry(0.50);
        XLG21B5Retry(1.00);
        XLG21B5Retry(2.00);
        XLG21B5Retry(4.00);
    }
}
