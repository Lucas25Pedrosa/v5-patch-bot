#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSMutableString *gReport;
static IMP gOrigSetupSections;
static IMP gOrigViewWillAppear;

static void PLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gReport) gReport = [NSMutableString string];
    [gReport appendFormat:@"[%@] %@\n", NSDate.date, s ?: @""];
    NSLog(@"[XSoccerGamedayProbe] %@", s ?: @"");
}

static void FeatureLog(NSString *line) {
    PLog(@"%@", line ?: @"");
}

extern void XSGRunFeatureScan(void (*logger)(NSString *));

static void DumpFlags(void) {
    NSArray *keys = @[
        @"x_sports_soccer_gameday_enabled",
        @"x_sports_development_progress_enabled",
        @"x_sports_soccer_game_odds_card_enabled",
        @"x_sports_soccer_game_selected_poll_interval_seconds",
        @"x_sports_soccer_game_background_poll_interval_seconds",
        @"x_sports_hub_home_timeline_ids"
    ];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    PLog(@"FLAGS_BEGIN");
    for (NSString *key in keys) {
        id value = [d objectForKey:key];
        PLog(@"FLAG key=%@ value=%@ bool=%d", key, value ?: @"<nil>", [d boolForKey:key]);
    }
    PLog(@"FLAGS_END");
}

static void DumpClass(NSString *name) {
    Class c = NSClassFromString(name);
    PLog(@"CLASS name=%@ present=%@ ptr=%p", name, c ? @"YES" : @"NO", c);
    if (!c) return;
    unsigned count = 0;
    Method *methods = class_copyMethodList(c, &count);
    for (unsigned i = 0; i < count && i < 80; i++) {
        PLog(@"METHOD class=%@ selector=%s", name, sel_getName(method_getName(methods[i])));
    }
    free(methods);
}

static void DumpRuntime(void) {
    PLog(@"RUNTIME_BEGIN");
    NSArray *targets = @[
        @"XSports.SportsHubViewController",
        @"XSports.SportsHubHomeViewController",
        @"XSports.SportsScheduleViewController",
        @"XSports.SportsGameViewController",
        @"XSports.SportsGameStatsViewController",
        @"XSports.SportsGamePlaysViewController",
        @"XSports.SportsPlayerLeadersViewController",
        @"T1TwitterSwift.T1SportsHubHomeFeedViewController",
        @"T1TwitterSwift.SportsGameChatContainerViewController",
        @"T1TwitterSwift.SportsGameFeedContainerViewController"
    ];
    for (NSString *name in targets) DumpClass(name);

    int count = objc_getClassList(NULL, 0);
    __unsafe_unretained Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    NSMutableArray *hits = [NSMutableArray array];
    if (classes) {
        count = objc_getClassList(classes, count);
        for (int i = 0; i < count; i++) {
            NSString *n = NSStringFromClass(classes[i]);
            if ([n rangeOfString:@"Soccer" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [n rangeOfString:@"XSports" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [n rangeOfString:@"SportsGame" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [n rangeOfString:@"SportsHub" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [hits addObject:n];
            }
        }
        free(classes);
    }
    [hits sortUsingSelector:@selector(compare:)];
    PLog(@"RUNTIME_HITS count=%lu classes=%@", (unsigned long)hits.count, hits);
    PLog(@"RUNTIME_END");
}

static void DumpUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PLog(@"UI_BEGIN");
        UIWindow *window = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) { window = w; break; }
        }
        NSMutableArray *queue = [NSMutableArray array];
        if (window) [queue addObject:window];
        NSUInteger seen = 0;
        while (queue.count && seen < 800) {
            UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
            NSString *cn = NSStringFromClass(v.class);
            NSString *text = nil;
            if ([v isKindOfClass:UILabel.class]) text = ((UILabel *)v).text;
            else if ([v isKindOfClass:UIButton.class]) text = [((UIButton *)v) titleForState:UIControlStateNormal];
            BOOL hit = [cn rangeOfString:@"Sport" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                       [cn rangeOfString:@"Soccer" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                       (text && ([text rangeOfString:@"Soccer" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                 [text rangeOfString:@"Futebol" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                 [text rangeOfString:@"Games" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                 [text rangeOfString:@"Jogos" options:NSCaseInsensitiveSearch].location != NSNotFound));
            if (hit) PLog(@"VIEW class=%@ text=%@ a11y=%@", cn, text ?: @"-", v.accessibilityLabel ?: @"-");
            [queue addObjectsFromArray:v.subviews]; seen++;
        }
        PLog(@"UI_END seen=%lu", (unsigned long)seen);
    });
}

@interface XSGProbeController : UITableViewController @end
@implementation XSGProbeController
- (void)viewDidLoad { [super viewDidLoad]; self.title = @"Soccer Gameday Probe"; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { (void)t; (void)s; return 6; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { (void)t; return 1; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { (void)t; (void)s; return @"Diagnóstico X 12.37"; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)p {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"xsg"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"xsg"];
    NSArray *a = @[@"Capturar flags", @"Probe de runtime", @"Feature switch scan", @"Capturar tela", @"Copiar relatório", @"Limpar relatório"];
    NSArray *b = @[@"Lê as chaves Soccer/Sports visíveis ao app.", @"Procura classes XSports e Soccer carregadas.", @"Mapeia classes e seletores ligados a flags/experimentos sem alterar valores.", @"Procura elementos de Sports/Soccer na UI atual.", @"Copia o relatório completo.", @"Inicia uma nova sessão limpa."];
    c.textLabel.text = a[p.row]; c.detailTextLabel.text = b[p.row]; return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)p {
    [t deselectRowAtIndexPath:p animated:YES];
    if (p.row == 0) DumpFlags();
    else if (p.row == 1) DumpRuntime();
    else if (p.row == 2) XSGRunFeatureScan(FeatureLog);
    else if (p.row == 3) DumpUI();
    else if (p.row == 4) {
        NSString *r = [gReport copy] ?: @"";
        UIPasteboard.generalPasteboard.string = r;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Relatório copiado" message:[NSString stringWithFormat:@"%lu caracteres.", (unsigned long)r.length] preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } else { gReport = [NSMutableString string]; PLog(@"NEW_SESSION version=1.1 mode=PASSIVE_FEATURE_SCAN"); }
}
@end

static BOOL HasEntry(NSArray *sections) {
    for (id e in sections) if ([e isKindOfClass:NSDictionary.class] && [[e objectForKey:@"action"] isEqual:@"showXSoccerGamedayProbe"]) return YES;
    return NO;
}
static void Inject(id controller) {
    NSArray *sections = nil;
    @try { sections = [controller valueForKey:@"sections"]; } @catch (__unused NSException *e) {}
    if (![sections isKindOfClass:NSArray.class] || HasEntry(sections)) return;
    NSMutableArray *m = [sections mutableCopy];
    [m addObject:@{@"title":@"Soccer Gameday Probe", @"subtitle":@"Diagnóstico passivo do Soccer no X 12.37.", @"icon":@"flask", @"action":@"showXSoccerGamedayProbe"}];
    @try { [controller setValue:[m copy] forKey:@"sections"]; } @catch (__unused NSException *e) {}
}
static void Show(id self, SEL cmd) {
    (void)cmd; XSGProbeController *vc = [XSGProbeController new]; UINavigationController *n = [self navigationController];
    if (n) [n pushViewController:vc animated:YES]; else [self presentViewController:[[UINavigationController alloc] initWithRootViewController:vc] animated:YES completion:nil];
}
static void Setup(id self, SEL cmd) { if (gOrigSetupSections) ((void(*)(id,SEL))gOrigSetupSections)(self,cmd); Inject(self); }
static void Appear(id self, SEL cmd, BOOL animated) { if (gOrigViewWillAppear) ((void(*)(id,SEL,BOOL))gOrigViewWillAppear)(self,cmd,animated); Inject(self); }
static void InstallNFB(void) {
    Class c = NSClassFromString(@"ModernSettingsViewController");
    if (!c) { PLog(@"NFB ModernSettingsViewController not found"); return; }
    class_addMethod(c, NSSelectorFromString(@"showXSoccerGamedayProbe"), (IMP)Show, "v@:");
    Method m = class_getInstanceMethod(c, NSSelectorFromString(@"setupSections"));
    if (m) { gOrigSetupSections = method_getImplementation(m); class_replaceMethod(c, NSSelectorFromString(@"setupSections"), (IMP)Setup, method_getTypeEncoding(m)); }
    m = class_getInstanceMethod(c, @selector(viewWillAppear:));
    if (m) { gOrigViewWillAppear = method_getImplementation(m); class_replaceMethod(c, @selector(viewWillAppear:), (IMP)Appear, method_getTypeEncoding(m)); }
    PLog(@"NFB installed");
}

__attribute__((constructor)) static void Init(void) {
    @autoreleasepool {
        gReport = [NSMutableString string];
        PLog(@"BOOT version=1.1 mode=PASSIVE_FEATURE_SCAN app=%@ build=%@ iOS=%@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"], [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"], UIDevice.currentDevice.systemVersion);
        InstallNFB();
        DumpFlags();
    }
}
