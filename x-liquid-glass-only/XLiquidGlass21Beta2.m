#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <stdint.h>
#import <string.h>

#pragma mark - XLiquidGlass 2.1 Beta 2 Collapse Classification Observer

static NSString *const kXLG21B2LogFileName=@"XLiquidGlass21Beta2.log";
static NSMutableDictionary<NSString *,NSString *> *gXLG21B2LastEngineSnapshots;
static dispatch_source_t gXLG21B2Timer;
static BOOL gXLG21B2DumpedEngineMethods=NO;

static IMP gHomeSupports=NULL;
static IMP gHomePinned=NULL;
static IMP gHomeManual=NULL;
static IMP gHomeExpandedBottom=NULL;
static IMP gSettingsSupports=NULL;
static IMP gSettingsPinned=NULL;
static IMP gSettingsManual=NULL;
static IMP gSettingsExpandedBottom=NULL;

static BOOL gHomeSupportsHooked=NO;
static BOOL gHomePinnedHooked=NO;
static BOOL gHomeManualHooked=NO;
static BOOL gHomeExpandedBottomHooked=NO;
static BOOL gSettingsSupportsHooked=NO;
static BOOL gSettingsPinnedHooked=NO;
static BOOL gSettingsManualHooked=NO;
static BOOL gSettingsExpandedBottomHooked=NO;

static NSString *XLG21B2LogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            [@"Documents" stringByAppendingPathComponent:kXLG21B2LogFileName]];
}

static void XLG21B2Log(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args,format);
    NSString *message=[[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *formatter=[[NSDateFormatter alloc] init];
    formatter.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat=@"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *stamp=[formatter stringFromDate:[NSDate date]] ?: @"-";

    NSString *line=[NSString stringWithFormat:@"[%@] %@\n",stamp,message ?: @""];
    NSLog(@"[XLiquidGlass 2.1 Beta 2] %@",message ?: @"");

    NSData *data=[line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path=XLG21B2LogPath();

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

static Ivar XLG21B2FindIvarInHierarchy(Class cls,const char *name) {
    for (Class current=cls; current && current!=NSObject.class;
         current=class_getSuperclass(current)) {
        Ivar ivar=class_getInstanceVariable(current,name);
        if (ivar) return ivar;
    }
    return NULL;
}

static uint64_t XLG21B2ReadRaw64(id object,const char *ivarName) {
    if (!object || !ivarName) return 0;
    Ivar ivar=XLG21B2FindIvarInHierarchy(object_getClass(object),ivarName);
    if (!ivar) return 0;

    ptrdiff_t offset=ivar_getOffset(ivar);
    uint64_t value=0;
    const uint8_t *base=(const uint8_t *)(__bridge const void *)object;
    memcpy(&value,base+offset,sizeof(value));
    return value;
}

static uint64_t XLG21B2ReadRaw64AtOffset(id object,const char *ivarName,ptrdiff_t extra) {
    if (!object || !ivarName) return 0;
    Ivar ivar=XLG21B2FindIvarInHierarchy(object_getClass(object),ivarName);
    if (!ivar) return 0;

    ptrdiff_t offset=ivar_getOffset(ivar)+extra;
    uint64_t value=0;
    const uint8_t *base=(const uint8_t *)(__bridge const void *)object;
    memcpy(&value,base+offset,sizeof(value));
    return value;
}

static double XLG21B2DoubleFromRaw(uint64_t raw) {
    double value=0.0;
    memcpy(&value,&raw,sizeof(value));
    return value;
}

static NSArray<UIWindow *> *XLG21B2Windows(void) {
    NSMutableArray<UIWindow *> *windows=[NSMutableArray array];

    UIApplication *app=UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene=(UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window) [windows addObject:window];
        }
    }

    return windows;
}

static NSString *XLG21B2ControllerLabelForPointer(UIWindow *window,uint64_t raw) {
    if (!window || raw==0 || !window.rootViewController) return @"-";

    NSMutableArray<UIViewController *> *queue=
        [NSMutableArray arrayWithObject:window.rootViewController];
    NSMutableSet<NSValue *> *visited=[NSMutableSet set];

    for (NSUInteger i=0;i<queue.count && i<320;i++) {
        UIViewController *vc=queue[i];
        NSValue *token=[NSValue valueWithNonretainedObject:vc];
        if ([visited containsObject:token]) continue;
        [visited addObject:token];

        if ((uint64_t)(uintptr_t)(__bridge void *)vc==raw) {
            return [NSString stringWithFormat:@"%@[%@]@%p",
                    NSStringFromClass(vc.class),
                    vc.title ?: @"-",
                    vc];
        }

        if (vc.presentedViewController) {
            [queue addObject:vc.presentedViewController];
        }
        [queue addObjectsFromArray:vc.childViewControllers ?: @[]];
    }

    return @"-";
}

static NSString *XLG21B2VisibleControllerChain(UIWindow *window) {
    if (!window || !window.rootViewController) return @"-";

    NSMutableArray<NSString *> *labels=[NSMutableArray array];
    NSMutableArray<UIViewController *> *queue=
        [NSMutableArray arrayWithObject:window.rootViewController];
    NSMutableSet<NSValue *> *visited=[NSMutableSet set];

    for (NSUInteger i=0;i<queue.count && i<320;i++) {
        UIViewController *vc=queue[i];
        NSValue *token=[NSValue valueWithNonretainedObject:vc];
        if ([visited containsObject:token]) continue;
        [visited addObject:token];

        BOOL visible=(vc==window.rootViewController) ||
            (vc.isViewLoaded && vc.view.window==window);
        if (visible) {
            [labels addObject:[NSString stringWithFormat:@"%@[%@]@%p",
                               NSStringFromClass(vc.class),
                               vc.title ?: @"-",
                               vc]];
        }

        if (vc.presentedViewController) {
            [queue addObject:vc.presentedViewController];
        }
        [queue addObjectsFromArray:vc.childViewControllers ?: @[]];
    }

    return labels.count ? [labels componentsJoinedByString:@" > "] : @"-";
}

static id XLG21B2CollapseEngineForNavigationController(UIViewController *controller) {
    if (!controller) return nil;
    if (![NSStringFromClass(controller.class)
          isEqualToString:@"XNavigation.NavigationController"]) {
        return nil;
    }

    Ivar engineIvar=XLG21B2FindIvarInHierarchy(
        controller.class,
        "$__lazy_storage_$_collapseEngine");
    if (!engineIvar) return nil;

    @try {
        return object_getIvar(controller,engineIvar);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void XLG21B2DumpEngineMethodsIfNeeded(id engine) {
    if (!engine || gXLG21B2DumpedEngineMethods) return;
    gXLG21B2DumpedEngineMethods=YES;

    Class cls=object_getClass(engine);
    unsigned int count=0;
    Method *methods=class_copyMethodList(cls,&count);

    XLG21B2Log(@"ENGINE_CLASS class=%@ ptr=%p directMethodCount=%u",
               NSStringFromClass(cls),engine,count);

    for (unsigned int i=0;i<count;i++) {
        SEL sel=method_getName(methods[i]);
        const char *types=method_getTypeEncoding(methods[i]);
        XLG21B2Log(@"ENGINE_METHOD selector=%@ types=%s imp=%p",
                   NSStringFromSelector(sel),
                   types ?: "-",
                   method_getImplementation(methods[i]));
    }

    free(methods);

    unsigned int ivarCount=0;
    Ivar *ivars=class_copyIvarList(cls,&ivarCount);
    XLG21B2Log(@"ENGINE_IVAR_COUNT count=%u",ivarCount);

    for (unsigned int i=0;i<ivarCount;i++) {
        const char *name=ivar_getName(ivars[i]);
        const char *type=ivar_getTypeEncoding(ivars[i]);
        XLG21B2Log(@"ENGINE_IVAR name=%s type=%s offset=%td",
                   name ?: "-",
                   type ?: "-",
                   ivar_getOffset(ivars[i]));
    }

    free(ivars);
}

static void XLG21B2ObserveEngine(id engine,UIWindow *window) {
    if (!engine || !window) return;

    XLG21B2DumpEngineMethodsIfNeeded(engine);

    uint64_t policy=XLG21B2ReadRaw64(engine,"policy");
    uint64_t hidden=XLG21B2ReadRaw64(engine,"hiddenBarTravel");
    uint64_t memory=XLG21B2ReadRaw64(engine,"progressMemory");
    uint64_t governed=XLG21B2ReadRaw64(engine,"governedScreen");
    uint64_t target0=XLG21B2ReadRaw64(engine,"pendingTarget");
    uint64_t target1=XLG21B2ReadRaw64AtOffset(engine,"pendingTarget",8);
    uint64_t lastUndeclared=XLG21B2ReadRaw64(engine,"lastLoggedUndeclaredScreen");
    uint64_t pendingUndeclared=XLG21B2ReadRaw64(engine,"pendingUndeclaredVerdict");
    uint64_t progress=XLG21B2ReadRaw64(engine,"collapseProgress");

    NSString *governedLabel=XLG21B2ControllerLabelForPointer(window,governed);
    NSString *pendingLabel=XLG21B2ControllerLabelForPointer(window,pendingUndeclared);
    NSString *lastUndeclaredLabel=XLG21B2ControllerLabelForPointer(window,lastUndeclared);

    NSString *snapshot=[NSString stringWithFormat:
        @"policy=%016llx hidden=%016llx memory=%016llx governed=%016llx target0=%016llx target1=%016llx lastUnd=%016llx pendingUnd=%016llx progress=%016llx",
        (unsigned long long)policy,
        (unsigned long long)hidden,
        (unsigned long long)memory,
        (unsigned long long)governed,
        (unsigned long long)target0,
        (unsigned long long)target1,
        (unsigned long long)lastUndeclared,
        (unsigned long long)pendingUndeclared,
        (unsigned long long)progress];

    NSString *key=[NSString stringWithFormat:@"%p",engine];
    NSString *previous=gXLG21B2LastEngineSnapshots[key];
    if ([previous isEqualToString:snapshot]) return;

    gXLG21B2LastEngineSnapshots[key]=snapshot;

    XLG21B2Log(
        @"ENGINE_STATE engine=%p policyRaw=0x%016llx policyDouble=%.6f hiddenBarTravel=%.6f progressMemoryRaw=0x%016llx governedScreen=0x%016llx governed=%@ pendingTarget={0x%016llx,0x%016llx} lastLoggedUndeclaredScreen=0x%016llx lastUndeclared=%@ pendingUndeclaredVerdict=0x%016llx pendingUndeclared=%@ collapseProgress=%.6f",
        engine,
        (unsigned long long)policy,
        XLG21B2DoubleFromRaw(policy),
        XLG21B2DoubleFromRaw(hidden),
        (unsigned long long)memory,
        (unsigned long long)governed,
        governedLabel,
        (unsigned long long)target0,
        (unsigned long long)target1,
        (unsigned long long)lastUndeclared,
        lastUndeclaredLabel,
        (unsigned long long)pendingUndeclared,
        pendingLabel,
        XLG21B2DoubleFromRaw(progress));

    XLG21B2Log(@"SCREEN_CHAIN %@",XLG21B2VisibleControllerChain(window));
}

static void XLG21B2Sample(void) {
    for (UIWindow *window in XLG21B2Windows()) {
        if (!window || window.hidden || !window.rootViewController) continue;

        NSMutableArray<UIViewController *> *queue=
            [NSMutableArray arrayWithObject:window.rootViewController];
        NSMutableSet<NSValue *> *visited=[NSMutableSet set];

        for (NSUInteger i=0;i<queue.count && i<320;i++) {
            UIViewController *vc=queue[i];
            NSValue *token=[NSValue valueWithNonretainedObject:vc];
            if ([visited containsObject:token]) continue;
            [visited addObject:token];

            if (vc==window.rootViewController ||
                (vc.isViewLoaded && vc.view.window==window)) {
                id engine=XLG21B2CollapseEngineForNavigationController(vc);
                if (engine) XLG21B2ObserveEngine(engine,window);
            }

            if (vc.presentedViewController) {
                [queue addObject:vc.presentedViewController];
            }
            [queue addObjectsFromArray:vc.childViewControllers ?: @[]];
        }
    }
}

static BOOL XLG21B2CallBool(IMP imp,id self,SEL cmd) {
    return imp ? ((BOOL(*)(id,SEL))imp)(self,cmd) : NO;
}

static BOOL XLG21B2HomeSupports(id self,SEL cmd) {
    BOOL value=XLG21B2CallBool(gHomeSupports,self,cmd);
    XLG21B2Log(@"CAPABILITY_CALL screen=Home selector=%@ value=%d object=%p",
               NSStringFromSelector(cmd),value,self);
    return value;
}
static BOOL XLG21B2HomePinned(id self,SEL cmd) {
    BOOL value=XLG21B2CallBool(gHomePinned,self,cmd);
    XLG21B2Log(@"CAPABILITY_CALL screen=Home selector=%@ value=%d object=%p",
               NSStringFromSelector(cmd),value,self);
    return value;
}
static BOOL XLG21B2HomeManual(id self,SEL cmd) {
    BOOL value=XLG21B2CallBool(gHomeManual,self,cmd);
    XLG21B2Log(@"CAPABILITY_CALL screen=Home selector=%@ value=%d object=%p",
               NSStringFromSelector(cmd),value,self);
    return value;
}
static BOOL XLG21B2HomeExpandedBottom(id self,SEL cmd) {
    BOOL value=XLG21B2CallBool(gHomeExpandedBottom,self,cmd);
    XLG21B2Log(@"CAPABILITY_CALL screen=Home selector=%@ value=%d object=%p",
               NSStringFromSelector(cmd),value,self);
    return value;
}
static BOOL XLG21B2SettingsSupports(id self,SEL cmd) {
    BOOL value=XLG21B2CallBool(gSettingsSupports,self,cmd);
    XLG21B2Log(@"CAPABILITY_CALL screen=Settings selector=%@ value=%d object=%p",
               NSStringFromSelector(cmd),value,self);
    return value;
}
static BOOL XLG21B2SettingsPinned(id self,SEL cmd) {
    BOOL value=XLG21B2CallBool(gSettingsPinned,self,cmd);
    XLG21B2Log(@"CAPABILITY_CALL screen=Settings selector=%@ value=%d object=%p",
               NSStringFromSelector(cmd),value,self);
    return value;
}
static BOOL XLG21B2SettingsManual(id self,SEL cmd) {
    BOOL value=XLG21B2CallBool(gSettingsManual,self,cmd);
    XLG21B2Log(@"CAPABILITY_CALL screen=Settings selector=%@ value=%d object=%p",
               NSStringFromSelector(cmd),value,self);
    return value;
}
static BOOL XLG21B2SettingsExpandedBottom(id self,SEL cmd) {
    BOOL value=XLG21B2CallBool(gSettingsExpandedBottom,self,cmd);
    XLG21B2Log(@"CAPABILITY_CALL screen=Settings selector=%@ value=%d object=%p",
               NSStringFromSelector(cmd),value,self);
    return value;
}

static BOOL XLG21B2InstallBoolHook(
    Class cls,
    NSString *selectorName,
    IMP replacement,
    IMP *original,
    BOOL *installed,
    NSString *screenLabel) {

    if (!cls || !selectorName || !replacement || !original || !installed) return NO;
    if (*installed) return YES;

    SEL sel=NSSelectorFromString(selectorName);
    Method method=class_getInstanceMethod(cls,sel);
    if (!method) return NO;

    IMP current=class_getMethodImplementation(cls,sel);
    if (current==replacement) {
        *installed=YES;
        return YES;
    }

    const char *types=method_getTypeEncoding(method);
    if (!types) return NO;

    *original=current;
    class_replaceMethod(cls,sel,replacement,types);
    *installed=(class_getMethodImplementation(cls,sel)==replacement);

    if (*installed) {
        XLG21B2Log(@"CAPABILITY_HOOK screen=%@ class=%@ selector=%@ original=%p replacement=%p",
                   screenLabel,
                   NSStringFromClass(cls),
                   selectorName,
                   current,
                   replacement);
    }

    return *installed;
}

static void XLG21B2InstallCapabilityHooks(void) {
    Class home=NSClassFromString(
        @"TwitterHomeFeatureImplementation.HomeTimelineContainerViewController");
    Class settings=NSClassFromString(@"T1GenericSettingsViewController");

    if (home) {
        XLG21B2InstallBoolHook(home,@"tfn_supportsTabBarCollapsing",
            (IMP)XLG21B2HomeSupports,&gHomeSupports,&gHomeSupportsHooked,@"Home");
        XLG21B2InstallBoolHook(home,@"tfn_prefersTabBarPinned",
            (IMP)XLG21B2HomePinned,&gHomePinned,&gHomePinnedHooked,@"Home");
        XLG21B2InstallBoolHook(home,@"tfn_preferManualNavBarCollapse",
            (IMP)XLG21B2HomeManual,&gHomeManual,&gHomeManualHooked,@"Home");
        XLG21B2InstallBoolHook(home,@"prefersNavigationBarExpandedWhenScrolledToBottom",
            (IMP)XLG21B2HomeExpandedBottom,&gHomeExpandedBottom,
            &gHomeExpandedBottomHooked,@"Home");
    }

    if (settings) {
        XLG21B2InstallBoolHook(settings,@"tfn_supportsTabBarCollapsing",
            (IMP)XLG21B2SettingsSupports,&gSettingsSupports,
            &gSettingsSupportsHooked,@"Settings");
        XLG21B2InstallBoolHook(settings,@"tfn_prefersTabBarPinned",
            (IMP)XLG21B2SettingsPinned,&gSettingsPinned,
            &gSettingsPinnedHooked,@"Settings");
        XLG21B2InstallBoolHook(settings,@"tfn_preferManualNavBarCollapse",
            (IMP)XLG21B2SettingsManual,&gSettingsManual,
            &gSettingsManualHooked,@"Settings");
        XLG21B2InstallBoolHook(settings,@"prefersNavigationBarExpandedWhenScrolledToBottom",
            (IMP)XLG21B2SettingsExpandedBottom,&gSettingsExpandedBottom,
            &gSettingsExpandedBottomHooked,@"Settings");
    }
}

static void XLG21B2StartTimer(void) {
    if (gXLG21B2Timer) return;

    dispatch_queue_t queue=dispatch_get_main_queue();
    gXLG21B2Timer=dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);

    dispatch_source_set_timer(
        gXLG21B2Timer,
        dispatch_time(DISPATCH_TIME_NOW,0),
        (uint64_t)(0.05*NSEC_PER_SEC),
        (uint64_t)(0.01*NSEC_PER_SEC));

    dispatch_source_set_event_handler(gXLG21B2Timer,^{
        XLG21B2InstallCapabilityHooks();
        XLG21B2Sample();
    });

    dispatch_resume(gXLG21B2Timer);
}

__attribute__((constructor))
static void XLiquidGlass21Beta2Init(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager] removeItemAtPath:XLG21B2LogPath()
                                                   error:nil];

        gXLG21B2LastEngineSnapshots=[NSMutableDictionary dictionary];

        XLG21B2Log(@"========== XLiquidGlass 2.1 Beta 2 Collapse Classification Observer ==========");
        XLG21B2Log(@"BASE commit=622de1df3306264894ff5ce9f31a9e882fa34e98");
        XLG21B2Log(@"MODE observation-only automatic-sampling=50ms no-gesture-arming");
        XLG21B2Log(@"GUARD no-capability-forcing no-tabbar-transform-writes no-collapse-engine-ivar-writes no-beta8-11-autohide");

        dispatch_async(dispatch_get_main_queue(),^{
            XLG21B2InstallCapabilityHooks();
            XLG21B2StartTimer();
        });
    }
}
