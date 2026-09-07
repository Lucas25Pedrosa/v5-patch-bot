#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// iQFaceToggleProbe 0.1.0
// Read-only runtime probe used to identify the native iQFace toggle-row builder.
// Does not add rows, change preferences, or modify iQFace behavior.

static void (*IQFTPOriginalViewDidAppear)(UIViewController *, SEL, BOOL) = NULL;
static BOOL IQFTPHookInstalled = NO;
static NSInteger IQFTPHookAttempts = 0;
static BOOL IQFTPReported = NO;
static NSString *IQFTPReportPath = nil;

static BOOL IQFTPContainsAny(NSString *value, NSArray<NSString *> *needles) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *lower = value.lowercaseString;
    for (NSString *needle in needles) {
        if ([lower containsString:needle]) return YES;
    }
    return NO;
}

static void IQFTPAppend(NSMutableString *report, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [report appendString:line ?: @""];
    [report appendString:@"\n"];
}

static NSString *IQFTPStringForObject(id object) {
    if (object == nil) return @"(nil)";
    @try {
        NSString *description = [object description];
        return description ?: @"(no description)";
    } @catch (__unused NSException *exception) {
        return @"(description threw)";
    }
}

static void IQFTPDumpClassMethods(Class cls, NSMutableString *report, BOOL candidatesOnly) {
    if (cls == Nil) return;

    NSArray<NSString *> *keywords = @[@"switch", @"toggle", @"bool", @"row", @"value", @"setting", @"feature", @"section", @"cell"];
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    IQFTPAppend(report, @"METHODS class=%@ count=%u", NSStringFromClass(cls), count);

    for (unsigned int i = 0; i < count; i++) {
        SEL selector = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(selector);
        if (candidatesOnly && !IQFTPContainsAny(name, keywords)) continue;
        const char *types = method_getTypeEncoding(methods[i]);
        unsigned int args = method_getNumberOfArguments(methods[i]);
        IQFTPAppend(report, @"  - %@ | args=%u | types=%s", name, args, types ?: "(null)");
    }
    free(methods);
}

static void IQFTPDumpPropertiesAndIvars(Class cls, NSMutableString *report) {
    if (cls == Nil) return;

    unsigned int propertyCount = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &propertyCount);
    IQFTPAppend(report, @"PROPERTIES class=%@ count=%u", NSStringFromClass(cls), propertyCount);
    for (unsigned int i = 0; i < propertyCount; i++) {
        const char *name = property_getName(properties[i]);
        const char *attrs = property_getAttributes(properties[i]);
        IQFTPAppend(report, @"  - %s | %s", name ?: "(null)", attrs ?: "(null)");
    }
    free(properties);

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    IQFTPAppend(report, @"IVARS class=%@ count=%u", NSStringFromClass(cls), ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *name = ivar_getName(ivars[i]);
        const char *type = ivar_getTypeEncoding(ivars[i]);
        IQFTPAppend(report, @"  - %s | %s", name ?: "(null)", type ?: "(null)");
    }
    free(ivars);
}

static void IQFTPDumpClassHierarchy(Class cls, NSMutableString *report) {
    IQFTPAppend(report, @"=== CLASS HIERARCHY ===");
    for (Class current = cls; current != Nil; current = class_getSuperclass(current)) {
        IQFTPAppend(report, @"CLASS %@", NSStringFromClass(current));
        IQFTPDumpClassMethods(current, report, YES);
        IQFTPDumpPropertiesAndIvars(current, report);
        if (current == UIViewController.class) break;
    }
}

static NSString *IQFTPSafeKVC(id object, NSString *key) {
    if (object == nil || key.length == 0) return nil;
    @try {
        id value = [object valueForKey:key];
        if ([value isKindOfClass:NSString.class]) return value;
        if (value != nil) return IQFTPStringForObject(value);
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static NSArray *IQFTPSafeArrayKVC(id object, NSString *key) {
    if (object == nil || key.length == 0) return nil;
    @try {
        id value = [object valueForKey:key];
        return [value isKindOfClass:NSArray.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void IQFTPDumpLiveSections(UIViewController *controller, NSMutableString *report) {
    IQFTPAppend(report, @"=== LIVE SETTINGS MODEL ===");
    NSArray *sections = IQFTPSafeArrayKVC(controller, @"sections");
    IQFTPAppend(report, @"sections=%lu", (unsigned long)sections.count);

    NSMutableSet<NSString *> *dumpedRowClasses = [NSMutableSet set];
    NSInteger sectionIndex = 0;
    for (id section in sections) {
        NSString *header = IQFTPSafeKVC(section, @"header") ?: @"";
        NSArray *rows = IQFTPSafeArrayKVC(section, @"rows");
        IQFTPAppend(report, @"SECTION[%ld] class=%@ header=%@ rows=%lu",
                    (long)sectionIndex,
                    NSStringFromClass([section class]),
                    header,
                    (unsigned long)rows.count);

        NSInteger rowIndex = 0;
        for (id row in rows) {
            NSString *title = IQFTPSafeKVC(row, @"title") ?: @"";
            NSString *detail = IQFTPSafeKVC(row, @"detail") ?: @"";
            NSString *rowClassName = NSStringFromClass([row class]);
            IQFTPAppend(report, @"  ROW[%ld] class=%@ title=%@ detail=%@",
                        (long)rowIndex,
                        rowClassName,
                        title,
                        detail);

            for (NSString *key in @[@"enabled", @"isEnabled", @"on", @"isOn", @"value", @"toggle", @"switch", @"accessoryType", @"kind", @"type"]) {
                NSString *value = IQFTPSafeKVC(row, key);
                if (value.length) IQFTPAppend(report, @"    KVC %@=%@", key, value);
            }

            if (![dumpedRowClasses containsObject:rowClassName]) {
                [dumpedRowClasses addObject:rowClassName];
                IQFTPDumpClassMethods([row class], report, NO);
                IQFTPDumpPropertiesAndIvars([row class], report);
            }
            rowIndex++;
        }
        sectionIndex++;
    }
}

static void IQFTPDumpIQFClasses(NSMutableString *report) {
    IQFTPAppend(report, @"=== LOADED IQF CLASSES ===");
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    int actual = objc_getClassList(classes, count);
    NSArray<NSString *> *keywords = @[@"row", @"setting", @"switch", @"toggle", @"section", @"cell"];

    for (int i = 0; i < actual; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (![name hasPrefix:@"IQF"]) continue;
        if (!IQFTPContainsAny(name, keywords)) continue;
        IQFTPAppend(report, @"IQF CLASS %@", name);
        IQFTPDumpClassMethods(classes[i], report, YES);
        IQFTPDumpPropertiesAndIvars(classes[i], report);
    }
    free(classes);
}

static NSString *IQFTPBuildReport(UIViewController *controller) {
    NSMutableString *report = [NSMutableString string];
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
    IQFTPAppend(report, @"iQFace Toggle Probe 0.1.0");
    IQFTPAppend(report, @"Facebook %@ (%@)", version, build);
    IQFTPAppend(report, @"Controller=%@", NSStringFromClass(controller.class));
    IQFTPAppend(report, @"iOS=%@", UIDevice.currentDevice.systemVersion);
    IQFTPAppend(report, @"");

    IQFTPDumpClassHierarchy(controller.class, report);
    IQFTPAppend(report, @"");
    IQFTPDumpLiveSections(controller, report);
    IQFTPAppend(report, @"");
    IQFTPDumpIQFClasses(report);

    return report;
}

static NSString *IQFTPSaveReport(NSString *contents) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents.length == 0) documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *directory = [documents stringByAppendingPathComponent:@"iQFaceToggleProbe"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    NSString *path = [directory stringByAppendingPathComponent:@"iQFaceToggleProbe.txt"];
    [contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return path;
}

static void IQFTPPresentResult(UIViewController *controller, NSString *report) {
    if (controller == nil || controller.presentedViewController != nil) return;
    IQFTPReportPath = IQFTPSaveReport(report);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"iQFace Toggle Probe"
                                                                   message:@"A estrutura nativa dos toggles foi analisada. Compartilhe o relatório para identificarmos o construtor correto."
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Copiar relatório"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = report;
    }]];

    __weak UIViewController *weakController = controller;
    [alert addAction:[UIAlertAction actionWithTitle:@"Compartilhar arquivo"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        UIViewController *presenter = weakController;
        if (presenter == nil || IQFTPReportPath.length == 0) return;
        UIActivityViewController *activity = [[UIActivityViewController alloc]
            initWithActivityItems:@[[NSURL fileURLWithPath:IQFTPReportPath]]
            applicationActivities:nil];
        UIPopoverPresentationController *popover = activity.popoverPresentationController;
        if (popover != nil) {
            popover.sourceView = presenter.view;
            popover.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
        }
        [presenter presentViewController:activity animated:YES completion:nil];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Fechar" style:UIAlertActionStyleCancel handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static BOOL IQFTPClassImplementsSelector(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

static void IQFTPViewDidAppear(UIViewController *self, SEL command, BOOL animated) {
    if (IQFTPOriginalViewDidAppear != NULL) {
        IQFTPOriginalViewDidAppear(self, command, animated);
    }

    if (IQFTPReported) return;
    IQFTPReported = YES;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *report = IQFTPBuildReport(self);
        IQFTPPresentResult(self, report);
    });
}

static void IQFTPTryInstallHook(void) {
    if (IQFTPHookInstalled) return;
    IQFTPHookAttempts++;

    Class target = NSClassFromString(@"IQFSettingsViewController");
    if (target != Nil) {
        SEL selector = @selector(viewDidAppear:);
        Method method = class_getInstanceMethod(target, selector);
        if (method != NULL) {
            IQFTPOriginalViewDidAppear = (void (*)(UIViewController *, SEL, BOOL))method_getImplementation(method);
            const char *types = method_getTypeEncoding(method);
            if (IQFTPClassImplementsSelector(target, selector)) {
                method_setImplementation(method, (IMP)&IQFTPViewDidAppear);
                IQFTPHookInstalled = YES;
            } else if (class_addMethod(target, selector, (IMP)&IQFTPViewDidAppear, types)) {
                IQFTPHookInstalled = YES;
            }
        }
    }

    if (!IQFTPHookInstalled && IQFTPHookAttempts < 120) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            IQFTPTryInstallHook();
        });
    }
}

__attribute__((constructor))
static void IQFTPInitialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            IQFTPTryInstallHook();
        });
    }
}
