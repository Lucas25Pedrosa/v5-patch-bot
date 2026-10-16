#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

// XLiquidGlassNative 3.0
// Native activation path only. No navigation, badge, sidebar, blur,
// tab-label, legacy-host or visual/runtime fixes.
// The only extra UI is a localized NeoFreeBird Appearance submenu toggle.

static NSString *const kXLGNativeEnabledKey = @"XLiquidGlassEnabled";
static NSString *const kXLGNativePersistedGateKey = @"T1LiquidGlassRedesignPersistedGate";

static IMP gOrigInstallGate = NULL;
static IMP gOrigInstallGateForAccount = NULL;
static IMP gOrigAccountGate = NULL;
static IMP gOrigAppearanceUpdateVisibleToggles = NULL;
static IMP gOrigAppearanceViewWillAppear = NULL;

static BOOL gDebugSettingsHooked = NO;
static BOOL gSwiftLiquidGlassHooked = NO;
static BOOL gRedesignFeaturesHooked = NO;
static BOOL gInstallGateHooked = NO;
static BOOL gInstallGateForAccountHooked = NO;
static BOOL gAccountGateHooked = NO;
static BOOL gAppearanceSettingsHooked = NO;

static BOOL XLGNativeEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:kXLGNativeEnabledKey];
    return stored ? [stored boolValue] : YES;
}

static BOOL XLGNativeHookMethod(Class cls,
                                SEL sel,
                                BOOL classMethod,
                                IMP replacement,
                                IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;

    Method method = classMethod ? class_getClassMethod(cls, sel)
                                : class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    Class target = classMethod ? object_getClass(cls) : cls;
    if (!target) return NO;

    IMP current = class_getMethodImplementation(target, sel);
    if (current == replacement) return YES;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    if (originalOut && !*originalOut) {
        *originalOut = current;
    }

    class_replaceMethod(target, sel, replacement, types);
    return class_getMethodImplementation(target, sel) == replacement;
}

#pragma mark - Native Liquid Glass activation gates

static BOOL XLGNativeReturnState(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return XLGNativeEnabled();
}

static BOOL XLGNativeAccountGate(id self, SEL _cmd) {
    if (XLGNativeEnabled()) return YES;
    if (gOrigAccountGate) {
        return ((BOOL (*)(id, SEL))gOrigAccountGate)(self, _cmd);
    }
    return NO;
}

static void XLGNativeInstallGateWithRedesignEnabled(id self,
                                                     SEL _cmd,
                                                     BOOL requestedState) {
    if (!gOrigInstallGate) return;

    BOOL forwarded = XLGNativeEnabled() ? YES : requestedState;
    ((void (*)(id, SEL, BOOL))gOrigInstallGate)(self, _cmd, forwarded);
}

static void XLGNativeInstallGateForAccount(id self, SEL _cmd, id account) {
    if (gOrigInstallGateForAccount) {
        ((void (*)(id, SEL, id))gOrigInstallGateForAccount)(self, _cmd, account);
    }

    if (!XLGNativeEnabled()) return;

    SEL gateSEL = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    if ([self respondsToSelector:gateSEL]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, gateSEL, YES);
    }
}

static void XLGNativeSyncPersistedGate(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if (XLGNativeEnabled()) {
        [defaults setBool:YES forKey:kXLGNativePersistedGateKey];

        Class compatibility =
            NSClassFromString(@"_TtC17TFSUtilitiesSwift32LiquidGlassCompatibilityOverride");
        SEL applySEL = NSSelectorFromString(@"applyOverrideIfNeeded");

        if (compatibility && [compatibility respondsToSelector:applySEL]) {
            ((void (*)(id, SEL))objc_msgSend)(compatibility, applySEL);
        }
    } else {
        [defaults removeObjectForKey:kXLGNativePersistedGateKey];
    }

    Class installer = NSClassFromString(@"T1LiquidGlassGateInstaller");
    SEL gateSEL = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    if (installer && [installer respondsToSelector:gateSEL] && XLGNativeEnabled()) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(installer, gateSEL, YES);
    }
}

static void XLGNativeInstallActivationHooks(void) {
    Class cls = Nil;

    if (!gDebugSettingsHooked) {
        cls = NSClassFromString(@"T1LiquidGlassDebugSettings");
        if (cls) {
            gDebugSettingsHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"useTabBarControllerEnabled"),
                YES,
                (IMP)XLGNativeReturnState,
                NULL
            );
        }
    }

    if (!gSwiftLiquidGlassHooked) {
        cls = NSClassFromString(@"_TtC17TFSUtilitiesSwift11LiquidGlass");
        if (cls) {
            gSwiftLiquidGlassHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"isEnabled"),
                YES,
                (IMP)XLGNativeReturnState,
                NULL
            );
        }
    }

    if (!gRedesignFeaturesHooked) {
        cls = NSClassFromString(@"_TtC14T1TwitterSwift27LiquidGlassRedesignFeatures");
        if (cls) {
            gRedesignFeaturesHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"isRedesignEnabled"),
                NO,
                (IMP)XLGNativeReturnState,
                NULL
            );
        }
    }

    cls = NSClassFromString(@"T1LiquidGlassGateInstaller");
    if (cls) {
        if (!gInstallGateHooked) {
            gInstallGateHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"installGateWithRedesignEnabled:"),
                YES,
                (IMP)XLGNativeInstallGateWithRedesignEnabled,
                &gOrigInstallGate
            );
        }

        if (!gInstallGateForAccountHooked) {
            gInstallGateForAccountHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"installGateForAccount:"),
                YES,
                (IMP)XLGNativeInstallGateForAccount,
                &gOrigInstallGateForAccount
            );
        }
    }

    if (!gAccountGateHooked) {
        cls = NSClassFromString(@"TFNTwitterAccount");
        if (cls) {
            gAccountGateHooked = XLGNativeHookMethod(
                cls,
                NSSelectorFromString(@"isDummyTest1FeatureEnabled"),
                NO,
                (IMP)XLGNativeAccountGate,
                &gOrigAccountGate
            );
        }
    }

    XLGNativeSyncPersistedGate();
}

#pragma mark - Localization

static NSString *XLGNativeLanguageCode(void) {
    NSString *language = NSLocale.preferredLanguages.firstObject ?: @"en";
    NSString *lower = language.lowercaseString;

    if ([lower hasPrefix:@"zh-hant"] ||
        [lower hasPrefix:@"zh-tw"] ||
        [lower hasPrefix:@"zh-hk"] ||
        [lower hasPrefix:@"zh-mo"]) {
        return @"zh-Hant";
    }
    if ([lower hasPrefix:@"zh"]) return @"zh-Hans";

    NSArray<NSString *> *supported = @[
        @"ar", @"de", @"en", @"es", @"fr", @"hr", @"id", @"ja", @"ko",
        @"pl", @"pt", @"ru", @"sv", @"tr", @"uk"
    ];
    for (NSString *code in supported) {
        if ([lower hasPrefix:code]) return code;
    }
    return @"en";
}

static NSString *XLGNativeLoc(NSString *key) {
    static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *tables;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tables = @{
            @"en": @{
                @"enable_title": @"Enable Liquid Glass",
                @"enable_detail": @"Uses the native redesign built into X.",
                @"restart_footer": @"Restart X after changing this option to fully apply the interface.",
                @"restart_alert": @"Restart X to fully apply the change.",
                @"ok": @"OK"
            },
            @"pt": @{
                @"enable_title": @"Ativar Liquid Glass",
                @"enable_detail": @"Usa o redesign nativo presente no X.",
                @"restart_footer": @"Reinicie o X após alterar esta opção para aplicar completamente a interface.",
                @"restart_alert": @"Reinicie o X para aplicar completamente a alteração.",
                @"ok": @"OK"
            },
            @"es": @{
                @"enable_title": @"Activar Liquid Glass",
                @"enable_detail": @"Usa el rediseño nativo integrado en X.",
                @"restart_footer": @"Reinicia X después de cambiar esta opción para aplicar completamente la interfaz.",
                @"restart_alert": @"Reinicia X para aplicar completamente el cambio.",
                @"ok": @"Aceptar"
            },
            @"fr": @{
                @"enable_title": @"Activer Liquid Glass",
                @"enable_detail": @"Utilise la nouvelle interface native intégrée à X.",
                @"restart_footer": @"Redémarrez X après avoir modifié cette option pour appliquer complètement l’interface.",
                @"restart_alert": @"Redémarrez X pour appliquer complètement la modification.",
                @"ok": @"OK"
            },
            @"de": @{
                @"enable_title": @"Liquid Glass aktivieren",
                @"enable_detail": @"Verwendet das in X integrierte native Redesign.",
                @"restart_footer": @"Starte X nach dem Ändern dieser Option neu, damit die Oberfläche vollständig angewendet wird.",
                @"restart_alert": @"Starte X neu, um die Änderung vollständig anzuwenden.",
                @"ok": @"OK"
            },
            @"ar": @{
                @"enable_title": @"تفعيل Liquid Glass",
                @"enable_detail": @"يستخدم التصميم الأصلي الجديد المدمج في X.",
                @"restart_footer": @"أعد تشغيل X بعد تغيير هذا الخيار لتطبيق الواجهة بالكامل.",
                @"restart_alert": @"أعد تشغيل X لتطبيق التغيير بالكامل.",
                @"ok": @"موافق"
            },
            @"hr": @{
                @"enable_title": @"Omogući Liquid Glass",
                @"enable_detail": @"Koristi izvorni redizajn ugrađen u X.",
                @"restart_footer": @"Ponovno pokrenite X nakon promjene ove opcije kako bi se sučelje u potpunosti primijenilo.",
                @"restart_alert": @"Ponovno pokrenite X kako biste u potpunosti primijenili promjenu.",
                @"ok": @"U redu"
            },
            @"id": @{
                @"enable_title": @"Aktifkan Liquid Glass",
                @"enable_detail": @"Menggunakan desain ulang native yang tersedia di X.",
                @"restart_footer": @"Mulai ulang X setelah mengubah opsi ini agar antarmuka diterapkan sepenuhnya.",
                @"restart_alert": @"Mulai ulang X untuk menerapkan perubahan sepenuhnya.",
                @"ok": @"OK"
            },
            @"ja": @{
                @"enable_title": @"Liquid Glassを有効にする",
                @"enable_detail": @"Xに組み込まれているネイティブの新デザインを使用します。",
                @"restart_footer": @"このオプションを変更した後、インターフェースを完全に適用するにはXを再起動してください。",
                @"restart_alert": @"変更を完全に適用するにはXを再起動してください。",
                @"ok": @"OK"
            },
            @"ko": @{
                @"enable_title": @"Liquid Glass 활성화",
                @"enable_detail": @"X에 내장된 네이티브 리디자인을 사용합니다.",
                @"restart_footer": @"이 옵션을 변경한 후 인터페이스를 완전히 적용하려면 X를 다시 시작하세요.",
                @"restart_alert": @"변경 사항을 완전히 적용하려면 X를 다시 시작하세요.",
                @"ok": @"확인"
            },
            @"pl": @{
                @"enable_title": @"Włącz Liquid Glass",
                @"enable_detail": @"Używa natywnego przeprojektowanego interfejsu wbudowanego w X.",
                @"restart_footer": @"Uruchom ponownie X po zmianie tej opcji, aby w pełni zastosować interfejs.",
                @"restart_alert": @"Uruchom ponownie X, aby w pełni zastosować zmianę.",
                @"ok": @"OK"
            },
            @"ru": @{
                @"enable_title": @"Включить Liquid Glass",
                @"enable_detail": @"Использует встроенный в X нативный обновлённый интерфейс.",
                @"restart_footer": @"Перезапустите X после изменения этой настройки, чтобы интерфейс применился полностью.",
                @"restart_alert": @"Перезапустите X, чтобы полностью применить изменение.",
                @"ok": @"OK"
            },
            @"sv": @{
                @"enable_title": @"Aktivera Liquid Glass",
                @"enable_detail": @"Använder den inbyggda nya designen i X.",
                @"restart_footer": @"Starta om X efter att du ändrat det här alternativet för att tillämpa gränssnittet fullt ut.",
                @"restart_alert": @"Starta om X för att tillämpa ändringen fullt ut.",
                @"ok": @"OK"
            },
            @"tr": @{
                @"enable_title": @"Liquid Glass'ı etkinleştir",
                @"enable_detail": @"X'e yerleşik olan doğal yeni tasarımı kullanır.",
                @"restart_footer": @"Arayüzün tamamen uygulanması için bu seçeneği değiştirdikten sonra X'i yeniden başlatın.",
                @"restart_alert": @"Değişikliği tamamen uygulamak için X'i yeniden başlatın.",
                @"ok": @"Tamam"
            },
            @"uk": @{
                @"enable_title": @"Увімкнути Liquid Glass",
                @"enable_detail": @"Використовує вбудований у X нативний оновлений інтерфейс.",
                @"restart_footer": @"Перезапустіть X після зміни цього параметра, щоб інтерфейс застосувався повністю.",
                @"restart_alert": @"Перезапустіть X, щоб повністю застосувати зміну.",
                @"ok": @"Гаразд"
            },
            @"zh-Hant": @{
                @"enable_title": @"啟用 Liquid Glass",
                @"enable_detail": @"使用 X 內建的原生重新設計介面。",
                @"restart_footer": @"變更此選項後請重新啟動 X，以完整套用介面。",
                @"restart_alert": @"請重新啟動 X，以完整套用變更。",
                @"ok": @"好"
            },
            @"zh-Hans": @{
                @"enable_title": @"启用 Liquid Glass",
                @"enable_detail": @"使用 X 内置的原生重新设计界面。",
                @"restart_footer": @"更改此选项后请重新启动 X，以完整应用界面。",
                @"restart_alert": @"请重新启动 X，以完整应用更改。",
                @"ok": @"好"
            }
        };
    });

    NSDictionary<NSString *, NSString *> *english = tables[@"en"];
    NSDictionary<NSString *, NSString *> *table = tables[XLGNativeLanguageCode()] ?: english;
    return table[key] ?: english[key] ?: key;
}

#pragma mark - NeoFreeBird Appearance submenu

@interface XLiquidGlassNativeSettingsViewController : UITableViewController
@end

@implementation XLiquidGlassNativeSettingsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Liquid Glass";
    self.tableView.backgroundColor = UIColor.systemBackgroundColor;
    self.tableView.estimatedRowHeight = 60.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return XLGNativeLoc(@"restart_footer");
}

- (void)tableView:(UITableView *)tableView
 willDisplayFooterView:(UIView *)view
       forSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;
        footer.textLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)indexPath;

    static NSString *identifier = @"XLiquidGlassNativeToggleCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }

    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    cell.textLabel.text = XLGNativeLoc(@"enable_title");
    cell.textLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightRegular];
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.82;
    cell.textLabel.numberOfLines = 1;

    cell.detailTextLabel.text = XLGNativeLoc(@"enable_detail");
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 2;

    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    toggle.on = XLGNativeEnabled();
    [toggle addTarget:self
               action:@selector(xlgNativeToggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;

    return cell;
}

- (void)xlgNativeToggleChanged:(UISwitch *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn
                                            forKey:kXLGNativeEnabledKey];
    XLGNativeSyncPersistedGate();

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Liquid Glass"
                                            message:XLGNativeLoc(@"restart_alert")
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:XLGNativeLoc(@"ok")
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

static BOOL XLGNativeArrayContainsAction(NSArray *entries, NSString *action) {
    for (id entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"action"] isEqualToString:action]) return YES;
    }
    return NO;
}

static NSArray *XLGNativeArrayForKey(id controller, NSString *key) {
    if (!controller || !key.length) return nil;
    @try {
        id value = [controller valueForKey:key];
        return [value isKindOfClass:NSArray.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void XLGNativeSetArrayForKey(id controller, NSString *key, NSArray *value) {
    if (!controller || !key.length || !value) return;
    @try {
        [controller setValue:value forKey:key];
    } @catch (__unused NSException *exception) {
    }
}

static void XLGNativeReloadControllerTable(id controller) {
    UITableView *tableView = nil;
    @try {
        id value = [controller valueForKey:@"tableView"];
        if ([value isKindOfClass:UITableView.class]) tableView = value;
    } @catch (__unused NSException *exception) {
    }
    [tableView reloadData];
}

static void XLGNativeShowSettings(id self) {
    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassNativeSettingsViewController *settings =
        [[XLiquidGlassNativeSettingsViewController alloc] init];

    UINavigationController *navigation =
        ((UIViewController *)self).navigationController;

    if (navigation) {
        [navigation pushViewController:settings animated:YES];
    } else {
        UINavigationController *wrapper =
            [[UINavigationController alloc] initWithRootViewController:settings];
        [(UIViewController *)self presentViewController:wrapper
                                              animated:YES
                                            completion:nil];
    }
}

static void XLGNativeShowSettingsFromAppearance(id self, SEL _cmd, id sender) {
    (void)_cmd;
    (void)sender;
    XLGNativeShowSettings(self);
}

static void XLGNativeInjectAppearanceButton(id controller) {
    NSArray *visible = XLGNativeArrayForKey(controller, @"visibleToggles");
    if (!visible) return;

    NSString *action = @"showXLiquidGlassNativeSettings:";
    if (XLGNativeArrayContainsAction(visible, action)) return;

    NSDictionary *entry = @{
        @"type": @"button",
        @"key": @"xlg_native_liquid_glass_button",
        @"titleKey": @"Liquid Glass",
        @"action": action
    };

    NSMutableArray *updated = [visible mutableCopy];
    NSUInteger insertIndex = MIN((NSUInteger)3, updated.count);
    [updated insertObject:entry atIndex:insertIndex];
    XLGNativeSetArrayForKey(controller, @"visibleToggles", [updated copy]);
}

static void XLGNativeAppearanceUpdateVisibleToggles(id self, SEL _cmd) {
    if (gOrigAppearanceUpdateVisibleToggles) {
        ((void (*)(id, SEL))gOrigAppearanceUpdateVisibleToggles)(self, _cmd);
    }
    XLGNativeInjectAppearanceButton(self);
}

static void XLGNativeAppearanceViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigAppearanceViewWillAppear) {
        ((void (*)(id, SEL, BOOL))gOrigAppearanceViewWillAppear)(self, _cmd, animated);
    }
    XLGNativeInjectAppearanceButton(self);
    XLGNativeReloadControllerTable(self);
}

static void XLGNativeInstallNFBSettingsIntegration(void) {
    if (gAppearanceSettingsHooked) return;

    Class cls = NSClassFromString(@"AppearanceSettingsViewController");
    if (!cls) return;

    SEL showSEL = NSSelectorFromString(@"showXLiquidGlassNativeSettings:");
    if (![cls instancesRespondToSelector:showSEL]) {
        class_addMethod(cls, showSEL, (IMP)XLGNativeShowSettingsFromAppearance, "v@:@");
    }

    BOOL updateHooked = XLGNativeHookMethod(
        cls,
        NSSelectorFromString(@"updateVisibleToggles"),
        NO,
        (IMP)XLGNativeAppearanceUpdateVisibleToggles,
        &gOrigAppearanceUpdateVisibleToggles
    );

    BOOL appearHooked = XLGNativeHookMethod(
        cls,
        @selector(viewWillAppear:),
        NO,
        (IMP)XLGNativeAppearanceViewWillAppear,
        &gOrigAppearanceViewWillAppear
    );

    gAppearanceSettingsHooked = updateHooked || appearHooked;
}

static void XLGNativeInstall(void) {
    XLGNativeInstallActivationHooks();
    XLGNativeInstallNFBSettingsIntegration();
}

static void XLGNativeScheduleRetry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            XLGNativeInstall();
        }
    );
}

__attribute__((constructor))
static void XLiquidGlassNativeInit(void) {
    @autoreleasepool {
        NSLog(@"[XLiquidGlassNative] 3.0.0 loaded - native activation + NFB Appearance submenu");

        XLGNativeInstall();
        XLGNativeScheduleRetry(0.00);
        XLGNativeScheduleRetry(0.05);
        XLGNativeScheduleRetry(0.20);
        XLGNativeScheduleRetry(0.50);
        XLGNativeScheduleRetry(1.00);
        XLGNativeScheduleRetry(2.00);
        XLGNativeScheduleRetry(4.00);
    }
}
