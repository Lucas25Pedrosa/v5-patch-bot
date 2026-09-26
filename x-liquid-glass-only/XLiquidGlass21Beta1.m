#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

#pragma mark - XLiquidGlass 2.1 Beta 1 native collapse gate

static IMP gXLG21OrigGenericSettingsSupportsTabBarCollapsing = NULL;
static BOOL gXLG21GenericSettingsCollapseHookInstalled = NO;
static char kXLG21LoggedCapabilityCallKey;

static NSString *XLG21LogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Documents/XLiquidGlass21Beta1.log"];
}

static void XLG21Log(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args, format);
    NSString *message =
        [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"[%@] %@\n",
         [NSDate date], message ?: @""];

    NSLog(@"[XLiquidGlass 2.1 Beta 1] %@", message ?: @"");

    NSData *data=[line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path=XLG21LogPath();

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *handle=[NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;

    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (__unused NSException *exception) {
    }

    @try {
        [handle closeFile];
    } @catch (__unused NSException *exception) {
    }
}

static BOOL XLG21LiquidGlassEnabled(void) {
    NSUserDefaults *defaults=[NSUserDefaults standardUserDefaults];
    id stored=[defaults objectForKey:@"XLiquidGlassEnabled"];
    return stored ? [stored boolValue] : YES;
}

static BOOL XLG21GenericSettingsSupportsTabBarCollapsing(id self, SEL cmd) {
    BOOL original=NO;

    if (gXLG21OrigGenericSettingsSupportsTabBarCollapsing) {
        original=
            ((BOOL(*)(id,SEL))
             gXLG21OrigGenericSettingsSupportsTabBarCollapsing)(self,cmd);
    }

    BOOL enabled=XLG21LiquidGlassEnabled();
    BOOL result=enabled ? YES : original;

    if (!objc_getAssociatedObject(self,&kXLG21LoggedCapabilityCallKey)) {
        objc_setAssociatedObject(
            self,
            &kXLG21LoggedCapabilityCallKey,
            @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        XLG21Log(
            @"CAPABILITY_CALL class=%@ ptr=%p selector=%@ original=%d xlgEnabled=%d returned=%d",
            NSStringFromClass([self class]),
            self,
            NSStringFromSelector(cmd),
            original,
            enabled,
            result);
    }

    return result;
}

static void XLG21InstallGenericSettingsCollapseGate(void) {
    if (gXLG21GenericSettingsCollapseHookInstalled) return;

    Class cls=NSClassFromString(@"T1GenericSettingsViewController");
    SEL sel=NSSelectorFromString(@"tfn_supportsTabBarCollapsing");

    if (!cls) return;

    Method method=class_getInstanceMethod(cls,sel);
    if (!method) {
        XLG21Log(
            @"HOOK_WAIT class=T1GenericSettingsViewController selector=tfn_supportsTabBarCollapsing reason=method-missing");
        return;
    }

    IMP current=class_getMethodImplementation(cls,sel);
    if (current==(IMP)XLG21GenericSettingsSupportsTabBarCollapsing) {
        gXLG21GenericSettingsCollapseHookInstalled=YES;
        return;
    }

    const char *types=method_getTypeEncoding(method);
    if (!types) {
        XLG21Log(
            @"HOOK_WAIT class=T1GenericSettingsViewController selector=tfn_supportsTabBarCollapsing reason=encoding-missing");
        return;
    }

    gXLG21OrigGenericSettingsSupportsTabBarCollapsing=current;

    class_replaceMethod(
        cls,
        sel,
        (IMP)XLG21GenericSettingsSupportsTabBarCollapsing,
        types);

    IMP installed=class_getMethodImplementation(cls,sel);
    gXLG21GenericSettingsCollapseHookInstalled=
        installed==(IMP)XLG21GenericSettingsSupportsTabBarCollapsing;

    XLG21Log(
        @"HOOK_INSTALL class=T1GenericSettingsViewController selector=tfn_supportsTabBarCollapsing success=%d original=%p replacement=%p",
        gXLG21GenericSettingsCollapseHookInstalled,
        gXLG21OrigGenericSettingsSupportsTabBarCollapsing,
        (IMP)XLG21GenericSettingsSupportsTabBarCollapsing);
}

static void XLG21ScheduleInstall(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(delay*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            XLG21InstallGenericSettingsCollapseGate();
        });
}

__attribute__((constructor))
static void XLiquidGlass21Beta1Init(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager] removeItemAtPath:XLG21LogPath()
                                                   error:nil];

        XLG21Log(
            @"========== XLiquidGlass 2.1 Beta 1 native collapse gate loaded ==========");
        XLG21Log(
            @"BASE commit=622de1df3306264894ff5ce9f31a9e882fa34e98");
        XLG21Log(
            @"EXPERIMENT controller=T1GenericSettingsViewController selector=tfn_supportsTabBarCollapsing forced=YES");
        XLG21Log(
            @"GUARD no-manual-tabbar-transform no-collapse-engine-ivar-writes no-beta8-11-autohide");

        XLG21InstallGenericSettingsCollapseGate();
        XLG21ScheduleInstall(0.00);
        XLG21ScheduleInstall(0.05);
        XLG21ScheduleInstall(0.20);
        XLG21ScheduleInstall(0.50);
        XLG21ScheduleInstall(1.00);
        XLG21ScheduleInstall(2.00);
        XLG21ScheduleInstall(4.00);
    }
}
