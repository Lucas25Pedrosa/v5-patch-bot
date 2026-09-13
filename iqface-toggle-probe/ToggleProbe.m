#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// iQFaceToggleProbe 0.2.0
// Passive ABI/call-flow probe for iQFace 1.1 settings.
// It does not create settings, invoke factories, mutate sections, or change preferences.

static NSMutableString *IQFTPReport;
static NSString *IQFTPReportPath;
static BOOL IQFTPInstalled = NO;
static NSInteger IQFTPAttempts = 0;
static BOOL IQFTPAlertShown = NO;

static id (*IQFTPOrigInitSections)(id, SEL, id, id) = NULL;
static id (*IQFTPOrigInitBuilder)(id, SEL, id, id) = NULL;
static void (*IQFTPOrigRebuild)(id, SEL) = NULL;
static void (*IQFTPOrigViewDidAppear)(UIViewController *, SEL, BOOL) = NULL;

static void IQFTPFlush(void) {
    if (IQFTPReportPath.length && IQFTPReport) {
        [IQFTPReport writeToFile:IQFTPReportPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static void IQFTPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void IQFTPLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [IQFTPReport appendFormat:@"%@\n", line ?: @""];
    IQFTPFlush();
}

static BOOL IQFTPBoolGetter(id object, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:sel]) return NO;
    typedef BOOL (*Fn)(id, SEL);
    Fn fn = (Fn)(void *)objc_msgSend;
    return fn(object, sel);
}

static id IQFTPObjectGetter(id object, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:sel]) return nil;
    typedef id (*Fn)(id, SEL);
    Fn fn = (Fn)(void *)objc_msgSend;
    return fn(object, sel);
}

static void IQFTPLogControllerState(id controller, NSString *label) {
    id sections = IQFTPObjectGetter(controller, @"sections");
    id builder = IQFTPObjectGetter(controller, @"sectionsBuilder");
    NSUInteger count = [sections respondsToSelector:@selector(count)] ? (NSUInteger)[sections count] : 0;
    IQFTPLog(@"%@ class=%@ ptr=%p panelRoot=%@ sectionsClass=%@ sectionsCount=%lu builder=%@ builderClass=%@",
             label,
             NSStringFromClass([controller class]),
             controller,
             IQFTPBoolGetter(controller, @"panelRoot") ? @"YES" : @"NO",
             sections ? NSStringFromClass([sections class]) : @"nil",
             (unsigned long)count,
             builder ? @"YES" : @"NO",
             builder ? NSStringFromClass([builder class]) : @"nil");
}

static void IQFTPDumpCallStack(NSString *label) {
    NSArray<NSString *> *stack = NSThread.callStackSymbols;
    IQFTPLog(@"CALLSTACK %@ frames=%lu", label, (unsigned long)stack.count);
    NSUInteger limit = MIN((NSUInteger)10, stack.count);
    for (NSUInteger i = 0; i < limit; i++) {
        IQFTPLog(@"  #%lu %@", (unsigned long)i, stack[i]);
    }
}

static void IQFTPDumpMetaMethods(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        IQFTPLog(@"META %@ = MISSING", className);
        return;
    }
    Class meta = object_getClass(cls);
    unsigned int count = 0;
    Method *methods = class_copyMethodList(meta, &count);
    IQFTPLog(@"=== +[%@ ...] CLASS METHODS count=%u meta=%@ ===", className, count, NSStringFromClass(meta));
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        IQFTPLog(@"+ %@ | args=%u | types=%s | imp=%p",
                 NSStringFromSelector(sel),
                 method_getNumberOfArguments(methods[i]),
                 types ?: "(null)",
                 method_getImplementation(methods[i]));
    }
    free(methods);
}

static id IQFTPInitWithSections(id self, SEL _cmd, id title, id sections) {
    IQFTPLog(@"ENTER -[IQFSettingsViewController initWithTitle:sections:] self=%p title=%@ sectionsClass=%@ count=%lu",
             self,
             title ?: @"nil",
             sections ? NSStringFromClass([sections class]) : @"nil",
             [sections respondsToSelector:@selector(count)] ? (unsigned long)[sections count] : 0UL);
    IQFTPDumpCallStack(@"initWithTitle:sections:");
    id result = IQFTPOrigInitSections ? IQFTPOrigInitSections(self, _cmd, title, sections) : nil;
    IQFTPLogControllerState(result, @"EXIT initWithTitle:sections:");
    return result;
}

static id IQFTPInitWithBuilder(id self, SEL _cmd, id title, id builder) {
    IQFTPLog(@"ENTER -[IQFSettingsViewController initWithTitle:sectionsBuilder:] self=%p title=%@ builder=%@ builderClass=%@",
             self,
             title ?: @"nil",
             builder ? @"YES" : @"NO",
             builder ? NSStringFromClass([builder class]) : @"nil");
    IQFTPDumpCallStack(@"initWithTitle:sectionsBuilder:");
    id result = IQFTPOrigInitBuilder ? IQFTPOrigInitBuilder(self, _cmd, title, builder) : nil;
    IQFTPLogControllerState(result, @"EXIT initWithTitle:sectionsBuilder:");
    return result;
}

static void IQFTPRebuild(id self, SEL _cmd) {
    IQFTPLogControllerState(self, @"BEFORE iqfRebuildDynamicSectionsIfNeeded");
    IQFTPDumpCallStack(@"iqfRebuildDynamicSectionsIfNeeded");
    if (IQFTPOrigRebuild) IQFTPOrigRebuild(self, _cmd);
    IQFTPLogControllerState(self, @"AFTER iqfRebuildDynamicSectionsIfNeeded");
}

static void IQFTPPresentReport(UIViewController *controller) {
    if (IQFTPAlertShown || !controller || controller.presentedViewController) return;
    IQFTPAlertShown = YES;
    IQFTPFlush();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"iQFace ABI Probe"
                                                                   message:@"Fluxo dos settings capturado. Compartilhe iQFaceSettingsABI.txt."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copiar relatório" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = IQFTPReport;
    }]];
    __weak UIViewController *weakController = controller;
    [alert addAction:[UIAlertAction actionWithTitle:@"Compartilhar arquivo" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        UIViewController *presenter = weakController;
        if (!presenter || !IQFTPReportPath.length) return;
        UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:IQFTPReportPath]] applicationActivities:nil];
        UIPopoverPresentationController *popover = activity.popoverPresentationController;
        if (popover) {
            popover.sourceView = presenter.view;
            popover.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
        }
        [presenter presentViewController:activity animated:YES completion:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Fechar" style:UIAlertActionStyleCancel handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void IQFTPViewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (IQFTPOrigViewDidAppear) IQFTPOrigViewDidAppear(self, _cmd, animated);
    IQFTPLogControllerState(self, @"viewDidAppear");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        IQFTPPresentReport(self);
    });
}

static BOOL IQFTPInstallMethod(Class cls, SEL sel, IMP replacement, IMP *originalOut) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    IMP original = method_getImplementation(method);
    if (originalOut) *originalOut = original;
    method_setImplementation(method, replacement);
    IQFTPLog(@"HOOK %@ types=%s original=%p replacement=%p", NSStringFromSelector(sel), method_getTypeEncoding(method), original, replacement);
    return YES;
}

static void IQFTPTryInstall(void) {
    if (IQFTPInstalled) return;
    IQFTPAttempts++;
    Class vc = NSClassFromString(@"IQFSettingsViewController");
    Class setting = NSClassFromString(@"IQFSetting");
    if (!vc || !setting) {
        if (IQFTPAttempts < 120) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ IQFTPTryInstall(); });
        }
        return;
    }

    IQFTPDumpMetaMethods(@"IQFSetting");
    IQFTPDumpMetaMethods(@"IQFTweakSettings");

    BOOL a = IQFTPInstallMethod(vc, NSSelectorFromString(@"initWithTitle:sections:"), (IMP)IQFTPInitWithSections, (IMP *)&IQFTPOrigInitSections);
    BOOL b = IQFTPInstallMethod(vc, NSSelectorFromString(@"initWithTitle:sectionsBuilder:"), (IMP)IQFTPInitWithBuilder, (IMP *)&IQFTPOrigInitBuilder);
    BOOL c = IQFTPInstallMethod(vc, NSSelectorFromString(@"iqfRebuildDynamicSectionsIfNeeded"), (IMP)IQFTPRebuild, (IMP *)&IQFTPOrigRebuild);
    BOOL d = IQFTPInstallMethod(vc, @selector(viewDidAppear:), (IMP)IQFTPViewDidAppear, (IMP *)&IQFTPOrigViewDidAppear);
    IQFTPInstalled = a || b || c || d;
    IQFTPLog(@"INSTALL RESULT initSections=%@ initBuilder=%@ rebuild=%@ viewDidAppear=%@",
             a ? @"YES" : @"NO", b ? @"YES" : @"NO", c ? @"YES" : @"NO", d ? @"YES" : @"NO");
}

__attribute__((constructor))
static void IQFTPInitialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) return;

        IQFTPReport = [NSMutableString string];
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!documents.length) documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        NSString *directory = [documents stringByAppendingPathComponent:@"iQFaceABIProbe"];
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        IQFTPReportPath = [directory stringByAppendingPathComponent:@"iQFaceSettingsABI.txt"];
        IQFTPLog(@"iQFace ABI Probe 0.2.0");
        IQFTPLog(@"Facebook %@ (%@) | iOS %@",
                 [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?",
                 [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?",
                 UIDevice.currentDevice.systemVersion ?: @"?");
        dispatch_async(dispatch_get_main_queue(), ^{ IQFTPTryInstall(); });
    }
}
