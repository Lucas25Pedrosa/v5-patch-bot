#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>

#pragma mark - XLiquidGlass 2.1 Beta 3 Search native collapse declaration

static BOOL gXLG21B3Installed=NO;
static IMP gXLG21B3OrigSearchViewDidAppear=NULL;

static NSString *XLG21B3LogPath(void) {
    NSString *documents=NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    if (!documents.length) documents=NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:@"XLiquidGlass21Beta3.log"];
}

static void XLG21B3Log(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args,format);
    NSString *message=[[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line=[NSString stringWithFormat:@"[%@] %@\n",[NSDate date],message ?: @""];
    NSLog(@"[XLiquidGlass 2.1 Beta 3] %@",message ?: @"");

    NSData *data=[line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path=XLG21B3LogPath();

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

static NSString *XLG21B3SymbolForIMP(IMP imp) {
    if (!imp) return @"-";
    Dl_info info={0};
    if (dladdr((const void *)imp,&info)==0) return @"-";

    NSString *image=
        info.dli_fname ? [NSString stringWithUTF8String:info.dli_fname] : @"-";
    NSString *symbol=
        info.dli_sname ? [NSString stringWithUTF8String:info.dli_sname] : @"-";

    return [NSString stringWithFormat:@"%@ | %@",image,symbol];
}

static BOOL XLG21B3ClassDeclaresSelector(Class cls,SEL sel) {
    if (!cls || !sel) return NO;

    unsigned int count=0;
    Method *methods=class_copyMethodList(cls,&count);
    BOOL found=NO;

    for (unsigned int i=0;i<count;i++) {
        if (method_getName(methods[i])==sel) {
            found=YES;
            break;
        }
    }

    free(methods);
    return found;
}

static BOOL XLG21B3AddReadonlyBoolProperty(Class cls,const char *name) {
    if (!cls || !name) return NO;

    objc_property_attribute_t attrs[]={
        {"T","B"},
        {"N",""},
        {"R",""}
    };

    BOOL added=class_addProperty(cls,name,attrs,3);
    objc_property_t property=class_getProperty(cls,name);

    XLG21B3Log(@"PROPERTY_DECLARE class=%@ name=%s added=%d present=%d",
               NSStringFromClass(cls),
               name,
               added,
               property!=NULL);

    return property!=NULL;
}

static BOOL XLG21B3CopyHomeCapabilityToSearch(
    Class home,
    Class search,
    NSString *selectorName) {

    SEL sel=NSSelectorFromString(selectorName);
    Method homeMethod=class_getInstanceMethod(home,sel);
    Method searchMethod=class_getInstanceMethod(search,sel);

    if (!homeMethod || !searchMethod) {
        XLG21B3Log(@"CAPABILITY_COPY selector=%@ success=0 reason=method-missing home=%p search=%p",
                   selectorName,
                   homeMethod,
                   searchMethod);
        return NO;
    }

    const char *homeTypes=method_getTypeEncoding(homeMethod);
    const char *searchTypes=method_getTypeEncoding(searchMethod);
    IMP homeIMP=method_getImplementation(homeMethod);
    IMP inheritedSearchIMP=method_getImplementation(searchMethod);

    if (!homeTypes || !searchTypes || strcmp(homeTypes,searchTypes)!=0) {
        XLG21B3Log(@"CAPABILITY_COPY selector=%@ success=0 reason=encoding-mismatch homeTypes=%s searchTypes=%s",
                   selectorName,
                   homeTypes ?: "-",
                   searchTypes ?: "-");
        return NO;
    }

    BOOL alreadyDirect=XLG21B3ClassDeclaresSelector(search,sel);
    BOOL added=NO;

    if (!alreadyDirect) {
        added=class_addMethod(search,sel,homeIMP,homeTypes);
    }

    IMP finalIMP=class_getMethodImplementation(search,sel);
    BOOL direct=XLG21B3ClassDeclaresSelector(search,sel);
    BOOL success=direct && finalIMP==homeIMP;

    XLG21B3Log(
        @"CAPABILITY_COPY selector=%@ success=%d alreadyDirect=%d added=%d directNow=%d inheritedSearchIMP=%p homeIMP=%p finalIMP=%p homeSymbol=%@",
        selectorName,
        success,
        alreadyDirect,
        added,
        direct,
        inheritedSearchIMP,
        homeIMP,
        finalIMP,
        XLG21B3SymbolForIMP(homeIMP));

    return success;
}

static void XLG21B3RequestNativeConfigurationRefresh(id controller) {
    if (!controller) return;

    SEL xnav=NSSelectorFromString(@"xnav_setNeedsNavigationConfigurationUpdateAnimated:");
    if ([controller respondsToSelector:xnav]) {
        ((void(*)(id,SEL,BOOL))objc_msgSend)(controller,xnav,NO);
        XLG21B3Log(@"REFRESH object=%p class=%@ selector=%@",
                   controller,
                   NSStringFromClass([controller class]),
                   NSStringFromSelector(xnav));
    }

    SEL tabStyle=NSSelectorFromString(@"tfn_setNeedsTabBarStyleOverridesUpdate");
    if ([controller respondsToSelector:tabStyle]) {
        ((void(*)(id,SEL))objc_msgSend)(controller,tabStyle);
        XLG21B3Log(@"REFRESH object=%p class=%@ selector=%@",
                   controller,
                   NSStringFromClass([controller class]),
                   NSStringFromSelector(tabStyle));
    }

    SEL navExpansion=NSSelectorFromString(@"tfn_setNeedsNavigationBarExpansionUpdate");
    if ([controller respondsToSelector:navExpansion]) {
        ((void(*)(id,SEL))objc_msgSend)(controller,navExpansion);
        XLG21B3Log(@"REFRESH object=%p class=%@ selector=%@",
                   controller,
                   NSStringFromClass([controller class]),
                   NSStringFromSelector(navExpansion));
    }
}

static void XLG21B3SearchViewDidAppear(id self,SEL cmd,BOOL animated) {
    if (gXLG21B3OrigSearchViewDidAppear) {
        ((void(*)(id,SEL,BOOL))gXLG21B3OrigSearchViewDidAppear)(self,cmd,animated);
    }

    XLG21B3Log(@"SEARCH_APPEARED object=%p class=%@",
               self,
               NSStringFromClass([self class]));

    XLG21B3RequestNativeConfigurationRefresh(self);

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.15*NSEC_PER_SEC)),
        dispatch_get_main_queue(),^{
            XLG21B3RequestNativeConfigurationRefresh(self);
        });
}

static BOOL XLG21B3InstallSearchViewDidAppearHook(Class search) {
    SEL sel=@selector(viewDidAppear:);
    Method method=class_getInstanceMethod(search,sel);
    if (!method) return NO;

    const char *types=method_getTypeEncoding(method);
    if (!types) return NO;

    IMP current=class_getMethodImplementation(search,sel);
    if (current==(IMP)XLG21B3SearchViewDidAppear) return YES;

    gXLG21B3OrigSearchViewDidAppear=current;

    BOOL direct=XLG21B3ClassDeclaresSelector(search,sel);
    BOOL installed=NO;

    if (direct) {
        class_replaceMethod(search,sel,(IMP)XLG21B3SearchViewDidAppear,types);
        installed=
            class_getMethodImplementation(search,sel)==
            (IMP)XLG21B3SearchViewDidAppear;
    } else {
        installed=class_addMethod(
            search,
            sel,
            (IMP)XLG21B3SearchViewDidAppear,
            types);
    }

    XLG21B3Log(@"VIEW_HOOK class=%@ selector=viewDidAppear: success=%d original=%p",
               NSStringFromClass(search),
               installed,
               current);

    return installed;
}

static void XLG21B3Install(void) {
    if (gXLG21B3Installed) return;

    Class home=NSClassFromString(
        @"TwitterHomeFeatureImplementation.HomeTimelineContainerViewController");
    Class search=NSClassFromString(@"TTSSearchContainerViewControllerV2");

    if (!home || !search) {
        XLG21B3Log(@"INSTALL_WAIT home=%p search=%p",home,search);
        return;
    }

    NSArray<NSString *> *selectors=@[
        @"tfn_supportsTabBarCollapsing",
        @"tfn_prefersTabBarPinned",
        @"tfn_preferManualNavBarCollapse"
    ];

    BOOL methodsOK=YES;
    for (NSString *selectorName in selectors) {
        methodsOK &=
            XLG21B3CopyHomeCapabilityToSearch(home,search,selectorName);
    }

    BOOL propertiesOK=YES;
    propertiesOK &= XLG21B3AddReadonlyBoolProperty(
        search,"tfn_supportsTabBarCollapsing");
    propertiesOK &= XLG21B3AddReadonlyBoolProperty(
        search,"tfn_prefersTabBarPinned");
    propertiesOK &= XLG21B3AddReadonlyBoolProperty(
        search,"tfn_preferManualNavBarCollapse");

    BOOL viewHookOK=XLG21B3InstallSearchViewDidAppearHook(search);

    gXLG21B3Installed=methodsOK && propertiesOK && viewHookOK;

    XLG21B3Log(
        @"INSTALL_RESULT success=%d methods=%d properties=%d viewHook=%d home=%@ search=%@",
        gXLG21B3Installed,
        methodsOK,
        propertiesOK,
        viewHookOK,
        NSStringFromClass(home),
        NSStringFromClass(search));
}

static void XLG21B3Retry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),
        dispatch_get_main_queue(),^{
            XLG21B3Install();
        });
}

__attribute__((constructor))
static void XLiquidGlass21Beta3Init(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager] removeItemAtPath:XLG21B3LogPath()
                                                   error:nil];

        XLG21B3Log(@"========== XLiquidGlass 2.1 Beta 3 Search Native Collapse ==========");
        XLG21B3Log(@"BASE commit=622de1df3306264894ff5ce9f31a9e882fa34e98");
        XLG21B3Log(@"TARGET class=TTSSearchContainerViewControllerV2 source=TwitterHomeFeatureImplementation.HomeTimelineContainerViewController");
        XLG21B3Log(@"METHODS tfn_supportsTabBarCollapsing,tfn_prefersTabBarPinned,tfn_preferManualNavBarCollapse");
        XLG21B3Log(@"GUARD no-tabbar-transform-writes no-collapse-engine-ivar-writes no-manual-animation");

        XLG21B3Install();
        XLG21B3Retry(0.05);
        XLG21B3Retry(0.20);
        XLG21B3Retry(0.50);
        XLG21B3Retry(1.00);
        XLG21B3Retry(2.00);
        XLG21B3Retry(4.00);
    }
}
