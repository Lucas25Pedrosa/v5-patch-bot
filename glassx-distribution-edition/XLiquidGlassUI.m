#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

// GlassXDistributionEdition 3.0.0a
// UI/preferences only. Liquid Glass activation lives exclusively in
// XLiquidGlass1238Engine.m.

static NSString *const kXLGEnabledKey = @"XLiquidGlassEnabled";
static NSString *const kXLGLegacyPersistedGateKey = @"T1LiquidGlassRedesignPersistedGate";

static IMP gXLGOrigAppearanceUpdateVisibleToggles = NULL;
static IMP gXLGOrigAppearanceViewWillAppear = NULL;
static BOOL gXLGAppearanceSettingsHooked = NO;

static BOOL XLGEnabled(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kXLGEnabledKey];
    return stored ? [stored boolValue] : YES;
}

static BOOL XLGHookMethod(Class cls,
                          SEL sel,
                          IMP replacement,
                          IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP current = class_getMethodImplementation(cls, sel);
    if (current == replacement) return YES;

    if (originalOut && !*originalOut) *originalOut = current;
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    return class_getMethodImplementation(cls, sel) == replacement;
}

#pragma mark - Localization

static NSString *XLGUILanguageCode(void) {
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

static NSString *XLGUIText(NSString *key) {
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
    NSDictionary<NSString *, NSString *> *table = tables[XLGUILanguageCode()] ?: english;
    return table[key] ?: english[key] ?: key;
}

@interface XLiquidGlassSettingsViewController : UITableViewController
@end

@implementation XLiquidGlassSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
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
    return XLGUIText(@"restart_footer");
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

    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = XLGUIText(@"enable_title");
    cell.detailTextLabel.text = XLGUIText(@"enable_detail");
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.numberOfLines = 2;

    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
    toggle.on = XLGEnabled();
    [toggle addTarget:self
               action:@selector(xlgToggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;

    return cell;
}

- (void)xlgToggleChanged:(UISwitch *)sender {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:sender.isOn forKey:kXLGEnabledKey];

    // Cleanup only: this key belonged to the retired pre-12.38 engine.
    // The new engine does not use it.
    if (!sender.isOn) {
        [defaults removeObjectForKey:kXLGLegacyPersistedGateKey];
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Liquid Glass"
                                            message:XLGUIText(@"restart_alert")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:XLGUIText(@"ok")
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

static BOOL XLGArrayContainsAction(NSArray *entries, NSString *action) {
    for (id entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"action"] isEqualToString:action]) return YES;
    }
    return NO;
}

static NSArray *XLGArrayForKey(id controller, NSString *key) {
    @try {
        id value = [controller valueForKey:key];
        return [value isKindOfClass:NSArray.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void XLGSetArrayForKey(id controller, NSString *key, NSArray *value) {
    @try {
        [controller setValue:value forKey:key];
    } @catch (__unused NSException *exception) {
    }
}

static void XLGReloadControllerTable(id controller) {
    @try {
        id value = [controller valueForKey:@"tableView"];
        if ([value isKindOfClass:UITableView.class]) [(UITableView *)value reloadData];
    } @catch (__unused NSException *exception) {
    }
}

static void XLGShowSettings(id self) {
    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassSettingsViewController *settings =
        [[XLiquidGlassSettingsViewController alloc] init];
    UINavigationController *navigation = ((UIViewController *)self).navigationController;

    if (navigation) {
        [navigation pushViewController:settings animated:YES];
    } else {
        UINavigationController *wrapper =
            [[UINavigationController alloc] initWithRootViewController:settings];
        [(UIViewController *)self presentViewController:wrapper animated:YES completion:nil];
    }
}

static void XLGShowSettingsFromAppearance(id self, SEL _cmd, id sender) {
    (void)_cmd;
    (void)sender;
    XLGShowSettings(self);
}

static void XLGInjectAppearanceButton(id controller) {
    NSArray *visible = XLGArrayForKey(controller, @"visibleToggles");
    if (!visible) return;

    NSString *action = @"showXLiquidGlassNativeSettings:";
    if (XLGArrayContainsAction(visible, action)) return;

    NSDictionary *entry = @{
        @"type": @"button",
        @"key": @"xlg_native_liquid_glass_button",
        @"titleKey": @"Liquid Glass",
        @"action": action
    };

    NSMutableArray *updated = [visible mutableCopy];
    NSUInteger insertIndex = MIN((NSUInteger)3, updated.count);
    [updated insertObject:entry atIndex:insertIndex];
    XLGSetArrayForKey(controller, @"visibleToggles", [updated copy]);
}

static void XLGAppearanceUpdateVisibleToggles(id self, SEL _cmd) {
    if (gXLGOrigAppearanceUpdateVisibleToggles) {
        ((void (*)(id, SEL))gXLGOrigAppearanceUpdateVisibleToggles)(self, _cmd);
    }
    XLGInjectAppearanceButton(self);
}

static void XLGAppearanceViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gXLGOrigAppearanceViewWillAppear) {
        ((void (*)(id, SEL, BOOL))gXLGOrigAppearanceViewWillAppear)(self, _cmd, animated);
    }
    XLGInjectAppearanceButton(self);
    XLGReloadControllerTable(self);
}

static void XLGInstallNFBSettingsIntegration(void) {
    if (gXLGAppearanceSettingsHooked) return;

    Class cls = NSClassFromString(@"AppearanceSettingsViewController");
    if (!cls) return;

    SEL showSEL = NSSelectorFromString(@"showXLiquidGlassNativeSettings:");
    if (![cls instancesRespondToSelector:showSEL]) {
        class_addMethod(cls, showSEL, (IMP)XLGShowSettingsFromAppearance, "v@:@");
    }

    BOOL updateHooked = XLGHookMethod(
        cls,
        NSSelectorFromString(@"updateVisibleToggles"),
        (IMP)XLGAppearanceUpdateVisibleToggles,
        &gXLGOrigAppearanceUpdateVisibleToggles
    );

    BOOL appearHooked = XLGHookMethod(
        cls,
        @selector(viewWillAppear:),
        (IMP)XLGAppearanceViewWillAppear,
        &gXLGOrigAppearanceViewWillAppear
    );

    gXLGAppearanceSettingsHooked = updateHooked || appearHooked;
}

static void XLGScheduleUIRetry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            XLGInstallNFBSettingsIntegration();
        }
    );
}

__attribute__((constructor))
static void XLiquidGlassUIInit(void) {
    @autoreleasepool {
        NSLog(@"[GlassXDE] 3.0.0a UI loaded; locale=%@; activation handled by X12.38 engine", XLGUILanguageCode());
        XLGInstallNFBSettingsIntegration();
        for (NSNumber *delay in @[@0.0, @0.05, @0.20, @0.50, @1.0, @2.0, @4.0]) {
            XLGScheduleUIRetry(delay.doubleValue);
        }
    }
}
