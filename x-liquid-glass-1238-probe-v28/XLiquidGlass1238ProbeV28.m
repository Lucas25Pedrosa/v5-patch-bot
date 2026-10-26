#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *const kVersion = @"2.8";
static const uintptr_t kExpectedEnabledGetterOffset = 0x21079dc;
static const uintptr_t kRedesignGateWriterOffset = 0x2107b34;

typedef void (*XLGRedesignGateWriter)(BOOL);

static void InspectAppearance(void) {
    Class c = NSClassFromString(@"XAppearance.Appearance");
    if (!c) {
        NSLog(@"[XLiquidGlass1238ProbeV28] RUNTIME class=0");
        return;
    }

    SEL s = NSSelectorFromString(@"isLiquidGlassEnabled");
    Method m = class_getClassMethod(c, s);
    if (!m) {
        NSLog(@"[XLiquidGlass1238ProbeV28] RUNTIME class=1 getter=0");
        return;
    }

    IMP imp = method_getImplementation(m);
    Dl_info info = {0};
    if (dladdr((const void *)imp, &info) && info.dli_fbase) {
        uintptr_t offset = (uintptr_t)imp - (uintptr_t)info.dli_fbase;
        NSString *image = info.dli_fname ? [[NSString stringWithUTF8String:info.dli_fname] lastPathComponent] : @"?";
        BOOL buildMatch = [image isEqualToString:@"XServiceLibraries"] && offset == kExpectedEnabledGetterOffset;
        uintptr_t writerAddress = (uintptr_t)info.dli_fbase + kRedesignGateWriterOffset;
        XLGRedesignGateWriter writer = NULL;
        NSLog(@"[XLiquidGlass1238ProbeV28] RUNTIME class=1 getter=1 image=%@ offset=0x%llx expected=0x%llx buildMatch=%d writerOffset=0x%llx writerAddress=0x%llx writer=%d",
              image,
              (unsigned long long)offset,
              (unsigned long long)kExpectedEnabledGetterOffset,
              buildMatch ? 1 : 0,
              (unsigned long long)kRedesignGateWriterOffset,
              (unsigned long long)writerAddress,
              writer ? 1 : 0);
    } else {
        NSLog(@"[XLiquidGlass1238ProbeV28] RUNTIME class=1 getter=1 image=? offset=?");
    }
}

@interface XLGV28Bootstrap : NSObject
@end

@implementation XLGV28Bootstrap

+ (void)load {
    @autoreleasepool {
        NSLog(@"[XLiquidGlass1238ProbeV28] NEW_SESSION version=%@ target=X_12.38 bootstrap=+load", kVersion);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            InspectAppearance();
        });
    }
}

@end
