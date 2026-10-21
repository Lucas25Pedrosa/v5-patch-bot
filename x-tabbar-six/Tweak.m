#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSInteger XTSix(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return 6;
}

__attribute__((constructor))
static void XTSixInit(void) {
    @autoreleasepool {
        Class cls = NSClassFromString(@"T1BottomTabBarItemCapacity");
        if (!cls) cls = objc_getClass("T1BottomTabBarItemCapacity");
        if (!cls) {
            NSLog(@"[XTabBarSix] T1BottomTabBarItemCapacity not found");
            return;
        }

        Class meta = object_getClass(cls);
        SEL compactSel = NSSelectorFromString(@"compact");
        Method method = class_getClassMethod(cls, compactSel);
        if (!method) {
            NSLog(@"[XTabBarSix] +compact not found");
            return;
        }

        const char *types = method_getTypeEncoding(method);
        if (!class_replaceMethod(meta, compactSel, (IMP)XTSix, types)) {
            method_setImplementation(method, (IMP)XTSix);
        }
        NSLog(@"[XTabBarSix] compact tab capacity forced to 6");
    }
}
