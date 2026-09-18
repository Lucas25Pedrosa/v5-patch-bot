#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *XLProbePath(void) {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.firstObject ?: NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:@"XLoginProbe.txt"];
}

static void XLProbeWrite(NSString *line) {
    if (line.length == 0) return;
    NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                     dateStyle:NSDateFormatterNoStyle
                                                     timeStyle:NSDateFormatterMediumStyle];
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", stamp, line];
    NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];

    NSString *path = XLProbePath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (__unused NSException *e) {}
    [handle closeFile];
}

static BOOL XLClassOwnsSelector(Class cls, SEL sel, BOOL classMethod) {
    Class target = classMethod ? object_getClass(cls) : cls;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count);
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

static void XLDescribeMethod(Class cls, NSString *selectorName, BOOL classMethod) {
    SEL sel = NSSelectorFromString(selectorName);
    if (!XLClassOwnsSelector(cls, sel, classMethod)) return;

    Method method = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    const char *types = method ? method_getTypeEncoding(method) : NULL;
    XLProbeWrite([NSString stringWithFormat:@"%@ %@[%@ %@] types=%s",
                  classMethod ? @"+" : @"-",
                  NSStringFromClass(cls),
                  NSStringFromClass(cls),
                  selectorName,
                  types ?: "?"]);
}

static void XLScanKnownClasses(void) {
    NSArray<NSString *> *classes = @[
        @"TFNTwitterAccount", @"TFSTwitterAccount", @"TFNAccount",
        @"TFNTwitterAccountStore", @"TFSTwitterAccountStore", @"TFNAccountStore",
        @"T1AccountController", @"TFSAccountService", @"TEKTwitterAccountSource",
        @"TFSAccountIndex", @"T1AccountsViewController", @"TFSKeychain",
        @"TFSKeychainDefaultTwitterConfiguration"
    ];

    NSArray<NSString *> *selectors = @[
        @"activeAccount", @"activeAccountID", @"accounts", @"loadAccounts",
        @"addAccount:", @"removeAccount:", @"setActiveAccount:", @"selectAccount:",
        @"saveAccountStore", @"accountService", @"sharedTwitter",
        @"sharedAccountStore", @"sharedAccountsManager",
        @"updateUserInfoAndCredentialsWithToken:secret:username:",
        @"private_startLoginFlowWithSender:",
        @"makeOnboardingViewControllerWithCompletion:"
    ];

    for (NSString *className in classes) {
        Class cls = NSClassFromString(className);
        XLProbeWrite([NSString stringWithFormat:@"class %@ = %@", className, cls ? @"present" : @"missing"]);
        if (!cls) continue;

        for (NSString *selectorName in selectors) {
            XLDescribeMethod(cls, selectorName, NO);
            XLDescribeMethod(cls, selectorName, YES);
        }
    }
}

static void XLScanLoginSelectors(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);

    NSArray<NSString *> *targets = @[
        @"private_startLoginFlowWithSender:",
        @"makeOnboardingViewControllerWithCompletion:",
        @"completeLoginWithUsername:errorDetails:"
    ];

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!cls) continue;

        const char *image = class_getImageName(cls);
        if (!image || strstr(image, "/Twitter.app/") == NULL) continue;

        for (NSString *selectorName in targets) {
            SEL sel = NSSelectorFromString(selectorName);
            if (!XLClassOwnsSelector(cls, sel, NO)) continue;

            Method method = class_getInstanceMethod(cls, sel);
            const char *types = method ? method_getTypeEncoding(method) : NULL;
            XLProbeWrite([NSString stringWithFormat:@"login-selector class=%@ selector=%@ types=%s image=%s",
                          NSStringFromClass(cls), selectorName, types ?: "?", image]);
        }
    }

    free(classes);
}

__attribute__((constructor))
static void XLoginProbeInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *path = XLProbePath();
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

            NSDictionary *info = NSBundle.mainBundle.infoDictionary;
            XLProbeWrite(@"XLoginProbe 1.0 started");
            XLProbeWrite([NSString stringWithFormat:@"bundle=%@", NSBundle.mainBundle.bundleIdentifier ?: @"?"]);
            XLProbeWrite([NSString stringWithFormat:@"version=%@ build=%@",
                          info[@"CFBundleShortVersionString"] ?: @"?",
                          info[@"CFBundleVersion"] ?: @"?"]);
            XLProbeWrite([NSString stringWithFormat:@"ios=%@", UIDevice.currentDevice.systemVersion ?: @"?"]);

            XLScanKnownClasses();
            XLScanLoginSelectors();

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                XLProbeWrite(@"second-pass");
                XLScanKnownClasses();
                XLScanLoginSelectors();
            });
        });
    }
}
