#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdint.h>
#import <string.h>

static NSString * const XGGFeatureKey = @"ios_liquid_glass_redesign_enabled";

typedef void (*MSHookMemoryType)(void *target, const void *data, size_t size);

static IMP gOriginalInstallGate = NULL;
static IMP gOriginalDataWithFile = NULL;
static IMP gOriginalDataWithURL = NULL;
static IMP gOriginalJSONObjectWithData = NULL;

static BOOL gGateHookInstalled = NO;
static BOOL gDataHooksInstalled = NO;
static BOOL gJSONHookInstalled = NO;
static BOOL gBranchPatchesInstalled = NO;

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

#pragma mark - Existing safe native gate

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

#pragma mark - Direct Legacy -> Glass branch patch (X 12.23 only)

static const struct mach_header_64 *XGGFindT1TwitterHeader(void) {
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strstr(name, "/T1Twitter.framework/T1Twitter") != NULL) {
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

static BOOL XGGPatchInstruction(MSHookMemoryType hookMemory,
                                uintptr_t base,
                                uintptr_t offset,
                                const uint8_t expected[4]) {
    uint8_t *target = (uint8_t *)(base + offset);
    const uint8_t nop[4] = {0x1f, 0x20, 0x03, 0xd5};

    if (memcmp(target, nop, sizeof(nop)) == 0) {
        return YES;
    }

    if (memcmp(target, expected, 4) != 0) {
        NSLog(@"[XGlassGate] skip 0x%llx: unexpected bytes %02x %02x %02x %02x",
              (unsigned long long)offset,
              target[0], target[1], target[2], target[3]);
        return NO;
    }

    hookMemory(target, nop, sizeof(nop));
    BOOL ok = (memcmp(target, nop, sizeof(nop)) == 0);
    NSLog(@"[XGlassGate] branch 0x%llx %@",
          (unsigned long long)offset,
          ok ? @"patched -> WithGlass" : @"FAILED");
    return ok;
}

static BOOL XGGTryInstallBranchPatches(void) {
    if (gBranchPatchesInstalled) return YES;

    MSHookMemoryType hookMemory = (MSHookMemoryType)XGGFindSymbol("MSHookMemory");
    if (!hookMemory) {
        NSLog(@"[XGlassGate] MSHookMemory unavailable");
        return NO;
    }

    const struct mach_header_64 *header = XGGFindT1TwitterHeader();
    if (!header) return NO;

    // T1Twitter 12.23 __TEXT vmaddr is 0, so image header + unslid VM offset.
    uintptr_t base = (uintptr_t)header;

    const uint8_t expectedA[4] = {0x60, 0x00, 0x00, 0x36}; // tbz w0,#0 -> Legacy
    const uint8_t expectedB[4] = {0x80, 0x02, 0x00, 0x36}; // tbz w0,#0 -> Legacy

    BOOL a = XGGPatchInstruction(hookMemory, base, 0x00DA1F84, expectedA);
    BOOL b = XGGPatchInstruction(hookMemory, base, 0x00DB2C38, expectedA);
    BOOL c = XGGPatchInstruction(hookMemory, base, 0x00DB8BF4, expectedB);

    gBranchPatchesInstalled = (a && b && c);
    return gBranchPatchesInstalled;
}

static void XGGRunSafePatches(void) {
    XGGTryInstallGateHook();
    XGGTryInstallBranchPatches();
}

static void XGGScheduleRetry(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XGGRunSafePatches();
    });
}

__attribute__((constructor))
static void XGlassGateInit(void) {
    @autoreleasepool {
        NSLog(@"[XGlassGate] 0.6.0 loaded");

        // Keep only the non-crashing feature/gate layers from earlier builds.
        XGGInstallFeatureHooks();

        // No direct Swift function hook in 0.6.0. Patch only the verified
        // Legacy/Glass branch instructions after T1Twitter has loaded.
        XGGScheduleRetry(0.20);
        XGGScheduleRetry(1.00);
        XGGScheduleRetry(3.00);
    }
}
