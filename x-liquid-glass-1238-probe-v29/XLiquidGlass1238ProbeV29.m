#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *const kVersion = @"2.9";
static const uintptr_t kExpectedEnabledGetterOffset = 0x21079dc;
static const uintptr_t kRedesignGateWriterOffset = 0x2107b34;

typedef void (*XLGRedesignGateWriter)(BOOL);
typedef union {
    uintptr_t raw;
    XLGRedesignGateWriter fn;
} XLGWriterAddress;

static void ApplyEarlyGate(NSString *reason) {
    Class c = NSClassFromString(@"XAppearance.Appearance");
    if (!c) {
        NSLog(@"[XLiquidGlass1238ProbeV29] APPLY reason=%@ class=0", reason);
        return;
    }

    SEL s = NSSelectorFromString(@"isLiquidGlassEnabled");
    Method m = class_getClassMethod(c, s);
    if (!m) {
        NSLog(@"[XLiquidGlass1238ProbeV29] APPLY reason=%@ class=1 getter=0", reason);
        return;
    }

    IMP imp = method_getImplementation(m);
    Dl_info info = {0};
    if (!dladdr((const void *)imp, &info) || !info.dli_fbase) {
        NSLog(@"[XLiquidGlass1238ProbeV29] APPLY reason=%@ dladdr=0", reason);
        return;
    }

    uintptr_t offset = (uintptr_t)imp - (uintptr_t)info.dli_fbase;
    NSString *image = info.dli_fname ? [[NSString stringWithUTF8String:info.dli_fname] lastPathComponent] : @"?";
    BOOL buildMatch = [image isEqualToString:@"XServiceLibraries"] && offset == kExpectedEnabledGetterOffset;

    BOOL before = ((BOOL(*)(id,SEL))imp)(c, s);
    BOOL after = before;

    uintptr_t writerAddress = (uintptr_t)info.dli_fbase + kRedesignGateWriterOffset;
    XLGWriterAddress resolved = {0};
    resolved.raw = writerAddress;
    XLGRedesignGateWriter writer = resolved.fn;

    if (buildMatch && writer) {
        writer(YES);
        after = ((BOOL(*)(id,SEL))imp)(c, s);
    }

    NSLog(@"[XLiquidGlass1238ProbeV29] APPLY reason=%@ image=%@ getterOffset=0x%llx buildMatch=%d writer=%d before=%d after=%d",
          reason,
          image,
          (unsigned long long)offset,
          buildMatch ? 1 : 0,
          writer ? 1 : 0,
          before ? 1 : 0,
          after ? 1 : 0);
}

@interface XLGV29Bootstrap : NSObject
@end

@implementation XLGV29Bootstrap

+ (void)load {
    @autoreleasepool {
        NSLog(@"[XLiquidGlass1238ProbeV29] NEW_SESSION version=%@ target=X_12.38 mode=EARLY_GATE bootstrap=+load", kVersion);

        ApplyEarlyGate(@"load-sync");

        NSArray<NSNumber *> *delays = @[@0.0, @0.01, @0.03, @0.06, @0.10, @0.20, @0.35, @0.50];
        for (NSNumber *delay in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                ApplyEarlyGate([NSString stringWithFormat:@"retry-%.2f", delay.doubleValue]);
            });
        }
    }
}

@end
