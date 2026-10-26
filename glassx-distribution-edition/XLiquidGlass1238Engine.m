#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <string.h>
#include <stdint.h>

// XLiquidGlass 3.0 Beta 1
// X 12.38 activation engine only.
// Keeps the existing XLiquidGlassEnabled preference/UI and leaves Tab Tint
// and Lucas25Pedrosa credits in their existing modules untouched.

static NSString *const kXLG1238EnabledKey = @"XLiquidGlassEnabled";
static const uintptr_t kXLG1238WriterOffset = 0x2107b34;
static const uint8_t kXLG1238TargetUUID[16] = {
    0xFD,0x66,0x1A,0xA4,0x70,0x47,0x3C,0x70,
    0x96,0x0A,0x64,0x99,0xC8,0x00,0xD7,0x28
};

typedef void (*XLG1238Writer)(BOOL);
typedef union {
    uintptr_t raw;
    XLG1238Writer fn;
} XLG1238WriterAddress;

static XLG1238Writer gXLG1238Writer = NULL;
static IMP gXLG1238OrigGate = NULL;
static IMP gXLG1238OrigLoadView = NULL;
static BOOL gXLG1238GateHooked = NO;
static BOOL gXLG1238TabHooked = NO;
static BOOL gXLG1238UUIDMatched = NO;

static BOOL XLG1238Enabled(void) {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:kXLG1238EnabledKey];
    return stored ? [stored boolValue] : YES;
}

static BOOL XLG1238HeaderMatchesUUID(const struct mach_header *header) {
    if (!header || header->magic != MH_MAGIC_64) return NO;

    const struct mach_header_64 *h = (const struct mach_header_64 *)header;
    const struct load_command *cmd = (const struct load_command *)(h + 1);

    for (uint32_t i = 0; i < h->ncmds; i++) {
        if (cmd->cmd == LC_UUID && cmd->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *u = (const struct uuid_command *)cmd;
            return memcmp(u->uuid, kXLG1238TargetUUID, 16) == 0;
        }
        cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
    }

    return NO;
}

static const char *XLG1238ImageNameForHeader(const struct mach_header *header) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (_dyld_get_image_header(i) == header) {
            return _dyld_get_image_name(i);
        }
    }
    return NULL;
}

static BOOL XLG1238IsXServiceLibraries(const char *path) {
    if (!path) return NO;
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    return strcmp(name, "XServiceLibraries") == 0;
}

static void XLG1238ApplyWriter(const char *reason) {
    if (!XLG1238Enabled() || !gXLG1238Writer) return;
    gXLG1238Writer(YES);
    NSLog(@"[XLiquidGlass] 3.0 Beta 1 gate=1 reason=%s", reason ?: "?");
}

static void XLG1238ImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)slide;

    const char *path = XLG1238ImageNameForHeader(header);
    if (!XLG1238IsXServiceLibraries(path)) return;
    if (!XLG1238HeaderMatchesUUID(header)) return;

    gXLG1238UUIDMatched = YES;

    // XServiceLibraries 12.38 has __TEXT vmaddr 0, so image header is its base.
    uintptr_t base = (uintptr_t)header;
    XLG1238WriterAddress resolved = {0};
    resolved.raw = base + kXLG1238WriterOffset;
    gXLG1238Writer = resolved.fn;

    XLG1238ApplyWriter("dyld-image-added");
}

__attribute__((constructor))
static void XLG1238EarlyConstructor(void) {
    _dyld_register_func_for_add_image(XLG1238ImageAdded);
    XLG1238ApplyWriter("constructor-after-register");
}

static void XLG1238GateHook(id self, SEL _cmd, id account) {
    XLG1238ApplyWriter("before-installGateForAccount");

    if (gXLG1238OrigGate) {
        ((void (*)(id, SEL, id))gXLG1238OrigGate)(self, _cmd, account);
    }

    XLG1238ApplyWriter("after-installGateForAccount");
}

static void XLG1238TabLoadViewHook(id self, SEL _cmd) {
    XLG1238ApplyWriter("before-T1TabBarViewController-loadView");

    if (gXLG1238OrigLoadView) {
        ((void (*)(id, SEL))gXLG1238OrigLoadView)(self, _cmd);
    }

    XLG1238ApplyWriter("after-T1TabBarViewController-loadView");
}

static void XLG1238InstallGateHook(void) {
    if (gXLG1238GateHooked) return;

    Class cls = NSClassFromString(@"T1LiquidGlassGateInstaller");
    if (!cls) return;

    SEL sel = NSSelectorFromString(@"installGateForAccount:");
    Method method = class_getClassMethod(cls, sel);
    if (!method) return;

    Class meta = object_getClass(cls);
    IMP current = class_getMethodImplementation(meta, sel);
    if (current == (IMP)XLG1238GateHook) {
        gXLG1238GateHooked = YES;
        return;
    }

    gXLG1238OrigGate = current;
    class_replaceMethod(meta, sel, (IMP)XLG1238GateHook, method_getTypeEncoding(method));
    gXLG1238GateHooked = class_getMethodImplementation(meta, sel) == (IMP)XLG1238GateHook;
}

static void XLG1238InstallTabHook(void) {
    if (gXLG1238TabHooked) return;

    Class cls = NSClassFromString(@"T1TabBarViewController");
    if (!cls) return;

    SEL sel = @selector(loadView);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;

    IMP current = class_getMethodImplementation(cls, sel);
    if (current == (IMP)XLG1238TabLoadViewHook) {
        gXLG1238TabHooked = YES;
        return;
    }

    gXLG1238OrigLoadView = current;
    class_replaceMethod(cls, sel, (IMP)XLG1238TabLoadViewHook, method_getTypeEncoding(method));
    gXLG1238TabHooked = class_getMethodImplementation(cls, sel) == (IMP)XLG1238TabLoadViewHook;
}

static void XLG1238InstallRuntimeGuards(void) {
    XLG1238InstallGateHook();
    XLG1238InstallTabHook();
    XLG1238ApplyWriter("runtime-guard-pass");
}

@interface XLG1238Bootstrap : NSObject
@end

@implementation XLG1238Bootstrap

+ (void)load {
    @autoreleasepool {
        NSLog(@"[XLiquidGlass] 3.0 Beta 1 target=X_12.38 pre-tabbar uuidMatch=%d enabled=%d",
              gXLG1238UUIDMatched ? 1 : 0,
              XLG1238Enabled() ? 1 : 0);

        XLG1238ApplyWriter("objc-load-sync");
        XLG1238InstallRuntimeGuards();

        NSArray<NSNumber *> *delays = @[
            @0.0, @0.01, @0.03, @0.06, @0.10,
            @0.20, @0.35, @0.50, @0.80, @1.20
        ];

        for (NSNumber *delay in delays) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    XLG1238InstallRuntimeGuards();
                }
            );
        }
    }
}

@end
