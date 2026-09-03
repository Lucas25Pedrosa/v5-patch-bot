#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

static NSString * const XGGFeatureKey = @"ios_liquid_glass_redesign_enabled";

static IMP gOriginalInstallGate = NULL;
static IMP gOriginalDataWithFile = NULL;
static IMP gOriginalDataWithURL = NULL;
static IMP gOriginalJSONObjectWithData = NULL;

static BOOL gGateHookInstalled = NO;
static BOOL gDataHooksInstalled = NO;
static BOOL gJSONHookInstalled = NO;
static BOOL gRedesignFeaturesHookInstalled = NO;
static BOOL gAppearanceHookInstalled = NO;

#pragma mark - Embedded feature switch

static NSData *XGGPatchDefaultsData(NSData *data, NSString *source) {
    if (!data || data.length == 0) return data;

    NSData *keyData = [XGGFeatureKey dataUsingEncoding:NSUTF8StringEncoding];
    NSData *falseData = [@"false" dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char truePadded[5] = {'t','r','u','e',' '};

    if ([data rangeOfData:keyData options:0 range:NSMakeRange(0, data.length)].location == NSNotFound) {
        return data;
    }

    NSMutableData *patched = [data mutableCopy];
    BOOL changed = NO;
    NSUInteger cursor = 0;

    while (cursor < patched.length) {
        NSRange currentKey = [patched rangeOfData:keyData
                                         options:0
                                           range:NSMakeRange(cursor, patched.length - cursor)];
        if (currentKey.location == NSNotFound) break;

        NSUInteger start = NSMaxRange(currentKey);
        NSUInteger length = MIN((NSUInteger)256, patched.length - start);
        if (length >= falseData.length) {
            NSRange falseRange = [patched rangeOfData:falseData
                                             options:0
                                               range:NSMakeRange(start, length)];
            if (falseRange.location != NSNotFound) {
                [patched replaceBytesInRange:falseRange
                                   withBytes:truePadded
                                      length:sizeof(truePadded)];
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
        for (id value in (NSArray *)object) {
            [result addObject:XGGDeepMutableCopy(value) ?: [NSNull null]];
        }
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
        for (id value in [dictionary allValues]) {
            changes += XGGForceFeatureInObject(value);
        }
    } else if ([object isKindOfClass:[NSMutableArray class]]) {
        for (id value in (NSMutableArray *)object) {
            changes += XGGForceFeatureInObject(value);
        }
    }
    return changes;
}

static NSData *XGGDataWithContentsOfFileReplacement(id self, SEL _cmd, NSString *path) {
    NSData *data = gOriginalDataWithFile ? ((NSData *(*)(id,SEL,NSString *))gOriginalDataWithFile)(self,_cmd,path) : nil;
    if ([path.lastPathComponent hasPrefix:@"fs_embedded_defaults_"] &&
        [path.pathExtension.lowercaseString isEqualToString:@"json"]) {
        return XGGPatchDefaultsData(data, path.lastPathComponent);
    }
    return data;
}

static NSData *XGGDataWithContentsOfURLReplacement(id self, SEL _cmd, NSURL *url) {
    NSData *data = gOriginalDataWithURL ? ((NSData *(*)(id,SEL,NSURL *))gOriginalDataWithURL)(self,_cmd,url) : nil;
    NSString *path = url.path;
    if ([path.lastPathComponent hasPrefix:@"fs_embedded_defaults_"] &&
        [path.pathExtension.lowercaseString isEqualToString:@"json"]) {
        return XGGPatchDefaultsData(data, path.lastPathComponent);
    }
    return data;
}

static id XGGJSONObjectWithDataReplacement(id self, SEL _cmd, NSData *data, NSJSONReadingOptions options, NSError **error) {
    NSData *patchedData = XGGPatchDefaultsData(data, @"NSJSONSerialization");
    id object = gOriginalJSONObjectWithData ?
        ((id (*)(id,SEL,NSData *,NSJSONReadingOptions,NSError **))gOriginalJSONObjectWithData)(self,_cmd,patchedData,options,error) : nil;
    if (!object) return object;

    NSData *keyData = [XGGFeatureKey dataUsingEncoding:NSUTF8StringEncoding];
    if ([patchedData rangeOfData:keyData options:0 range:NSMakeRange(0, patchedData.length)].location == NSNotFound) {
        return object;
    }

    id mutableObject = XGGDeepMutableCopy(object);
    NSUInteger changes = XGGForceFeatureInObject(mutableObject);
    if (changes > 0) {
        NSLog(@"[XGlassGate] JSON %@ forced TRUE (%lu)", XGGFeatureKey, (unsigned long)changes);
        return mutableObject;
    }
    return object;
}

static void XGGInstallFeatureHooks(void) {
    if (!gDataHooksInstalled) {
        Class dataClass = [NSData class];
        Method fileMethod = class_getClassMethod(dataClass, @selector(dataWithContentsOfFile:));
        Method urlMethod = class_getClassMethod(dataClass, @selector(dataWithContentsOfURL:));
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

#pragma mark - Exact LiquidGlassRedesignFeatures hook

static BOOL XGGReturnYES0(id self, SEL _cmd) {
    NSLog(@"[XGlassGate] %@ -> YES", NSStringFromSelector(_cmd));
    return YES;
}

static BOOL XGGReturnYES2(id self, SEL _cmd, id a1, id a2) {
    NSLog(@"[XGlassGate] %@ -> YES", NSStringFromSelector(_cmd));
    return YES;
}

static BOOL XGGHookExactBOOLMethod(Class cls, SEL selector, IMP replacement) {
    if (!cls) return NO;
    BOOL hooked = NO;

    Method instanceMethod = class_getInstanceMethod(cls, selector);
    if (instanceMethod) {
        const char *types = method_getTypeEncoding(instanceMethod);
        if (types && (types[0] == 'B' || types[0] == 'c')) {
            method_setImplementation(instanceMethod, replacement);
            hooked = YES;
            NSLog(@"[XGlassGate] exact instance hook %@ on %s", NSStringFromSelector(selector), class_getName(cls));
        }
    }

    Method classMethod = class_getClassMethod(cls, selector);
    if (classMethod) {
        const char *types = method_getTypeEncoding(classMethod);
        if (types && (types[0] == 'B' || types[0] == 'c')) {
            method_setImplementation(classMethod, replacement);
            hooked = YES;
            NSLog(@"[XGlassGate] exact class hook %@ on %s", NSStringFromSelector(selector), class_getName(cls));
        }
    }

    return hooked;
}

static BOOL XGGTryInstallRedesignFeaturesHook(void) {
    if (gRedesignFeaturesHookInstalled) return YES;

    Class cls = objc_getClass("_TtC14T1TwitterSwift27LiquidGlassRedesignFeatures");
    if (!cls) return NO;

    BOOL a = XGGHookExactBOOLMethod(cls, NSSelectorFromString(@"isFeatureEnabled:for:"), (IMP)XGGReturnYES2);
    BOOL b = XGGHookExactBOOLMethod(cls, NSSelectorFromString(@"isFeatureEnabled"), (IMP)XGGReturnYES0);
    gRedesignFeaturesHookInstalled = (a || b);
    return gRedesignFeaturesHookInstalled;
}

#pragma mark - XAppearance authoritative getter

static BOOL XGGTryInstallAppearanceHook(void) {
    if (gAppearanceHookInstalled) return YES;

    Class appearanceClass = objc_getClass("_TtC11XAppearance10Appearance");
    if (!appearanceClass) return NO;

    SEL selector = NSSelectorFromString(@"isLiquidGlassEnabled");
    gAppearanceHookInstalled = XGGHookExactBOOLMethod(appearanceClass, selector, (IMP)XGGReturnYES0);
    return gAppearanceHookInstalled;
}

#pragma mark - Native gate installer

static void XGGInstallGateReplacement(id self, SEL _cmd, BOOL redesignEnabled) {
    NSLog(@"[XGlassGate] %@ requested=%@ -> forced YES", NSStringFromSelector(_cmd), redesignEnabled ? @"YES" : @"NO");
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

    if (method_getImplementation(method) == (IMP)XGGInstallGateReplacement) {
        gGateHookInstalled = YES;
        return YES;
    }

    gOriginalInstallGate = method_setImplementation(method, (IMP)XGGInstallGateReplacement);
    gGateHookInstalled = (gOriginalInstallGate != NULL);
    return gGateHookInstalled;
}

#pragma mark - Retry for framework load order

static void XGGRunRuntimeHooks(void) {
    XGGTryInstallRedesignFeaturesHook();
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
        NSLog(@"[XGlassGate] 0.4.0 loaded");
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
