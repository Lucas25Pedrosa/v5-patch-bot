#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <string.h>

static NSString * const XGGFeatureKey = @"ios_liquid_glass_redesign_enabled";
typedef void (*MSHookFunctionType)(void *symbol, void *replacement, void **original);

static IMP gOriginalInstallGate = NULL;
static IMP gOriginalDataWithFile = NULL;
static IMP gOriginalDataWithURL = NULL;
static IMP gOriginalJSONObjectWithData = NULL;
static void *gOriginalAppearanceGetter = NULL;

static BOOL gGateHookInstalled = NO;
static BOOL gDataHooksInstalled = NO;
static BOOL gJSONHookInstalled = NO;
static BOOL gAppearanceHookInstalled = NO;

static void *XGGFindSymbol(const char *name) {
    if (!name) return NULL;
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol) return symbol;

    char underscored[256] = {0};
    size_t length = strlen(name);
    if (length + 2 < sizeof(underscored)) {
        underscored[0] = '_';
        strlcpy(underscored + 1, name, sizeof(underscored) - 1);
        symbol = dlsym(RTLD_DEFAULT, underscored);
    }
    return symbol;
}

#pragma mark - Embedded feature flag

static NSData *XGGPatchDefaultsData(NSData *data, NSString *source) {
    if (!data || data.length == 0) return data;

    NSData *keyData = [XGGFeatureKey dataUsingEncoding:NSUTF8StringEncoding];
    NSData *falseData = [@"false" dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char truePadded[5] = {'t','r','u','e',' '};

    if ([data rangeOfData:keyData options:0 range:NSMakeRange(0, data.length)].location == NSNotFound) {
        return data;
    }

    NSMutableData *patched = [data mutableCopy];
    NSUInteger cursor = 0;
    BOOL changed = NO;

    while (cursor < patched.length) {
        NSRange keyRange = [patched rangeOfData:keyData options:0 range:NSMakeRange(cursor, patched.length - cursor)];
        if (keyRange.location == NSNotFound) break;

        NSUInteger start = NSMaxRange(keyRange);
        NSUInteger length = MIN((NSUInteger)256, patched.length - start);
        if (length >= falseData.length) {
            NSRange falseRange = [patched rangeOfData:falseData options:0 range:NSMakeRange(start, length)];
            if (falseRange.location != NSNotFound) {
                [patched replaceBytesInRange:falseRange withBytes:truePadded length:sizeof(truePadded)];
                changed = YES;
                NSLog(@"[XGlassGate] %@ forced TRUE in %@", XGGFeatureKey, source ?: @"data");
            }
        }
        cursor = NSMaxRange(keyRange);
    }

    return changed ? patched : data;
}

static NSData *XGGDataWithContentsOfFileReplacement(id self, SEL _cmd, NSString *path) {
    NSData *data = gOriginalDataWithFile ? ((NSData *(*)(id,SEL,NSString *))gOriginalDataWithFile)(self,_cmd,path) : nil;
    if ([path.lastPathComponent hasPrefix:@"fs_embedded_defaults_"] && [path.pathExtension.lowercaseString isEqualToString:@"json"]) {
        return XGGPatchDefaultsData(data, path.lastPathComponent);
    }
    return data;
}

static NSData *XGGDataWithContentsOfURLReplacement(id self, SEL _cmd, NSURL *url) {
    NSData *data = gOriginalDataWithURL ? ((NSData *(*)(id,SEL,NSURL *))gOriginalDataWithURL)(self,_cmd,url) : nil;
    NSString *path = url.path;
    if ([path.lastPathComponent hasPrefix:@"fs_embedded_defaults_"] && [path.pathExtension.lowercaseString isEqualToString:@"json"]) {
        return XGGPatchDefaultsData(data, path.lastPathComponent);
    }
    return data;
}

static id XGGJSONObjectWithDataReplacement(id self, SEL _cmd, NSData *data, NSJSONReadingOptions options, NSError **error) {
    NSData *patched = XGGPatchDefaultsData(data, @"NSJSONSerialization");
    return gOriginalJSONObjectWithData ?
        ((id (*)(id,SEL,NSData *,NSJSONReadingOptions,NSError **))gOriginalJSONObjectWithData)(self,_cmd,patched,options,error) : nil;
}

static void XGGInstallFeatureHooks(void) {
    if (!gDataHooksInstalled) {
        Method fileMethod = class_getClassMethod([NSData class], @selector(dataWithContentsOfFile:));
        Method urlMethod = class_getClassMethod([NSData class], @selector(dataWithContentsOfURL:));
        if (fileMethod) gOriginalDataWithFile = method_setImplementation(fileMethod, (IMP)XGGDataWithContentsOfFileReplacement);
        if (urlMethod) gOriginalDataWithURL = method_setImplementation(urlMethod, (IMP)XGGDataWithContentsOfURLReplacement);
        gDataHooksInstalled = (gOriginalDataWithFile != NULL || gOriginalDataWithURL != NULL);
    }

    if (!gJSONHookInstalled) {
        Method jsonMethod = class_getClassMethod([NSJSONSerialization class], @selector(JSONObjectWithData:options:error:));
        if (jsonMethod) {
            gOriginalJSONObjectWithData = method_setImplementation(jsonMethod, (IMP)XGGJSONObjectWithDataReplacement);
            gJSONHookInstalled = (gOriginalJSONObjectWithData != NULL);
        }
    }
}

#pragma mark - XAppearance Swift getter only

// ABI-minimal ARM64 replacement: Swift.Bool is returned in w0.
__attribute__((naked))
static void XGGSwiftReturnYES(void) {
    __asm__("mov w0, #1\n"
            "ret\n");
}

static BOOL XGGTryInstallAppearanceHook(void) {
    if (gAppearanceHookInstalled) return YES;

    MSHookFunctionType hookFunction = (MSHookFunctionType)XGGFindSymbol("MSHookFunction");
    if (!hookFunction) return NO;

    void *getter = XGGFindSymbol("$s11XAppearance10AppearanceC20isLiquidGlassEnabledSbvgZ");
    if (!getter) return NO;

    hookFunction(getter, (void *)&XGGSwiftReturnYES, &gOriginalAppearanceGetter);
    gAppearanceHookInstalled = (gOriginalAppearanceGetter != NULL);
    NSLog(@"[XGlassGate] XAppearance Swift hook %@", gAppearanceHookInstalled ? @"installed" : @"FAILED");
    return gAppearanceHookInstalled;
}

#pragma mark - Existing native gate

static void XGGInstallGateReplacement(id self, SEL _cmd, BOOL redesignEnabled) {
    if (gOriginalInstallGate) {
        ((void (*)(id,SEL,BOOL))gOriginalInstallGate)(self,_cmd,YES);
    }
}

static BOOL XGGTryInstallGateHook(void) {
    if (gGateHookInstalled) return YES;

    Class installerClass = objc_getClass("T1LiquidGlassGateInstaller");
    if (!installerClass) return NO;

    SEL selector = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    Method method = class_getClassMethod(installerClass, selector);
    if (!method) method = class_getInstanceMethod(installerClass, selector);
    if (!method) return NO;

    gOriginalInstallGate = method_setImplementation(method, (IMP)XGGInstallGateReplacement);
    gGateHookInstalled = (gOriginalInstallGate != NULL);
    return gGateHookInstalled;
}

static void XGGRunRuntimeHooks(void) {
    XGGTryInstallAppearanceHook();
    XGGTryInstallGateHook();
}

static void XGGScheduleRetry(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XGGRunRuntimeHooks();
    });
}

__attribute__((constructor))
static void XGlassGateInit(void) {
    @autoreleasepool {
        NSLog(@"[XGlassGate] 0.5.1 loaded");
        XGGInstallFeatureHooks();

        // Delay the direct Swift hook slightly so the framework and hook engine
        // finish loading before we patch the function body.
        XGGScheduleRetry(0.20);
        XGGScheduleRetry(1.00);
        XGGScheduleRetry(3.00);
    }
}
