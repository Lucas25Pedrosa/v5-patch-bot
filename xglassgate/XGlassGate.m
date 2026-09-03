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

#pragma mark - Embedded feature-switch patch

static NSData *XGGPatchDefaultsData(NSData *data, NSString *source) {
    if (!data || data.length == 0) {
        return data;
    }

    NSData *keyData = [XGGFeatureKey dataUsingEncoding:NSUTF8StringEncoding];
    NSData *falseData = [@"false" dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char truePadded[5] = {'t', 'r', 'u', 'e', ' '};

    NSRange keyRange = [data rangeOfData:keyData
                                 options:0
                                   range:NSMakeRange(0, data.length)];
    if (keyRange.location == NSNotFound) {
        return data;
    }

    NSMutableData *patched = [data mutableCopy];
    BOOL changed = NO;
    NSUInteger cursor = 0;

    while (cursor < patched.length) {
        NSRange searchRange = NSMakeRange(cursor, patched.length - cursor);
        NSRange currentKey = [patched rangeOfData:keyData options:0 range:searchRange];
        if (currentKey.location == NSNotFound) {
            break;
        }

        NSUInteger valueSearchStart = NSMaxRange(currentKey);
        NSUInteger remaining = patched.length - valueSearchStart;
        NSUInteger valueSearchLength = MIN((NSUInteger)256, remaining);

        if (valueSearchLength >= falseData.length) {
            NSRange falseRange = [patched rangeOfData:falseData
                                             options:0
                                               range:NSMakeRange(valueSearchStart,
                                                                 valueSearchLength)];
            if (falseRange.location != NSNotFound) {
                [patched replaceBytesInRange:falseRange
                                   withBytes:truePadded
                                      length:sizeof(truePadded)];
                changed = YES;
                NSLog(@"[XGlassGate] feature switch forced TRUE in %@", source ?: @"data");
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
    NSData *data = nil;
    if (gOriginalDataWithFile) {
        data = ((NSData *(*)(id, SEL, NSString *))gOriginalDataWithFile)(self, _cmd, path);
    }

    if ([path.lastPathComponent hasPrefix:@"fs_embedded_defaults_"] &&
        [path.pathExtension.lowercaseString isEqualToString:@"json"]) {
        return XGGPatchDefaultsData(data, path.lastPathComponent);
    }

    return data;
}

static NSData *XGGDataWithContentsOfURLReplacement(id self, SEL _cmd, NSURL *url) {
    NSData *data = nil;
    if (gOriginalDataWithURL) {
        data = ((NSData *(*)(id, SEL, NSURL *))gOriginalDataWithURL)(self, _cmd, url);
    }

    NSString *path = url.path;
    if ([path.lastPathComponent hasPrefix:@"fs_embedded_defaults_"] &&
        [path.pathExtension.lowercaseString isEqualToString:@"json"]) {
        return XGGPatchDefaultsData(data, path.lastPathComponent);
    }

    return data;
}

static id XGGJSONObjectWithDataReplacement(id self,
                                            SEL _cmd,
                                            NSData *data,
                                            NSJSONReadingOptions options,
                                            NSError **error) {
    NSData *patchedData = XGGPatchDefaultsData(data, @"NSJSONSerialization");
    id object = nil;

    if (gOriginalJSONObjectWithData) {
        object = ((id (*)(id, SEL, NSData *, NSJSONReadingOptions, NSError **))gOriginalJSONObjectWithData)(
            self, _cmd, patchedData, options, error);
    }

    if (!object) {
        return object;
    }

    NSData *keyData = [XGGFeatureKey dataUsingEncoding:NSUTF8StringEncoding];
    if ([patchedData rangeOfData:keyData options:0 range:NSMakeRange(0, patchedData.length)].location == NSNotFound) {
        return object;
    }

    id mutableObject = XGGDeepMutableCopy(object);
    NSUInteger changes = XGGForceFeatureInObject(mutableObject);
    if (changes > 0) {
        NSLog(@"[XGlassGate] JSON object forced %@=TRUE (%lu)",
              XGGFeatureKey,
              (unsigned long)changes);
        return mutableObject;
    }

    return object;
}

static void XGGInstallFeatureHooks(void) {
    if (!gDataHooksInstalled) {
        Class dataClass = [NSData class];

        Method fileMethod = class_getClassMethod(dataClass, @selector(dataWithContentsOfFile:));
        if (fileMethod) {
            gOriginalDataWithFile = method_setImplementation(fileMethod,
                                                              (IMP)XGGDataWithContentsOfFileReplacement);
        }

        Method urlMethod = class_getClassMethod(dataClass, @selector(dataWithContentsOfURL:));
        if (urlMethod) {
            gOriginalDataWithURL = method_setImplementation(urlMethod,
                                                             (IMP)XGGDataWithContentsOfURLReplacement);
        }

        gDataHooksInstalled = (gOriginalDataWithFile != NULL || gOriginalDataWithURL != NULL);
        NSLog(@"[XGlassGate] embedded defaults hooks %@",
              gDataHooksInstalled ? @"installed" : @"FAILED");
    }

    if (!gJSONHookInstalled) {
        Class jsonClass = [NSJSONSerialization class];
        Method jsonMethod = class_getClassMethod(jsonClass, @selector(JSONObjectWithData:options:error:));
        if (jsonMethod) {
            gOriginalJSONObjectWithData = method_setImplementation(jsonMethod,
                                                                    (IMP)XGGJSONObjectWithDataReplacement);
            gJSONHookInstalled = (gOriginalJSONObjectWithData != NULL);
        }

        NSLog(@"[XGlassGate] JSON fallback hook %@",
              gJSONHookInstalled ? @"installed" : @"FAILED");
    }
}

#pragma mark - LiquidGlassRedesignFeatures second factor

static BOOL XGGReturnYES0(id self, SEL _cmd) {
    NSLog(@"[XGlassGate] %@ -> forced YES", NSStringFromSelector(_cmd));
    return YES;
}

static BOOL XGGReturnYES1(id self, SEL _cmd, id a1) {
    NSLog(@"[XGlassGate] %@ -> forced YES", NSStringFromSelector(_cmd));
    return YES;
}

static BOOL XGGReturnYES2(id self, SEL _cmd, id a1, id a2) {
    NSLog(@"[XGlassGate] %@ -> forced YES", NSStringFromSelector(_cmd));
    return YES;
}

static BOOL XGGReturnYES3(id self, SEL _cmd, id a1, id a2, id a3) {
    NSLog(@"[XGlassGate] %@ -> forced YES", NSStringFromSelector(_cmd));
    return YES;
}

static NSUInteger XGGColonCount(NSString *selectorName) {
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < selectorName.length; i++) {
        if ([selectorName characterAtIndex:i] == ':') {
            count++;
        }
    }
    return count;
}

static BOOL XGGHookFeatureMethodsOnClass(Class cls) {
    if (!cls) {
        return NO;
    }

    NSUInteger hooked = 0;
    Class targets[2] = { cls, object_getClass(cls) };

    for (NSUInteger targetIndex = 0; targetIndex < 2; targetIndex++) {
        Class target = targets[targetIndex];
        if (!target) {
            continue;
        }

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(target, &methodCount);

        for (unsigned int i = 0; i < methodCount; i++) {
            Method method = methods[i];
            SEL selector = method_getName(method);
            NSString *name = NSStringFromSelector(selector);
            const char *types = method_getTypeEncoding(method);

            BOOL interesting = ([name rangeOfString:@"isFeatureEnabled" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                               ([name rangeOfString:@"featureEnabled" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                               ([name rangeOfString:@"isEnabled" options:NSCaseInsensitiveSearch].location != NSNotFound);

            if (!interesting) {
                continue;
            }

            // Only replace methods that return Objective-C BOOL (B or legacy c).
            if (!types || (types[0] != 'B' && types[0] != 'c')) {
                NSLog(@"[XGlassGate] candidate %@ ignored (types=%s)", name, types ?: "?");
                continue;
            }

            NSUInteger colons = XGGColonCount(name);
            IMP replacement = NULL;
            switch (colons) {
                case 0: replacement = (IMP)XGGReturnYES0; break;
                case 1: replacement = (IMP)XGGReturnYES1; break;
                case 2: replacement = (IMP)XGGReturnYES2; break;
                case 3: replacement = (IMP)XGGReturnYES3; break;
                default: break;
            }

            if (!replacement) {
                NSLog(@"[XGlassGate] candidate %@ ignored (%lu args)",
                      name,
                      (unsigned long)colons);
                continue;
            }

            if (method_getImplementation(method) != replacement) {
                method_setImplementation(method, replacement);
            }

            hooked++;
            NSLog(@"[XGlassGate] LiquidGlassRedesignFeatures hooked %@ (%s)",
                  name,
                  targetIndex == 0 ? "instance" : "class");
        }

        free(methods);
    }

    return hooked > 0;
}

static BOOL XGGTryInstallRedesignFeaturesHook(void) {
    if (gRedesignFeaturesHookInstalled) {
        return YES;
    }

    const char *classNames[] = {
        "_TtC14T1TwitterSwift27LiquidGlassRedesignFeatures",
        "T1TwitterSwift.LiquidGlassRedesignFeatures"
    };

    for (NSUInteger i = 0; i < sizeof(classNames) / sizeof(classNames[0]); i++) {
        Class cls = objc_getClass(classNames[i]);
        if (!cls) {
            continue;
        }

        NSLog(@"[XGlassGate] found LiquidGlassRedesignFeatures runtime class: %s",
              class_getName(cls));

        gRedesignFeaturesHookInstalled = XGGHookFeatureMethodsOnClass(cls);
        if (gRedesignFeaturesHookInstalled) {
            return YES;
        }
    }

    return NO;
}

#pragma mark - Native Liquid Glass gate

static void XGGInstallGateReplacement(id self, SEL _cmd, BOOL redesignEnabled) {
    NSLog(@"[XGlassGate] %@ requested=%@ -> forced=YES",
          NSStringFromSelector(_cmd),
          redesignEnabled ? @"YES" : @"NO");

    if (gOriginalInstallGate) {
        ((void (*)(id, SEL, BOOL))gOriginalInstallGate)(self, _cmd, YES);
    }
}

static BOOL XGGTryInstallGateHook(void) {
    if (gGateHookInstalled) {
        return YES;
    }

    Class installerClass = objc_getClass("T1LiquidGlassGateInstaller");
    if (!installerClass) {
        return NO;
    }

    SEL selector = NSSelectorFromString(@"installGateWithRedesignEnabled:");
    Method method = class_getClassMethod(installerClass, selector);

    if (!method) {
        method = class_getInstanceMethod(installerClass, selector);
    }

    if (!method) {
        NSLog(@"[XGlassGate] selector %@ not found", NSStringFromSelector(selector));
        return NO;
    }

    IMP current = method_getImplementation(method);
    if (current == (IMP)XGGInstallGateReplacement) {
        gGateHookInstalled = YES;
        return YES;
    }

    gOriginalInstallGate = method_setImplementation(method, (IMP)XGGInstallGateReplacement);
    gGateHookInstalled = (gOriginalInstallGate != NULL);

    NSLog(@"[XGlassGate] gate hook %@ for %@",
          gGateHookInstalled ? @"installed" : @"FAILED",
          NSStringFromSelector(selector));

    return gGateHookInstalled;
}

static void XGGRunRuntimeHooks(void) {
    XGGTryInstallRedesignFeaturesHook();
    XGGTryInstallGateHook();
}

static void XGGScheduleRetry(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        XGGRunRuntimeHooks();
    });
}

__attribute__((constructor))
static void XGlassGateInit(void) {
    @autoreleasepool {
        NSLog(@"[XGlassGate] 0.3.0 loaded");

        XGGInstallFeatureHooks();
        XGGRunRuntimeHooks();

        // Retry because T1Twitter.framework may register the Swift runtime class
        // after injected tweak constructors have already begun executing.
        XGGScheduleRetry(0.0);
        XGGScheduleRetry(0.05);
        XGGScheduleRetry(0.20);
        XGGScheduleRetry(1.00);
        XGGScheduleRetry(3.00);
    }
}
