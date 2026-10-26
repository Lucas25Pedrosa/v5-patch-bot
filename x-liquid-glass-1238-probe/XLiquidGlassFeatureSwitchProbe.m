#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *const kXLGFeatureLog = @"XLiquidGlass1238Probe.log";
static NSUInteger gXLGFeatureCalls = 0;
static NSUInteger gXLGLiquidCalls = 0;
static NSUInteger gXLGForcedCalls = 0;

typedef struct { Class cls; SEL sel; IMP orig; unsigned int argc; } XLGFSHook;
static XLGFSHook gXLGFSHooks[384];
static NSUInteger gXLGFSHookCount = 0;

static NSString *XLGFSLogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kXLGFeatureLog];
}

static void XLGFSLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[FEATURE] %@\n", body ?: @""];
    @synchronized(NSFileManager.defaultManager) {
        NSString *path = XLGFSLogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (h) { [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile]; }
    }
}

static BOOL XLGFSEnabled(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:@"XLiquidGlassEnabled"];
    return value ? [value boolValue] : YES;
}

static NSString *XLGFSKey(id key) {
    if ([key isKindOfClass:NSString.class]) return key;
    return key ? ([key description] ?: @"") : @"";
}

static BOOL XLGFSIsLiquidKey(NSString *key) {
    return [key hasPrefix:@"ios_liquid_glass_"];
}

static BOOL XLGFSAppClass(Class cls) {
    const char *image = class_getImageName(cls);
    if (!image) return NO;
    NSString *path = [NSString stringWithUTF8String:image] ?: @"";
    return [path containsString:@"/Twitter.app/"] || [path hasSuffix:@"/Twitter"];
}

static XLGFSHook *XLGFSFind(id receiver, SEL sel) {
    for (Class c = object_getClass(receiver); c; c = class_getSuperclass(c)) {
        for (NSUInteger i = 0; i < gXLGFSHookCount; i++) if (gXLGFSHooks[i].cls == c && gXLGFSHooks[i].sel == sel) return &gXLGFSHooks[i];
    }
    return NULL;
}

static BOOL XLGFSBool1(id self, SEL _cmd, id key) {
    XLGFSHook *h = XLGFSFind(self, _cmd);
    BOOL native = h && h->orig ? ((BOOL(*)(id,SEL,id))h->orig)(self,_cmd,key) : NO;
    NSString *name = XLGFSKey(key);
    BOOL forced = XLGFSEnabled() && XLGFSIsLiquidKey(name);
    BOOL result = forced ? YES : native;
    gXLGFeatureCalls++; if (XLGFSIsLiquidKey(name)) gXLGLiquidCalls++; if (forced && !native) gXLGForcedCalls++;
    if (XLGFSIsLiquidKey(name)) XLGFSLog(@"FEATURE_SWITCH selector=%@ class=%@ key=%@ native=%d returned=%d forced=%d calls=%lu liquid=%lu forcedCalls=%lu", NSStringFromSelector(_cmd), NSStringFromClass([self class]), name, native, result, forced, (unsigned long)gXLGFeatureCalls, (unsigned long)gXLGLiquidCalls, (unsigned long)gXLGForcedCalls);
    return result;
}

static BOOL XLGFSBool2(id self, SEL _cmd, id key, BOOL def) {
    XLGFSHook *h = XLGFSFind(self, _cmd);
    BOOL native = h && h->orig ? ((BOOL(*)(id,SEL,id,BOOL))h->orig)(self,_cmd,key,def) : def;
    NSString *name = XLGFSKey(key);
    BOOL forced = XLGFSEnabled() && XLGFSIsLiquidKey(name);
    BOOL result = forced ? YES : native;
    gXLGFeatureCalls++; if (XLGFSIsLiquidKey(name)) gXLGLiquidCalls++; if (forced && !native) gXLGForcedCalls++;
    if (XLGFSIsLiquidKey(name)) XLGFSLog(@"FEATURE_SWITCH selector=%@ class=%@ key=%@ default=%d native=%d returned=%d forced=%d calls=%lu liquid=%lu forcedCalls=%lu", NSStringFromSelector(_cmd), NSStringFromClass([self class]), name, def, native, result, forced, (unsigned long)gXLGFeatureCalls, (unsigned long)gXLGLiquidCalls, (unsigned long)gXLGForcedCalls);
    return result;
}

static BOOL XLGFSRecorded(Class cls, SEL sel) {
    for (NSUInteger i = 0; i < gXLGFSHookCount; i++) if (gXLGFSHooks[i].cls == cls && gXLGFSHooks[i].sel == sel) return YES;
    return NO;
}

static void XLGFSInstall(void) {
    NSArray *names = @[@"boolForKey:", @"boolForKey:defaultValue:", @"tfs_boolForKey:", @"tfs_boolForKey:defaultValue:"];
    int n = objc_getClassList(NULL,0); if (n <= 0) return;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)n,sizeof(Class));
    n = objc_getClassList(classes,n);
    NSUInteger added = 0;
    for (int i = 0; i < n && gXLGFSHookCount < 384; i++) {
        Class cls = classes[i]; if (!XLGFSAppClass(cls)) continue;
        unsigned int mc = 0; Method *methods = class_copyMethodList(cls,&mc);
        for (unsigned int j = 0; j < mc; j++) {
            SEL sel = method_getName(methods[j]); NSString *sn = NSStringFromSelector(sel);
            if (![names containsObject:sn] || XLGFSRecorded(cls,sel)) continue;
            const char *types = method_getTypeEncoding(methods[j]); unsigned int argc = method_getNumberOfArguments(methods[j]);
            if (!types || (types[0] != 'B' && types[0] != 'c') || (argc != 3 && argc != 4)) continue;
            IMP orig = method_getImplementation(methods[j]); IMP repl = argc == 3 ? (IMP)XLGFSBool1 : (IMP)XLGFSBool2;
            class_replaceMethod(cls,sel,repl,types);
            if (class_getMethodImplementation(cls,sel) == repl) { gXLGFSHooks[gXLGFSHookCount++] = (XLGFSHook){cls,sel,orig,argc}; added++; XLGFSLog(@"FEATURE_HOOK class=%@ selector=%@ argc=%u", NSStringFromClass(cls), sn, argc); }
        }
        free(methods);
    }
    free(classes);
    XLGFSLog(@"FEATURE_HOOK_PASS total=%lu added=%lu XLiquidGlassEnabled=%d", (unsigned long)gXLGFSHookCount, (unsigned long)added, XLGFSEnabled());
}

__attribute__((constructor)) static void XLGFSInit(void) {
    @autoreleasepool {
        XLGFSLog(@"FEATURE_SESSION version=2.0 target=X_12.38 XLiquidGlassEnabled=%d", XLGFSEnabled());
        NSArray *delays = @[@0.0,@0.2,@0.7,@1.5,@3.0,@6.0,@10.0];
        for (NSNumber *d in delays) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(d.doubleValue*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ XLGFSInstall(); });
    }
}
