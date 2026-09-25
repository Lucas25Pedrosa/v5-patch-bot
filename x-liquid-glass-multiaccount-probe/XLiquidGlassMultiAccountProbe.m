#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kMAPLogFileName = @"XLiquidGlassMultiAccountProbe.log";
static const NSUInteger kMAPMaxLogBytes = 4 * 1024 * 1024;

static NSString *gEventActiveUserID = nil;
static NSInteger gRootBadgeCount = -1;
static NSDictionary *gLastBadgeMap = nil;

static IMP gOrigActiveAccountDidChange = NULL;
static IMP gOrigAppAccountsDidChange = NULL;
static IMP gOrigTwitterAccountDidUpdate = NULL;
static IMP gOrigSetBadgeCountsForUserID = NULL;
static IMP gOrigUpdateBadgeCountFromNotification = NULL;
static IMP gOrigRootBadgeUpdate = NULL;
static IMP gOrigItemLayout = NULL;
static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;

static id gNotificationObserver = nil;
static NSString *gLastSnapshotSignature = nil;

#pragma mark - Log

static NSString *MAPLogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kMAPLogFileName];
}

static NSString *MAPStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:NSDate.date];
}

static NSString *MAPText(id value) {
    if (!value || value == NSNull.null) return @"-";
    NSString *text = [value description] ?: @"-";
    if (text.length > 1200) {
        text = [[text substringToIndex:1200] stringByAppendingString:@"…"];
    }
    return text.length ? text : @"-";
}

static void MAPTrimLog(void) {
    NSString *path = MAPLogPath();
    NSDictionary *attrs =
        [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size <= kMAPMaxLogBytes) return;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length <= kMAPMaxLogBytes) return;

    NSUInteger keep = kMAPMaxLogBytes / 2;
    NSData *tail =
        [data subdataWithRange:NSMakeRange(data.length - keep, keep)];
    [tail writeToFile:path atomically:YES];
}

static void MAPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void MAPLog(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *body =
        [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"[%@] %@\n", MAPStamp(), body ?: @""];
    NSLog(@"[XLiquidGlassMultiAccountProbe] %@", body ?: @"");

    @synchronized(NSFileManager.defaultManager) {
        NSString *path = MAPLogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [@"" writeToFile:path atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *handle =
            [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
        MAPTrimLog();
    }
}

#pragma mark - Safe runtime helpers

static id MAPSafeValue(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *MAPNormalizedUserID(id value) {
    if (!value || value == NSNull.null) return nil;
    if ([value isKindOfClass:NSString.class]) {
        return [(NSString *)value length] ? value : nil;
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *s = [value stringValue];
        return s.length ? s : nil;
    }
    NSString *s = [value description];
    return s.length ? s : nil;
}

static NSString *MAPResolveUserID(id object, NSUInteger depth) {
    if (!object || depth > 3) return nil;

    for (NSString *key in @[
        @"userID", @"userId", @"restID", @"restId",
        @"accountID", @"accountId", @"activeUserID",
        @"activeAccountID", @"currentUserID", @"currentAccountID"
    ]) {
        NSString *resolved = MAPNormalizedUserID(MAPSafeValue(object, key));
        if (resolved.length) return resolved;
    }

    for (NSString *key in @[@"account", @"currentAccount", @"activeAccount",
                             @"user", @"profile"]) {
        id nested = MAPSafeValue(object, key);
        if (!nested || nested == object) continue;
        NSString *resolved = MAPResolveUserID(nested, depth + 1);
        if (resolved.length) return resolved;
    }

    return nil;
}

static BOOL MAPReadInteger(id object, NSString *name, NSInteger *outValue) {
    if (!object || !name.length || !outValue) return NO;
    SEL sel = NSSelectorFromString(name);
    if ([object respondsToSelector:sel]) {
        NSMethodSignature *sig = [object methodSignatureForSelector:sel];
        const char *ret = sig.methodReturnType;
        if (ret) {
            switch (ret[0]) {
                case '@': {
                    id value = ((id(*)(id,SEL))objc_msgSend)(object, sel);
                    if ([value respondsToSelector:@selector(integerValue)]) {
                        *outValue = [value integerValue];
                        return YES;
                    }
                    break;
                }
                case 'q':
                    *outValue = (NSInteger)((long long(*)(id,SEL))objc_msgSend)(object, sel);
                    return YES;
                case 'Q':
                    *outValue = (NSInteger)((unsigned long long(*)(id,SEL))objc_msgSend)(object, sel);
                    return YES;
                case 'i':
                    *outValue = (NSInteger)((int(*)(id,SEL))objc_msgSend)(object, sel);
                    return YES;
                case 'I':
                    *outValue = (NSInteger)((unsigned int(*)(id,SEL))objc_msgSend)(object, sel);
                    return YES;
                default:
                    break;
            }
        }
    }

    id value = MAPSafeValue(object, name);
    if ([value respondsToSelector:@selector(integerValue)]) {
        *outValue = [value integerValue];
        return YES;
    }
    return NO;
}

static BOOL MAPReadCount(id object, NSString *base, NSInteger *outValue) {
    if (MAPReadInteger(object, [base stringByAppendingString:@"Number"], outValue))
        return YES;
    return MAPReadInteger(object, base, outValue);
}

static BOOL MAPHookInstanceMethod(Class cls, SEL sel, IMP replacement, IMP *original) {
    if (!cls || !sel || !replacement) return NO;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP current = class_getMethodImplementation(cls, sel);
    if (current == replacement) return YES;
    if (original && !*original) *original = current;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;
    class_replaceMethod(cls, sel, replacement, types);
    return class_getMethodImplementation(cls, sel) == replacement;
}

#pragma mark - Account sources

static UIWindow *MAPActiveWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!fallback && !window.hidden) fallback = window;
            if (window.isKeyWindow) return window;
        }
    }
    return fallback;
}

static id MAPAppNavigation(void) {
    UIViewController *root = MAPActiveWindow().rootViewController;
    if (!root) return nil;

    NSMutableArray<UIViewController *> *queue =
        [NSMutableArray arrayWithObject:root];

    for (NSUInteger i = 0; i < queue.count && i < 256; i++) {
        UIViewController *vc = queue[i];

        SEL appNavigationSEL = NSSelectorFromString(@"appNavigation");
        if ([vc respondsToSelector:appNavigationSEL]) {
            id navigation =
                ((id(*)(id,SEL))objc_msgSend)(vc, appNavigationSEL);
            if (navigation) return navigation;
        }

        NSString *className = NSStringFromClass(vc.class);
        if ([className containsString:@"XTabbedAppNavigationViewController"] ||
            [className isEqualToString:@"T1TabbedAppNavigationViewController"]) {
            return vc;
        }

        if (vc.presentedViewController &&
            ![queue containsObject:vc.presentedViewController]) {
            [queue addObject:vc.presentedViewController];
        }

        for (UIViewController *child in vc.childViewControllers ?: @[]) {
            if (![queue containsObject:child]) [queue addObject:child];
        }
    }
    return nil;
}

static id MAPAppNavigationAccount(void) {
    id navigation = MAPAppNavigation();
    SEL accountSEL = NSSelectorFromString(@"account");
    if (navigation && [navigation respondsToSelector:accountSEL]) {
        return ((id(*)(id,SEL))objc_msgSend)(navigation, accountSEL);
    }
    return nil;
}

static id MAPTFNTwitterAccount(void) {
    Class twitterClass = NSClassFromString(@"TFNTwitter");
    if (!twitterClass) return nil;

    for (NSString *sharedName in @[@"sharedTwitter", @"sharedInstance", @"shared"]) {
        SEL sharedSEL = NSSelectorFromString(sharedName);
        if (![twitterClass respondsToSelector:sharedSEL]) continue;

        id twitter = ((id(*)(id,SEL))objc_msgSend)(twitterClass, sharedSEL);
        for (NSString *accountName in @[@"activeAccount", @"currentAccount", @"account"]) {
            SEL accountSEL = NSSelectorFromString(accountName);
            if (twitter && [twitter respondsToSelector:accountSEL]) {
                id account =
                    ((id(*)(id,SEL))objc_msgSend)(twitter, accountSEL);
                if (account) return account;
            }
        }
    }
    return nil;
}

#pragma mark - Badge map

static BOOL MAPReadCounts(id object,
                          NSInteger *ntab, BOOL *hasNtab,
                          NSInteger *dm, BOOL *hasDM,
                          NSInteger *xchat, BOOL *hasXChat,
                          NSInteger *total, BOOL *hasTotal) {
    if (!object) return NO;
    *hasNtab = MAPReadCount(object, @"ntabUnreadCount", ntab);
    *hasDM = MAPReadCount(object, @"dmUnreadCount", dm);
    *hasXChat = MAPReadCount(object, @"xchatUnreadCount", xchat);
    *hasTotal = MAPReadCount(object, @"totalUnreadCount", total);
    return *hasNtab || *hasDM || *hasXChat || *hasTotal;
}

static BOOL MAPLooksLikeBadgeMap(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:NSDictionary.class] || !dictionary.count)
        return NO;

    NSUInteger valid = 0;
    for (id key in dictionary) {
        NSInteger a=0,b=0,c=0,d=0;
        BOOL ha=NO,hb=NO,hc=NO,hd=NO;
        if (MAPReadCounts(dictionary[key], &a,&ha,&b,&hb,&c,&hc,&d,&hd))
            valid++;
    }
    return valid == dictionary.count;
}

static void MAPLogBadgeMap(NSDictionary *dictionary, NSString *source) {
    if (!MAPLooksLikeBadgeMap(dictionary)) return;
    gLastBadgeMap = [dictionary copy];

    MAPLog(@"BADGE_MAP_BEGIN source=%@ accounts=%lu root=%ld eventActive=%@ appNav=%@ tfn=%@",
           source ?: @"-",
           (unsigned long)dictionary.count,
           (long)gRootBadgeCount,
           gEventActiveUserID ?: @"-",
           MAPResolveUserID(MAPAppNavigationAccount(), 0) ?: @"-",
           MAPResolveUserID(MAPTFNTwitterAccount(), 0) ?: @"-");

    for (id key in dictionary) {
        id counts = dictionary[key];
        NSInteger ntab=0,dm=0,xchat=0,total=0;
        BOOL hn=NO,hd=NO,hx=NO,ht=NO;
        MAPReadCounts(counts, &ntab,&hn,&dm,&hd,&xchat,&hx,&total,&ht);

        MAPLog(@"BADGE_MAP_ACCOUNT userID=%@ class=%@ ntab=%ld/%d dm=%ld/%d xchat=%ld/%d total=%ld/%d desc=%@",
               MAPNormalizedUserID(key) ?: @"-",
               NSStringFromClass([counts class]),
               (long)ntab, hn,
               (long)dm, hd,
               (long)xchat, hx,
               (long)total, ht,
               MAPText(counts));
    }

    MAPLog(@"BADGE_MAP_END source=%@", source ?: @"-");
}

static void MAPTryExtractBadgeMap(id object, NSString *source) {
    if (!object) return;

    if ([object isKindOfClass:NSNotification.class]) {
        NSNotification *notification = object;
        id map = notification.userInfo[@"AccountBadgesDidChangeUpdatedValues"];
        if ([map isKindOfClass:NSDictionary.class]) {
            MAPLogBadgeMap(map, [source stringByAppendingString:@".AccountBadgesDidChangeUpdatedValues"]);
        }

        id root = notification.userInfo[@"AppIconBadgeCountDidChangeUpdatedValue"];
        if ([root respondsToSelector:@selector(integerValue)]) {
            gRootBadgeCount = [root integerValue];
            MAPLog(@"ROOT_BADGE source=%@ value=%ld",
                   source ?: @"-", (long)gRootBadgeCount);
        }
        return;
    }

    if ([object isKindOfClass:NSDictionary.class]) {
        if (MAPLooksLikeBadgeMap(object)) {
            MAPLogBadgeMap(object, source);
            return;
        }
        for (id key in object) {
            id value = object[key];
            if ([value isKindOfClass:NSDictionary.class] && MAPLooksLikeBadgeMap(value)) {
                MAPLogBadgeMap(value,
                               [source stringByAppendingFormat:@".%@", MAPText(key)]);
            }
        }
        return;
    }

    id map = MAPSafeValue(object, @"badgeCountsForUserID");
    if ([map isKindOfClass:NSDictionary.class] && MAPLooksLikeBadgeMap(map)) {
        MAPLogBadgeMap(map, [source stringByAppendingString:@".badgeCountsForUserID"]);
    }
}

#pragma mark - Snapshot / render context

static NSArray<UIView *> *MAPFindViewsNamed(NSString *className) {
    NSMutableArray<UIView *> *result = [NSMutableArray array];

    // Do not use KVC collection operators on connectedScenes. The set can
    // contain UIScene instances that do not expose a windows key, which throws
    // NSUnknownKeyException and can crash during startup.
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;

        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) {
            if (![window isKindOfClass:UIWindow.class]) continue;

            NSMutableArray<UIView *> *queue =
                [NSMutableArray arrayWithObject:window];

            for (NSUInteger i=0; i<queue.count && i<4096; i++) {
                UIView *view = queue[i];
                if ([NSStringFromClass(view.class) isEqualToString:className]) {
                    [result addObject:view];
                }
                [queue addObjectsFromArray:view.subviews ?: @[]];
            }
        }
    }

    return result;
}

static void MAPLogRenderContext(NSString *reason) {
    NSString *appNav = MAPResolveUserID(MAPAppNavigationAccount(), 0);
    NSString *tfn = MAPResolveUserID(MAPTFNTwitterAccount(), 0);

    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (UIView *item in MAPFindViewsNamed(@"XNavigation.TabBarItemView")) {
        NSString *label = item.accessibilityLabel ?: @"-";
        [items addObject:label];
    }

    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%ld|%@",
                           gEventActiveUserID ?: @"-",
                           appNav ?: @"-",
                           tfn ?: @"-",
                           (long)gRootBadgeCount,
                           [items componentsJoinedByString:@","]];

    if ([signature isEqualToString:gLastSnapshotSignature] &&
        ![reason hasPrefix:@"manual"] &&
        ![reason hasPrefix:@"switch"]) {
        return;
    }
    gLastSnapshotSignature = [signature copy];

    MAPLog(@"SNAPSHOT reason=%@ eventActive=%@ appNavUserID=%@ tfnUserID=%@ rootBadge=%ld items=%@",
           reason ?: @"-",
           gEventActiveUserID ?: @"-",
           appNav ?: @"-",
           tfn ?: @"-",
           (long)gRootBadgeCount,
           items.count ? [items componentsJoinedByString:@" | "] : @"-");

    if (gLastBadgeMap) {
        MAPLogBadgeMap(gLastBadgeMap,
                       [NSString stringWithFormat:@"snapshot:%@", reason ?: @"-"]);
    }
}

static void MAPItemLayout(id self, SEL cmd) {
    if (gOrigItemLayout) ((void(*)(id,SEL))gOrigItemLayout)(self, cmd);

    static CFTimeInterval lastLog = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastLog < 0.35) return;
    lastLog = now;

    UIView *item = [self isKindOfClass:UIView.class] ? (UIView *)self : nil;
    MAPLog(@"RENDER_CONTEXT item=%@ ptr=%p eventActive=%@ appNavUserID=%@ tfnUserID=%@",
           item.accessibilityLabel ?: @"-",
           self,
           gEventActiveUserID ?: @"-",
           MAPResolveUserID(MAPAppNavigationAccount(),0) ?: @"-",
           MAPResolveUserID(MAPTFNTwitterAccount(),0) ?: @"-");
}

#pragma mark - Hooks

static void MAPActiveAccountDidChange(id self, SEL cmd, id argument) {
    NSString *beforeAppNav = MAPResolveUserID(MAPAppNavigationAccount(), 0);
    NSString *beforeTFN = MAPResolveUserID(MAPTFNTwitterAccount(), 0);
    NSString *argumentID = MAPResolveUserID(argument, 0);

    MAPLog(@"ACCOUNT_SWITCH_BEFORE selector=%@ argClass=%@ argUserID=%@ appNav=%@ tfn=%@ arg=%@",
           NSStringFromSelector(cmd),
           argument ? NSStringFromClass([argument class]) : @"nil",
           argumentID ?: @"-",
           beforeAppNav ?: @"-",
           beforeTFN ?: @"-",
           MAPText(argument));

    if (gOrigActiveAccountDidChange)
        ((void(*)(id,SEL,id))gOrigActiveAccountDidChange)(self, cmd, argument);

    if (argumentID.length) gEventActiveUserID = [argumentID copy];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSString *afterAppNav = MAPResolveUserID(MAPAppNavigationAccount(), 0);
        NSString *afterTFN = MAPResolveUserID(MAPTFNTwitterAccount(), 0);
        MAPLog(@"ACCOUNT_SWITCH_AFTER selector=%@ eventActive=%@ appNav=%@ tfn=%@",
               NSStringFromSelector(cmd),
               gEventActiveUserID ?: @"-",
               afterAppNav ?: @"-",
               afterTFN ?: @"-");
        MAPLogRenderContext(@"switch+20ms");
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MAPLogRenderContext(@"switch+250ms");
    });
}

static void MAPAppAccountsDidChange(id self, SEL cmd, id argument) {
    MAPLog(@"ACCOUNT_EVENT selector=%@ argClass=%@ argUserID=%@ arg=%@",
           NSStringFromSelector(cmd),
           argument ? NSStringFromClass([argument class]) : @"nil",
           MAPResolveUserID(argument,0) ?: @"-",
           MAPText(argument));
    if (gOrigAppAccountsDidChange)
        ((void(*)(id,SEL,id))gOrigAppAccountsDidChange)(self, cmd, argument);
    MAPLogRenderContext(@"account-event");
}

static void MAPTwitterAccountDidUpdate(id self, SEL cmd, id argument) {
    MAPLog(@"ACCOUNT_EVENT selector=%@ argClass=%@ argUserID=%@ arg=%@",
           NSStringFromSelector(cmd),
           argument ? NSStringFromClass([argument class]) : @"nil",
           MAPResolveUserID(argument,0) ?: @"-",
           MAPText(argument));
    if (gOrigTwitterAccountDidUpdate)
        ((void(*)(id,SEL,id))gOrigTwitterAccountDidUpdate)(self, cmd, argument);
    MAPLogRenderContext(@"twitter-account-update");
}

static void MAPSetBadgeCountsForUserID(id self, SEL cmd, id argument) {
    MAPLog(@"BADGE_SOURCE_BEFORE selector=%@ eventActive=%@ appNav=%@ tfn=%@ argClass=%@",
           NSStringFromSelector(cmd),
           gEventActiveUserID ?: @"-",
           MAPResolveUserID(MAPAppNavigationAccount(),0) ?: @"-",
           MAPResolveUserID(MAPTFNTwitterAccount(),0) ?: @"-",
           argument ? NSStringFromClass([argument class]) : @"nil");
    MAPTryExtractBadgeMap(argument, @"T1PushNotificationRouter.setBadgeCountsForUserID:.arg");

    if (gOrigSetBadgeCountsForUserID)
        ((void(*)(id,SEL,id))gOrigSetBadgeCountsForUserID)(self, cmd, argument);

    MAPTryExtractBadgeMap(self, @"T1PushNotificationRouter.setBadgeCountsForUserID:.self.after");
    MAPLogRenderContext(@"badge-map-set");
}

static void MAPUpdateBadgeCountFromNotification(id self, SEL cmd, id argument) {
    MAPLog(@"BADGE_SOURCE_NOTIFICATION selector=%@ argClass=%@",
           NSStringFromSelector(cmd),
           argument ? NSStringFromClass([argument class]) : @"nil");
    MAPTryExtractBadgeMap(argument, @"T1PushNotificationRouter._updateBadgeCountFromNotification:.arg");

    if (gOrigUpdateBadgeCountFromNotification)
        ((void(*)(id,SEL,id))gOrigUpdateBadgeCountFromNotification)(self, cmd, argument);

    MAPTryExtractBadgeMap(self, @"T1PushNotificationRouter._updateBadgeCountFromNotification:.self.after");
}

static void MAPRootBadgeUpdate(id self, SEL cmd, NSInteger value) {
    gRootBadgeCount = value;
    MAPLog(@"ROOT_BADGE_UPDATE class=%@ value=%ld eventActive=%@ appNav=%@ tfn=%@",
           NSStringFromClass([self class]),
           (long)value,
           gEventActiveUserID ?: @"-",
           MAPResolveUserID(MAPAppNavigationAccount(),0) ?: @"-",
           MAPResolveUserID(MAPTFNTwitterAccount(),0) ?: @"-");

    if (gOrigRootBadgeUpdate)
        ((void(*)(id,SEL,NSInteger))gOrigRootBadgeUpdate)(self, cmd, value);

    MAPLogRenderContext(@"root-badge");
}

static void MAPInstallHooks(void) {
    Class appEvent = NSClassFromString(@"T1AppEventHandler");
    if (appEvent) {
        MAPHookInstanceMethod(appEvent,
                              NSSelectorFromString(@"_t1_activeAccountDidChange:"),
                              (IMP)MAPActiveAccountDidChange,
                              &gOrigActiveAccountDidChange);
        MAPHookInstanceMethod(appEvent,
                              NSSelectorFromString(@"_t1_appAccountsDidChange:"),
                              (IMP)MAPAppAccountsDidChange,
                              &gOrigAppAccountsDidChange);
        MAPHookInstanceMethod(appEvent,
                              NSSelectorFromString(@"_t1_twitterAccountDidUpdate:"),
                              (IMP)MAPTwitterAccountDidUpdate,
                              &gOrigTwitterAccountDidUpdate);
    }

    Class router = NSClassFromString(@"T1PushNotificationRouter");
    if (router) {
        MAPHookInstanceMethod(router,
                              NSSelectorFromString(@"setBadgeCountsForUserID:"),
                              (IMP)MAPSetBadgeCountsForUserID,
                              &gOrigSetBadgeCountsForUserID);
        MAPHookInstanceMethod(router,
                              NSSelectorFromString(@"_updateBadgeCountFromNotification:"),
                              (IMP)MAPUpdateBadgeCountFromNotification,
                              &gOrigUpdateBadgeCountFromNotification);
    }

    Class rootBadger = NSClassFromString(@"T1TwitterSwift.RootBadgerImpl");
    if (rootBadger) {
        MAPHookInstanceMethod(rootBadger,
                              NSSelectorFromString(@"updateBadgeCount:"),
                              (IMP)MAPRootBadgeUpdate,
                              &gOrigRootBadgeUpdate);
    }

    Class item = NSClassFromString(@"XNavigation.TabBarItemView");
    if (item) {
        MAPHookInstanceMethod(item, @selector(layoutSubviews),
                              (IMP)MAPItemLayout, &gOrigItemLayout);
    }
}

#pragma mark - Runtime probe

static void MAPDumpClassMethods(Class cls) {
    if (!cls) return;
    NSString *className = NSStringFromClass(cls);
    MAPLog(@"RUNTIME_CLASS_BEGIN %@", className);

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i=0; i<count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"account"] ||
            [lower containsString:@"badge"] ||
            [lower containsString:@"user"] ||
            [lower containsString:@"switch"] ||
            [lower containsString:@"active"] ||
            [lower containsString:@"current"]) {
            MAPLog(@"RUNTIME_METHOD class=%@ selector=%@ encoding=%s",
                   className, name,
                   method_getTypeEncoding(methods[i]) ?: "-");
        }
    }
    free(methods);

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    for (unsigned int i=0; i<ivarCount; i++) {
        const char *name = ivar_getName(ivars[i]);
        NSString *n = name ? [NSString stringWithUTF8String:name] : @"";
        NSString *lower = n.lowercaseString;
        if ([lower containsString:@"account"] ||
            [lower containsString:@"user"] ||
            [lower containsString:@"badge"] ||
            [lower containsString:@"selected"]) {
            MAPLog(@"RUNTIME_IVAR class=%@ name=%@ type=%s offset=%td",
                   className, n,
                   ivar_getTypeEncoding(ivars[i]) ?: "-",
                   ivar_getOffset(ivars[i]));
        }
    }
    free(ivars);
    MAPLog(@"RUNTIME_CLASS_END %@", className);
}

static void MAPRuntimeProbe(void) {
    MAPLog(@"RUNTIME_PROBE_BEGIN");
    for (NSString *name in @[
        @"T1AppEventHandler",
        @"T1PushNotificationRouter",
        @"T1AppBadging",
        @"T1TwitterSwift.RootBadgerImpl",
        @"XNavigation.TabBarController",
        @"XNavigation.TabBarView",
        @"XNavigation.TabBarItemView"
    ]) {
        MAPDumpClassMethods(NSClassFromString(name));
    }

    id navigation = MAPAppNavigation();
    if (navigation) MAPDumpClassMethods([navigation class]);

    id account = MAPAppNavigationAccount();
    if (account) MAPDumpClassMethods([account class]);

    MAPLog(@"RUNTIME_PROBE_END");
}

#pragma mark - Notification observer

static BOOL MAPInterestingNotification(NSString *name) {
    NSString *lower = name.lowercaseString ?: @"";
    return [lower containsString:@"account"] ||
           [lower containsString:@"badge"] ||
           [lower containsString:@"unread"] ||
           [lower containsString:@"login"] ||
           [lower containsString:@"session"];
}

static void MAPInstallNotificationObserver(void) {
    if (gNotificationObserver) return;

    gNotificationObserver =
        [NSNotificationCenter.defaultCenter
         addObserverForName:nil object:nil queue:nil
         usingBlock:^(NSNotification *notification) {
        if (!MAPInterestingNotification(notification.name)) return;

        MAPLog(@"OBSERVED_NOTIFICATION name=%@ objectClass=%@ objectUserID=%@ object=%@ userInfo=%@",
               notification.name ?: @"-",
               notification.object ? NSStringFromClass([notification.object class]) : @"nil",
               MAPResolveUserID(notification.object,0) ?: @"-",
               MAPText(notification.object),
               MAPText(notification.userInfo));

        MAPTryExtractBadgeMap(notification,
                              [NSString stringWithFormat:@"NSNotification:%@",
                               notification.name ?: @"-"]);

        NSString *candidate = MAPResolveUserID(notification.object, 0);
        if (!candidate.length) candidate = MAPResolveUserID(notification.userInfo, 0);
        if (candidate.length &&
            [notification.name.lowercaseString containsString:@"account"]) {
            MAPLog(@"ACCOUNT_NOTIFICATION_CANDIDATE name=%@ userID=%@",
                   notification.name, candidate);
        }
    }];

    MAPLog(@"Installed account+badge NSNotification observer.");
}

#pragma mark - NFB UI

@interface XLiquidGlassMultiAccountProbeViewController : UITableViewController
@end

@implementation XLiquidGlassMultiAccountProbeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Multi-Account Probe";
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    return @"Somente diagnóstico. Não cria, altera ou corrige badges.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"MAPCell";
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleSubtitle
                reuseIdentifier:identifier];
    }

    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (indexPath.row == 0) {
        cell.textLabel.text = @"Capturar estado";
        cell.detailTextLabel.text =
            [NSString stringWithFormat:@"Evento: %@ · appNav: %@ · TFN: %@",
             gEventActiveUserID ?: @"?",
             MAPResolveUserID(MAPAppNavigationAccount(),0) ?: @"?",
             MAPResolveUserID(MAPTFNTwitterAccount(),0) ?: @"?"];
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"Probe de runtime";
        cell.detailTextLabel.text = @"Métodos e ivars de conta/badge.";
    } else if (indexPath.row == 2) {
        cell.textLabel.text = @"Copiar relatório";
        cell.detailTextLabel.text = kMAPLogFileName;
    } else {
        cell.textLabel.text = @"Limpar relatório";
        cell.detailTextLabel.text = @"Reinicia somente o arquivo de log.";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.row == 0) {
        MAPLogRenderContext(@"manual-capture");
        [tableView reloadData];
        return;
    }

    if (indexPath.row == 1) {
        MAPRuntimeProbe();
        MAPLogRenderContext(@"manual-runtime");
        [tableView reloadData];
        return;
    }

    if (indexPath.row == 2) {
        NSString *report =
            [NSString stringWithContentsOfFile:MAPLogPath()
                                      encoding:NSUTF8StringEncoding
                                         error:nil] ?: @"";
        UIPasteboard.generalPasteboard.string = report;

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Multi-Account Probe"
                                                message:
             [NSString stringWithFormat:@"Relatório copiado (%lu caracteres).",
              (unsigned long)report.length]
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [NSFileManager.defaultManager removeItemAtPath:MAPLogPath() error:nil];
    MAPLog(@"LOG RESET eventActive=%@ appNav=%@ tfn=%@ root=%ld",
           gEventActiveUserID ?: @"-",
           MAPResolveUserID(MAPAppNavigationAccount(),0) ?: @"-",
           MAPResolveUserID(MAPTFNTwitterAccount(),0) ?: @"-",
           (long)gRootBadgeCount);
    [tableView reloadData];
}

@end

static BOOL MAPSectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([entry[@"action"] isEqualToString:@"showXLiquidGlassMultiAccountProbe"])
            return YES;
    }
    return NO;
}

static void MAPInjectNFBSection(id controller) {
    NSArray *sections = MAPSafeValue(controller, @"sections");
    if (![sections isKindOfClass:NSArray.class] || MAPSectionsContainEntry(sections))
        return;

    NSMutableArray *updated = [sections mutableCopy];
    [updated addObject:@{
        @"title": @"Multi-Account Probe",
        @"subtitle": @"Diagnóstico da troca de conta e badges.",
        @"icon": @"person_2",
        @"action": @"showXLiquidGlassMultiAccountProbe"
    }];

    @try {
        [controller setValue:[updated copy] forKey:@"sections"];
    } @catch (__unused NSException *exception) {
    }
}

static void MAPNFBSetupSections(id self, SEL cmd) {
    if (gOrigNFBSetupSections)
        ((void(*)(id,SEL))gOrigNFBSetupSections)(self, cmd);
    MAPInjectNFBSection(self);
}

static void MAPNFBViewWillAppear(id self, SEL cmd, BOOL animated) {
    if (gOrigNFBViewWillAppear)
        ((void(*)(id,SEL,BOOL))gOrigNFBViewWillAppear)(self, cmd, animated);

    MAPInjectNFBSection(self);
    UITableView *table = MAPSafeValue(self, @"tableView");
    [table reloadData];
}

static void MAPShowSettings(id self, SEL cmd) {
    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassMultiAccountProbeViewController *vc =
        [XLiquidGlassMultiAccountProbeViewController new];

    UINavigationController *nav =
        ((UIViewController *)self).navigationController;
    if (nav) {
        [nav pushViewController:vc animated:YES];
    } else {
        UINavigationController *wrapper =
            [[UINavigationController alloc] initWithRootViewController:vc];
        [(UIViewController *)self presentViewController:wrapper
                                              animated:YES completion:nil];
    }
}

static void MAPInstallNFBIntegration(void) {
    Class cls = NSClassFromString(@"ModernSettingsViewController");
    if (!cls) return;

    class_addMethod(cls,
                    NSSelectorFromString(@"showXLiquidGlassMultiAccountProbe"),
                    (IMP)MAPShowSettings,
                    "v@:");

    MAPHookInstanceMethod(cls, NSSelectorFromString(@"setupSections"),
                          (IMP)MAPNFBSetupSections, &gOrigNFBSetupSections);
    MAPHookInstanceMethod(cls, @selector(viewWillAppear:),
                          (IMP)MAPNFBViewWillAppear, &gOrigNFBViewWillAppear);
}

#pragma mark - Install

static void MAPInstallAll(void) {
    MAPInstallHooks();
    MAPInstallNotificationObserver();
    MAPInstallNFBIntegration();
}

static void MAPRetry(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MAPInstallAll();
        MAPLogRenderContext([NSString stringWithFormat:@"retry-%.2f", delay]);
    });
}

__attribute__((constructor))
static void XLiquidGlassMultiAccountProbeInit(void) {
    @autoreleasepool {
        MAPLog(@"========== XLiquidGlass Multi-Account Badge Probe 0.2.1 loaded ==========");
        MAPLog(@"logPath=%@", MAPLogPath());

        MAPInstallAll();

        MAPRetry(0.05);
        MAPRetry(0.20);
        MAPRetry(0.50);
        MAPRetry(1.00);
        MAPRetry(2.00);
        MAPRetry(4.00);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(2.5*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            MAPRuntimeProbe();
            MAPLogRenderContext(@"startup+2.5s");
        });
    }
}
