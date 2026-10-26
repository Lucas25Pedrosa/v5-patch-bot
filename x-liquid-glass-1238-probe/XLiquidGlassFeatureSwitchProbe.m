#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static NSString *const kXLGFeatureLog = @"XLiquidGlass1238Probe.log";
static NSUInteger gXLGFeatureCalls = 0;
static NSUInteger gXLGLiquidCalls = 0;
static NSUInteger gXLGForcedCalls = 0;
static NSUInteger gXLGInstallPass = 0;

typedef struct {
    Class cls;
    SEL sel;
    IMP orig;
    unsigned int argc;
    BOOL classMethod;
} XLGFSHook;

static XLGFSHook gXLGFSHooks[512];
static NSUInteger gXLGFSHookCount = 0;

static NSString *XLGFSLogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kXLGFeatureLog];
}

static void XLGFSLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void XLGFSLog(NSString *fmt, ...) {
    if (!fmt) return;
    va_list args;
    va_start(args, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[FEATURE] %@\n", body ?: @""];
    NSLog(@"[XLiquidGlass1238Feature] %@", body ?: @"");
    @synchronized(NSFileManager.defaultManager) {
        NSString *path = XLGFSLogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
    }
}

static BOOL XLGFSEnabled(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:@"XLiquidGlassEnabled"];
    return value ? [value boolValue] : YES;
}

static NSString *XLGFSKey(id key) {
    if ([key isKindOfClass:NSString.class]) return (NSString *)key;
    if (!key) return @"";
    @try { return [key description] ?: @""; }
    @catch (__unused NSException *e) { return @""; }
}

static BOOL XLGFSIsLiquidKey(NSString *key) {
    return [key hasPrefix:@"ios_liquid_glass_"];
}

static NSString *XLGFSImage(Class cls) {
    const char *image = class_getImageName(cls);
    if (!image) return @"-";
    NSString *path = [NSString stringWithUTF8String:image] ?: @"-";
    return path.lastPathComponent.length ? path.lastPathComponent : path;
}

static BOOL XLGFSInterestingClass(Class cls) {
    if (!cls) return NO;
    NSString *name = NSStringFromClass(cls);
    NSString *lower = name.lowercaseString;
    const char *imageC = class_getImageName(cls);
    NSString *image = imageC ? ([NSString stringWithUTF8String:imageC] ?: @"") : @"";

    if ([image containsString:@"/Twitter.app/"] || [image hasSuffix:@"/Twitter"]) return YES;
    if ([lower containsString:@"featureswitch"] ||
        [lower hasPrefix:@"tfs"] ||
        [lower hasPrefix:@"tps"] ||
        [lower containsString:@"featureaccess"]) return YES;
    return NO;
}

static XLGFSHook *XLGFSFind(id receiver, SEL sel) {
    if (!receiver || !sel) return NULL;
    Class dynamic = object_getClass(receiver);
    for (NSUInteger i = 0; i < gXLGFSHookCount; i++) {
        Class target = gXLGFSHooks[i].classMethod ? object_getClass(gXLGFSHooks[i].cls) : gXLGFSHooks[i].cls;
        if (gXLGFSHooks[i].sel == sel && dynamic == target) return &gXLGFSHooks[i];
    }
    for (Class c = dynamic; c; c = class_getSuperclass(c)) {
        for (NSUInteger i = 0; i < gXLGFSHookCount; i++) {
            Class target = gXLGFSHooks[i].classMethod ? object_getClass(gXLGFSHooks[i].cls) : gXLGFSHooks[i].cls;
            if (gXLGFSHooks[i].sel == sel && c == target) return &gXLGFSHooks[i];
        }
    }
    return NULL;
}

static void XLGFSLogCaller(NSString *selector) {
    void *caller = __builtin_extract_return_addr(__builtin_return_address(0));
    Dl_info info = {0};
    if (caller && dladdr(caller, &info) && info.dli_fname) {
        uintptr_t off = info.dli_fbase ? (uintptr_t)caller - (uintptr_t)info.dli_fbase : 0;
        NSString *path = [NSString stringWithUTF8String:info.dli_fname] ?: @"-";
        XLGFSLog(@"FEATURE_CALLER selector=%@ image=%@ offset=0x%llx address=%p",
                 selector ?: @"-", path.lastPathComponent ?: path,
                 (unsigned long long)off, caller);
    }
}

static BOOL XLGFSBool1(id self, SEL _cmd, id key) {
    XLGFSHook *h = XLGFSFind(self, _cmd);
    BOOL native = h && h->orig ? ((BOOL(*)(id,SEL,id))h->orig)(self,_cmd,key) : NO;
    NSString *name = XLGFSKey(key);
    BOOL liquid = XLGFSIsLiquidKey(name);
    BOOL forced = XLGFSEnabled() && liquid;
    BOOL result = forced ? YES : native;

    gXLGFeatureCalls++;
    if (liquid) gXLGLiquidCalls++;
    if (forced && !native) gXLGForcedCalls++;

    if (liquid) {
        XLGFSLog(@"FEATURE_SWITCH selector=%@ class=%@ key=%@ native=%d returned=%d forced=%d calls=%lu liquid=%lu forcedCalls=%lu",
                 NSStringFromSelector(_cmd), NSStringFromClass([self class]), name,
                 native, result, forced,
                 (unsigned long)gXLGFeatureCalls,
                 (unsigned long)gXLGLiquidCalls,
                 (unsigned long)gXLGForcedCalls);
        if (gXLGLiquidCalls <= 12) XLGFSLogCaller(NSStringFromSelector(_cmd));
    }
    return result;
}

static BOOL XLGFSBool2(id self, SEL _cmd, id key, BOOL def) {
    XLGFSHook *h = XLGFSFind(self, _cmd);
    BOOL native = h && h->orig ? ((BOOL(*)(id,SEL,id,BOOL))h->orig)(self,_cmd,key,def) : def;
    NSString *name = XLGFSKey(key);
    BOOL liquid = XLGFSIsLiquidKey(name);
    BOOL forced = XLGFSEnabled() && liquid;
    BOOL result = forced ? YES : native;

    gXLGFeatureCalls++;
    if (liquid) gXLGLiquidCalls++;
    if (forced && !native) gXLGForcedCalls++;

    if (liquid) {
        XLGFSLog(@"FEATURE_SWITCH selector=%@ class=%@ key=%@ default=%d native=%d returned=%d forced=%d calls=%lu liquid=%lu forcedCalls=%lu",
                 NSStringFromSelector(_cmd), NSStringFromClass([self class]), name,
                 def, native, result, forced,
                 (unsigned long)gXLGFeatureCalls,
                 (unsigned long)gXLGLiquidCalls,
                 (unsigned long)gXLGForcedCalls);
        if (gXLGLiquidCalls <= 12) XLGFSLogCaller(NSStringFromSelector(_cmd));
    }
    return result;
}

static BOOL XLGFSRecorded(Class cls, SEL sel, BOOL classMethod) {
    for (NSUInteger i = 0; i < gXLGFSHookCount; i++) {
        if (gXLGFSHooks[i].cls == cls && gXLGFSHooks[i].sel == sel && gXLGFSHooks[i].classMethod == classMethod) return YES;
    }
    return NO;
}

static BOOL XLGFSInstallMethod(Class cls, Method method, BOOL classMethod) {
    if (!cls || !method || gXLGFSHookCount >= 512) return NO;
    NSArray<NSString *> *names = @[
        @"boolForKey:",
        @"boolForKey:defaultValue:",
        @"tfs_boolForKey:",
        @"tfs_boolForKey:defaultValue:"
    ];

    SEL sel = method_getName(method);
    NSString *sn = NSStringFromSelector(sel);
    if (![names containsObject:sn] || XLGFSRecorded(cls, sel, classMethod)) return NO;

    const char *types = method_getTypeEncoding(method);
    unsigned int argc = method_getNumberOfArguments(method);
    if (!types || (types[0] != 'B' && types[0] != 'c' && types[0] != 'C') || (argc != 3 && argc != 4)) {
        XLGFSLog(@"FEATURE_CANDIDATE_REJECT class=%@ selector=%@ classMethod=%d types=%s argc=%u image=%@",
                 NSStringFromClass(cls), sn, classMethod, types ?: "-", argc, XLGFSImage(cls));
        return NO;
    }

    Class target = classMethod ? object_getClass(cls) : cls;
    IMP orig = method_getImplementation(method);
    IMP repl = argc == 3 ? (IMP)XLGFSBool1 : (IMP)XLGFSBool2;
    class_replaceMethod(target, sel, repl, types);
    if (class_getMethodImplementation(target, sel) != repl) return NO;

    gXLGFSHooks[gXLGFSHookCount++] = (XLGFSHook){cls, sel, orig, argc, classMethod};
    XLGFSLog(@"FEATURE_HOOK class=%@ selector=%@ classMethod=%d argc=%u image=%@ original=%p replacement=%p",
             NSStringFromClass(cls), sn, classMethod, argc, XLGFSImage(cls), orig, repl);
    return YES;
}

static void XLGFSInstall(void) {
    gXLGInstallPass++;
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) {
        XLGFSLog(@"FEATURE_HOOK_PASS pass=%lu classes=0 total=%lu added=0 enabled=%d",
                 (unsigned long)gXLGInstallPass, (unsigned long)gXLGFSHookCount, XLGFSEnabled());
        return;
    }

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)n, sizeof(Class));
    if (!classes) return;
    n = objc_getClassList(classes, n);

    NSUInteger added = 0;
    NSUInteger interesting = 0;
    NSUInteger directCandidates = 0;

    for (int i = 0; i < n && gXLGFSHookCount < 512; i++) {
        Class cls = classes[i];
        if (!XLGFSInterestingClass(cls)) continue;
        interesting++;

        unsigned int mc = 0;
        Method *methods = class_copyMethodList(cls, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            SEL sel = method_getName(methods[j]);
            NSString *sn = NSStringFromSelector(sel);
            if ([sn isEqualToString:@"boolForKey:"] ||
                [sn isEqualToString:@"boolForKey:defaultValue:"] ||
                [sn isEqualToString:@"tfs_boolForKey:"] ||
                [sn isEqualToString:@"tfs_boolForKey:defaultValue:"]) {
                directCandidates++;
                if (XLGFSInstallMethod(cls, methods[j], NO)) added++;
            }
        }
        free(methods);

        Class meta = object_getClass(cls);
        unsigned int cmc = 0;
        Method *classMethods = class_copyMethodList(meta, &cmc);
        for (unsigned int j = 0; j < cmc; j++) {
            SEL sel = method_getName(classMethods[j]);
            NSString *sn = NSStringFromSelector(sel);
            if ([sn isEqualToString:@"boolForKey:"] ||
                [sn isEqualToString:@"boolForKey:defaultValue:"] ||
                [sn isEqualToString:@"tfs_boolForKey:"] ||
                [sn isEqualToString:@"tfs_boolForKey:defaultValue:"]) {
                directCandidates++;
                if (XLGFSInstallMethod(cls, classMethods[j], YES)) added++;
            }
        }
        free(classMethods);
    }

    free(classes);
    XLGFSLog(@"FEATURE_HOOK_PASS pass=%lu classes=%d interesting=%lu candidates=%lu total=%lu added=%lu enabled=%d",
             (unsigned long)gXLGInstallPass, n,
             (unsigned long)interesting,
             (unsigned long)directCandidates,
             (unsigned long)gXLGFSHookCount,
             (unsigned long)added,
             XLGFSEnabled());
}

@interface XLiquidGlassFeatureSwitchBootstrap : NSObject
@end

@implementation XLiquidGlassFeatureSwitchBootstrap
+ (void)load {
    @autoreleasepool {
        XLGFSLog(@"FEATURE_SESSION version=2.1 target=X_12.38 bootstrap=+load enabled=%d",
                 XLGFSEnabled());
        NSArray<NSNumber *> *delays = @[@0.0,@0.15,@0.5,@1.0,@2.0,@4.0,@8.0,@15.0];
        for (NSNumber *d in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ XLGFSInstall(); });
        }
    }
}
@end
