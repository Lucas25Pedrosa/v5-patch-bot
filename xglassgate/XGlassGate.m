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
static void *gOriginalRedesignGetter = NULL;

static BOOL gGateHookInstalled = NO;
static BOOL gDataHooksInstalled = NO;
static BOOL gJSONHookInstalled = NO;
static BOOL gSwiftHooksInstalled = NO;

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

static NSData *XGGPatchDefaultsData(NSData *data, NSString *source) {
    if (!data || data.length == 0) return data;
    NSData *keyData = [XGGFeatureKey dataUsingEncoding:NSUTF8StringEncoding];
    NSData *falseData = [@"false" dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char truePadded[5] = {'t','r','u','e',' '};
    if ([data rangeOfData:keyData options:0 range:NSMakeRange(0, data.length)].location == NSNotFound) return data;

    NSMutableData *patched = [data mutableCopy];
    BOOL changed = NO;
    NSUInteger cursor = 0;
    while (cursor < patched.length) {
        NSRange currentKey = [patched rangeOfData:keyData options:0 range:NSMakeRange(cursor, patched.length - cursor)];
        if (currentKey.location == NSNotFound) break;
        NSUInteger start = NSMaxRange(currentKey);
        NSUInteger length = MIN((NSUInteger)256, patched.length - start);
        if (length >= falseData.length) {
            NSRange falseRange = [patched rangeOfData:falseData options:0 range:NSMakeRange(start, length)];
            if (falseRange.location != NSNotFound) {
                [patched replaceBytesInRange:falseRange withBytes:truePadded length:sizeof(truePadded)];
                changed = YES;
                NSLog(@"[XGlassGate] %@ forced TRUE in %@", XGGFeatureKey, source ?: @"data");
            }
        }
        cursor = NSMaxRange(currentKey);
    }
    return changed ? patched : data;
}

static id XGGDeepMutableCopy(id object) {
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:[(NSDictionary *)object count]];
        [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            result[key] = XGGDeepMutableCopy(value) ?: [NSNull null];
        }];
        return result;
    }
    if ([object isKindOfClass:[NSArray class]]) {
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:[(NSArray *)object count]];
        for (id value in (NSArray *)object) [result addObject:XGGDeepMutableCopy(value) ?: [NSNull null]];
        return result;
    }
    return object;
}

static NSUInteger XGGForceFeatureInObject(id object) {
    NSUInteger changes = 0;
    if ([object isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *dictionary = (NSMutableDictionary *)object;
        id feature = dictionary[XGGFeatureKey];
        if ([feature isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *featureDictionary = [feature mutableCopy];
            featureDictionary[@"value"] = @YES;
            dictionary[XGGFeatureKey] = featureDictionary;
            changes++;
        }
        for (id value in [dictionary allValues]) changes += XGGForceFeatureInObject(value);
    } else if ([object isKindOfClass:[NSMutableArray class]]) {
        for (id value in (NSMutableArray *)object) changes += XGGForceFeatureInObject(value);
    }
    return changes;
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
    NSData *patchedData = XGGPatchDefaultsData(data, @"NSJSONSerialization");
    id object = gOriginalJSONObjectWithData ? ((id (*)(id,SEL,NSData *,NSJSONReadingOptions,NSError **))gOriginalJSONObjectWithData)(self,_cmd,patchedData,options,error) : nil;
    if (!object) return object;
    NSData *keyData = [XGGFeatureKey dataUsingEncoding:NSUTF8StringEncoding];
    if ([patchedData rangeOfData:keyData options:0 range:NSMakeRange(0, patchedData.length)].location == NSNotFound) return object;
    id mutableObject = XGGDeepMutableCopy(object);
    NSUInteger changes = XGGForceFeatureInObject(mutableObject);
    if (changes > 0) return mutableObject;
    return object;
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

static BOOL XGGSwiftReturnYES(void) { return YES; }

static BOOL XGGTryInstallSwiftHooks(void) {
    if (gSwiftHooksInstalled) return YES;
    MSHookFunctionType hookFunction = (MSHookFunctionType)XGGFindSymbol("MSHookFunction");
    if (!hookFunction) return NO;

    void *appearanceGetter = XGGFindSymbol("$s11XAppearance10AppearanceC20isLiquidGlassEnabledSbvgZ");
    void *redesignGetter = XGGFindSymbol("$s14T1TwitterSwift27LiquidGlassRedesignFeaturesC02isF7EnabledSbvg");
    BOOL hookedAny = NO;

    if (appearanceGetter && !gOriginalAppearanceGetter) {
        hookFunction(appearanceGetter, (void *)&XGGSwiftReturnYES, &gOriginalAppearanceGetter);
        if (gOriginalAppearanceGetter) hookedAny = YES;
    }
    if (redesignGetter && !gOriginalRedesignGetter) {
        hookFunction(redesignGetter, (void *)&XGGSwiftReturnYES, &gOriginalRedesignGetter);
        if (gOriginalRedesignGetter) hookedAny = YES;
    }

    gSwiftHooksInstalled = (gOriginalAppearanceGetter != NULL && gOriginalRedesignGetter != NULL);
    return gSwiftHooksInstalled || hookedAny;
}

static void XGGInstallGateReplacement(id self, SEL _cmd, BOOL redesignEnabled) {
    if (gOriginalInstallGate) ((void (*)(id,SEL,BOOL))gOriginalInstallGate)(self,_cmd,YES);
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
    XGGTryInstallSwiftHooks();
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
        NSLog(@"[XGlassGate] 0.5.0 loaded");
        XGGInstallFeatureHooks();
        XGGRunRuntimeHooks();
        XGGScheduleRetry(0.0);
        XGGScheduleRetry(0.05);
        XGGScheduleRetry(0.20);
        XGGScheduleRetry(1.00);
        XGGScheduleRetry(3.00);
        XGGScheduleRetry(8.00);
    }
}
