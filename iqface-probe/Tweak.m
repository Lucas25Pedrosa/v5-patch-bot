#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString *reportPath;
static NSString *stringsPath;
static NSMutableSet *seenStrings;
static NSMutableSet *seenScreens;
static dispatch_source_t timer;

static void appendText(NSString *path, NSString *text) {
    if (!path.length || !text.length) return;
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) return;
    [h seekToEndOfFile];
    [h writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

static void logLine(NSString *line) {
    appendText(reportPath, [line stringByAppendingString:@"\n"]);
}

static NSString *cleanText(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    NSString *v = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    v = [v stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    return [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void recordString(NSString *text, NSString *source, NSString *screen) {
    NSString *v = cleanText(text);
    if (!v.length) return;
    NSString *key = [NSString stringWithFormat:@"%@|%@", screen ?: @"?", v];
    if ([seenStrings containsObject:key]) return;
    [seenStrings addObject:key];
    appendText(stringsPath, [NSString stringWithFormat:@"%@ | %@ | %@\n", screen ?: @"?", source ?: @"?", v]);
}

static void prepareFiles(void) {
    seenStrings = [NSMutableSet set];
    seenScreens = [NSMutableSet set];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"iQFaceProbe"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    reportPath = [dir stringByAppendingPathComponent:@"iQFaceProbe.txt"];
    stringsPath = [dir stringByAppendingPathComponent:@"iQFaceStrings.txt"];
    [[NSFileManager defaultManager] createFileAtPath:reportPath contents:nil attributes:nil];
    [[NSFileManager defaultManager] createFileAtPath:stringsPath contents:nil attributes:nil];
}

static void checkClass(NSString *name) {
    Class c = NSClassFromString(name);
    logLine([NSString stringWithFormat:@"CLASS %@ = %@", name, c ? @"FOUND" : @"MISSING"]);
}

static void checkClassSelector(NSString *className, NSString *selectorName) {
    Class c = NSClassFromString(className);
    SEL s = NSSelectorFromString(selectorName);
    BOOL ok = c && [c respondsToSelector:s];
    logLine([NSString stringWithFormat:@"+[%@ %@] = %@", className, selectorName, ok ? @"FOUND" : @"MISSING"]);
}

static void writeCompatibilityReport(void) {
    NSDictionary *info = [NSBundle mainBundle].infoDictionary ?: @{};
    logLine(@"=== iQFaceProbe 1.0 ===");
    logLine([NSString stringWithFormat:@"Facebook %@ (%@)", info[@"CFBundleShortVersionString"] ?: @"?", info[@"CFBundleVersion"] ?: @"?"]);
    logLine([NSString stringWithFormat:@"iOS %@", [UIDevice currentDevice].systemVersion ?: @"?"]);
    logLine(@"");
    logLine(@"=== CLASSES ===");
    for (NSString *name in @[@"IQFSettingsViewController", @"IQFSetting", @"IQFTweakSettings", @"IQFPrefs", @"IQFSymbol", @"IQFAssets", @"IQFRow", @"IQFSection", @"FBNavigationBar"]) checkClass(name);
    logLine(@"");
    logLine(@"=== IQFSETTING FACTORIES ===");
    for (NSString *sel in @[@"buttonCellWithTitle:subtitle:icon:action:", @"switchCellWithTitle:subtitle:defaultsKey:defaultOn:", @"optionsCellWithTitle:subtitle:icon:defaultsKey:defaultValue:options:", @"navigationCellWithTitle:subtitle:icon:viewController:", @"navigationCellWithTitle:subtitle:icon:navSections:", @"staticCellWithTitle:subtitle:icon:"]) checkClassSelector(@"IQFSetting", sel);
    logLine(@"");
    logLine(@"=== OLED FACEBOOK CLASSES ===");
    for (NSString *name in @[@"FBTopBarAndContentView", @"FBTabBarAndContentView", @"FBMovableNavigationBarView", @"FBNewsFeedView", @"FBNewsFeedCollectionView", @"FBTabBar", @"FBPassthroughView", @"FBLineComponentInternalView", @"_FBMaskedRoundedCornerView", @"MRCImageComponentView", @"MRCAnimatedImageView"]) checkClass(name);
    logLine(@"");
    logLine(@"Open every iQFace settings page. Visible cells and strings will be appended below.");
}

static void scanView(UIView *view, NSUInteger depth, NSMutableString *tree, NSString *screen) {
    if (!view || depth > 18) return;
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    NSString *className = NSStringFromClass(view.class);
    [tree appendFormat:@"%@%@", indent, className];
    NSMutableArray *texts = [NSMutableArray array];
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)view).text; if (t.length) [texts addObject:t];
    }
    if ([view isKindOfClass:[UIButton class]]) {
        NSString *t = ((UIButton *)view).currentTitle; if (t.length) [texts addObject:t];
    }
    if ([view isKindOfClass:[UITextField class]]) {
        UITextField *v = (UITextField *)view; if (v.text.length) [texts addObject:v.text]; if (v.placeholder.length) [texts addObject:v.placeholder];
    }
    if ([view isKindOfClass:[UITextView class]]) {
        NSString *t = ((UITextView *)view).text; if (t.length) [texts addObject:t];
    }
    if ([view isKindOfClass:[UITableViewCell class]]) {
        UITableViewCell *c = (UITableViewCell *)view; if (c.textLabel.text.length) [texts addObject:c.textLabel.text]; if (c.detailTextLabel.text.length) [texts addObject:c.detailTextLabel.text];
    }
    if (texts.count) {
        NSMutableArray *clean = [NSMutableArray array];
        for (NSString *t in texts) {
            NSString *v = cleanText(t);
            if (!v.length) continue;
            [clean addObject:v];
            recordString(v, className, screen);
        }
        if (clean.count) [tree appendFormat:@" text=%@", [clean componentsJoinedByString:@" | "]];
    }
    [tree appendString:@"\n"];
    for (UIView *sub in view.subviews) scanView(sub, depth + 1, tree, screen);
}

static void collectControllers(UIViewController *vc, NSMutableArray *out) {
    if (!vc || [out containsObject:vc]) return;
    [out addObject:vc];
    if (vc.presentedViewController) collectControllers(vc.presentedViewController, out);
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *child in ((UINavigationController *)vc).viewControllers) collectControllers(child, out);
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in ((UITabBarController *)vc).viewControllers) collectControllers(child, out);
    }
    for (UIViewController *child in vc.childViewControllers) collectControllers(child, out);
}

static BOOL relevantController(UIViewController *vc) {
    NSString *name = NSStringFromClass(vc.class);
    if ([name hasPrefix:@"IQF"]) return YES;
    NSString *title = vc.title ?: vc.navigationItem.title;
    return title && [title rangeOfString:@"iQFace" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static void captureSettings(void) {
    NSMutableArray *controllers = [NSMutableArray array];
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.rootViewController) collectControllers(w.rootViewController, controllers);
    }
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.rootViewController) collectControllers(w.rootViewController, controllers);
        }
    }
    for (UIViewController *vc in controllers) {
        if (!relevantController(vc) || !vc.isViewLoaded || !vc.view.window) continue;
        NSString *className = NSStringFromClass(vc.class);
        NSString *title = cleanText(vc.title ?: vc.navigationItem.title ?: @"");
        NSString *screen = title.length ? [NSString stringWithFormat:@"%@ [%@]", className, title] : className;
        NSMutableString *tree = [NSMutableString string];
        scanView(vc.view, 0, tree, screen);
        NSString *sig = [NSString stringWithFormat:@"%@:%lu", screen, (unsigned long)tree.hash];
        if ([seenScreens containsObject:sig]) continue;
        [seenScreens addObject:sig];
        logLine(@"");
        logLine(@"=== SETTINGS SNAPSHOT ===");
        logLine([NSString stringWithFormat:@"Controller: %@", className]);
        logLine([NSString stringWithFormat:@"Title: %@", title.length ? title : @"(none)"]);
        logLine(tree);
        logLine(@"=== END SNAPSHOT ===");
    }
}

__attribute__((constructor)) static void IQFProbeInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            prepareFiles();
            writeCompatibilityReport();
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 5);
            dispatch_source_set_event_handler(timer, ^{ captureSettings(); });
            dispatch_resume(timer);
        });
    }
}
