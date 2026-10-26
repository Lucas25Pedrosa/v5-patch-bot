#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>

static NSString *const kVersion = @"3.0";
static const uintptr_t kWriterOffset = 0x2107b34;
static const uint8_t kTargetUUID[16] = {
    0xFD,0x66,0x1A,0xA4,0x70,0x47,0x3C,0x70,
    0x96,0x0A,0x64,0x99,0xC8,0x00,0xD7,0x28
};

typedef void (*XLGWriter)(BOOL);
typedef union { uintptr_t raw; XLGWriter fn; } XLGWriterAddress;

static XLGWriter gWriter = NULL;
static IMP gOrigGate = NULL;
static IMP gOrigLoadView = NULL;
static BOOL gGateHooked = NO;
static BOOL gTabHooked = NO;
static BOOL gUUIDMatched = NO;
static NSUInteger gWriterCalls = 0;

static BOOL HeaderMatchesUUID(const struct mach_header *header) {
    if (!header || header->magic != MH_MAGIC_64) return NO;
    const struct mach_header_64 *h = (const struct mach_header_64 *)header;
    const struct load_command *cmd = (const struct load_command *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        if (cmd->cmd == LC_UUID && cmd->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *u = (const struct uuid_command *)cmd;
            return memcmp(u->uuid, kTargetUUID, 16) == 0;
        }
        cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
    }
    return NO;
}

static const char *ImageNameForHeader(const struct mach_header *header) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (_dyld_get_image_header(i) == header) return _dyld_get_image_name(i);
    }
    return NULL;
}

static BOOL IsXServiceLibraries(const char *path) {
    if (!path) return NO;
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    return strcmp(name, "XServiceLibraries") == 0;
}

static void ApplyWriter(const char *reason) {
    if (!gWriter) return;
    gWriter(YES);
    gWriterCalls++;
    NSLog(@"[XLiquidGlassPreTabBarV30] WRITER reason=%s calls=%lu", reason ?: "?", (unsigned long)gWriterCalls);
}

static void ImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    const char *path = ImageNameForHeader(header);
    if (!IsXServiceLibraries(path)) return;
    if (!HeaderMatchesUUID(header)) return;

    gUUIDMatched = YES;
    uintptr_t base = (uintptr_t)header; // __TEXT vmaddr is 0 in the analyzed 12.38 image.
    XLGWriterAddress resolved = {0};
    resolved.raw = base + kWriterOffset;
    gWriter = resolved.fn;
    ApplyWriter("dyld-image-added");
}

__attribute__((constructor))
static void XLGEarlyConstructor(void) {
    _dyld_register_func_for_add_image(ImageAdded);
    ApplyWriter("constructor-after-register");
}

static void GateHook(id self, SEL _cmd, id account) {
    ApplyWriter("before-installGateForAccount");
    if (gOrigGate) ((void(*)(id,SEL,id))gOrigGate)(self, _cmd, account);
    ApplyWriter("after-installGateForAccount");
}

static void TabLoadViewHook(id self, SEL _cmd) {
    ApplyWriter("before-T1TabBarViewController-loadView");
    if (gOrigLoadView) ((void(*)(id,SEL))gOrigLoadView)(self, _cmd);
    ApplyWriter("after-T1TabBarViewController-loadView");
}

static void InstallGateHook(void) {
    if (gGateHooked) return;
    Class c = NSClassFromString(@"T1LiquidGlassGateInstaller");
    if (!c) return;
    SEL s = NSSelectorFromString(@"installGateForAccount:");
    Method m = class_getClassMethod(c, s);
    if (!m) return;
    Class meta = object_getClass(c);
    IMP cur = class_getMethodImplementation(meta, s);
    if (cur == (IMP)GateHook) { gGateHooked = YES; return; }
    gOrigGate = cur;
    class_replaceMethod(meta, s, (IMP)GateHook, method_getTypeEncoding(m));
    gGateHooked = class_getMethodImplementation(meta, s) == (IMP)GateHook;
    NSLog(@"[XLiquidGlassPreTabBarV30] GATE_HOOK result=%d", gGateHooked ? 1 : 0);
}

static void InstallTabHook(void) {
    if (gTabHooked) return;
    Class c = NSClassFromString(@"T1TabBarViewController");
    if (!c) return;
    SEL s = @selector(loadView);
    Method m = class_getInstanceMethod(c, s);
    if (!m) return;
    IMP cur = class_getMethodImplementation(c, s);
    if (cur == (IMP)TabLoadViewHook) { gTabHooked = YES; return; }
    gOrigLoadView = cur;
    class_replaceMethod(c, s, (IMP)TabLoadViewHook, method_getTypeEncoding(m));
    gTabHooked = class_getMethodImplementation(c, s) == (IMP)TabLoadViewHook;
    NSLog(@"[XLiquidGlassPreTabBarV30] TAB_HOOK class=T1TabBarViewController selector=loadView result=%d", gTabHooked ? 1 : 0);
}

static void InstallRuntimeGuards(void) {
    InstallGateHook();
    InstallTabHook();
    ApplyWriter("runtime-guard-pass");
}

@interface XLGPreTabBarV30Bootstrap : NSObject
@end

@implementation XLGPreTabBarV30Bootstrap
+ (void)load {
    @autoreleasepool {
        NSLog(@"[XLiquidGlassPreTabBarV30] NEW_SESSION version=%@ target=X_12.38 mode=DYLD_PRE_TABBAR uuidMatch=%d writer=%d", kVersion, gUUIDMatched ? 1 : 0, gWriter ? 1 : 0);
        ApplyWriter("objc-load-sync");
        InstallRuntimeGuards();

        NSArray<NSNumber *> *delays = @[@0.0,@0.01,@0.03,@0.06,@0.10,@0.20,@0.35,@0.50,@0.80,@1.20];
        for (NSNumber *n in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(n.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                InstallRuntimeGuards();
            });
        }
    }
}
@end
