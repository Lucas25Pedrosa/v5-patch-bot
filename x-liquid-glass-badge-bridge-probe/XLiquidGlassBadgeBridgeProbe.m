#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kXBBPLogFileName = @"XLiquidGlassBadgeBridgeProbe.log";
static NSString *const kXBBPDefaultsPrefix = @"XLiquidGlassBadgeBridgeProbe.";
static const NSUInteger kXBBPMaxLogBytes = 3 * 1024 * 1024;

static NSInteger gNTabCount = -1;
static NSInteger gDMCount = -1;
static NSInteger gXChatCount = -1;
static NSInteger gTotalCount = -1;
static NSInteger gLastRootBadgeCount = -1;
static NSString *gActiveUserID = nil;
static NSDictionary *gLastBadgeCountsByUserID = nil;
static BOOL gLoadedPersistedCounts = NO;

static IMP gOrigXNavItemLayout = NULL;
static IMP gOrigNFBSetupSections = NULL;
static IMP gOrigNFBViewWillAppear = NULL;

static NSMutableDictionary<NSString *, NSValue *> *gObjectHookOriginals;
static NSMutableDictionary<NSString *, NSValue *> *gIntegerHookOriginals;
static id gNotificationObserver = nil;

static char kXBBPBadgeLabelKey;

#pragma mark - Log

static NSString *XBBPLogPath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) documents = NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:kXBBPLogFileName];
}

static NSString *XBBPStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:NSDate.date];
}

static NSString *XBBPText(id value) {
    if (!value || value == NSNull.null) return @"-";
    NSString *text = [value description] ?: @"-";
    if (text.length > 800) {
        text = [[text substringToIndex:800] stringByAppendingString:@"…"];
    }
    return text.length ? text : @"-";
}

static void XBBPTrimLogIfNeeded(void) {
    NSString *path = XBBPLogPath();
    NSDictionary *attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];

    unsigned long long size = [attrs fileSize];
    if (size <= kXBBPMaxLogBytes) return;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length <= kXBBPMaxLogBytes) return;

    NSUInteger keep = kXBBPMaxLogBytes / 2;
    NSData *tail =
        [data subdataWithRange:NSMakeRange(data.length - keep, keep)];
    [tail writeToFile:path atomically:YES];
}

static void XBBPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void XBBPLog(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args, format);
    NSString *body =
        [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line =
        [NSString stringWithFormat:@"[%@] %@\n", XBBPStamp(), body ?: @""];

    NSLog(@"[XLiquidGlassBadgeBridgeProbe] %@", body ?: @"");

    @synchronized([NSFileManager defaultManager]) {
        NSString *path = XBBPLogPath();

        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [@"" writeToFile:path
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:nil];
        }

        NSFileHandle *handle =
            [NSFileHandle fileHandleForWritingAtPath:path];

        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }

        XBBPTrimLogIfNeeded();
    }
}

#pragma mark - Runtime helpers

static NSString *XBBPHookKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%@|%@",
            NSStringFromClass(cls),
            NSStringFromSelector(sel)];
}

static BOOL XBBPDirectMethod(Class cls, SEL sel, Method *outMethod) {
    if (!cls || !sel) return NO;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;

    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            if (outMethod) *outMethod = methods[i];
            found = YES;
            break;
        }
    }

    free(methods);
    return found;
}

static BOOL XBBPHookMethod(Class cls,
                           SEL sel,
                           IMP replacement,
                           IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP current = class_getMethodImplementation(cls, sel);
    if (current == replacement) return YES;

    if (originalOut && !*originalOut) *originalOut = current;

    const char *types = method_getTypeEncoding(method);
    if (!types) return NO;

    class_replaceMethod(cls, sel, replacement, types);
    return class_getMethodImplementation(cls, sel) == replacement;
}

static Class XBBPClassByAnyName(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (cls) return cls;
    }

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;

    Class *classes =
        (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);

    Class result = Nil;

    for (int i = 0; i < count && !result; i++) {
        NSString *actual = NSStringFromClass(classes[i]);
        for (NSString *name in names) {
            if ([actual isEqualToString:name]) {
                result = classes[i];
                break;
            }
        }
    }

    free(classes);
    return result;
}

static id XBBPSafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;

    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL XBBPReadIntegerGetter(id object,
                                  NSString *name,
                                  NSInteger *valueOut) {
    if (!object || !name.length || !valueOut) return NO;

    SEL sel = NSSelectorFromString(name);
    Method method = class_getInstanceMethod([object class], sel);

    if (method && [object respondsToSelector:sel]) {
        const char *types = method_getTypeEncoding(method);
        NSMethodSignature *signature =
            [object methodSignatureForSelector:sel];

        const char *ret =
            signature ? signature.methodReturnType : NULL;

        if (ret) {
            switch (ret[0]) {
                case 'q':
                    *valueOut =
                        ((long long(*)(id,SEL))objc_msgSend)(object, sel);
                    return YES;
                case 'Q':
                    *valueOut =
                        (NSInteger)((unsigned long long(*)(id,SEL))objc_msgSend)(
                            object, sel);
                    return YES;
                case 'i':
                    *valueOut =
                        ((int(*)(id,SEL))objc_msgSend)(object, sel);
                    return YES;
                case 'I':
                    *valueOut =
                        (NSInteger)((unsigned int(*)(id,SEL))objc_msgSend)(
                            object, sel);
                    return YES;
                case 's':
                    *valueOut =
                        ((short(*)(id,SEL))objc_msgSend)(object, sel);
                    return YES;
                case 'S':
                    *valueOut =
                        (NSInteger)((unsigned short(*)(id,SEL))objc_msgSend)(
                            object, sel);
                    return YES;
                case 'c':
                case 'B':
                    *valueOut =
                        ((BOOL(*)(id,SEL))objc_msgSend)(object, sel);
                    return YES;
                case '@': {
                    id value =
                        ((id(*)(id,SEL))objc_msgSend)(object, sel);
                    if ([value respondsToSelector:@selector(integerValue)]) {
                        *valueOut = [value integerValue];
                        return YES;
                    }
                    break;
                }
                default:
                    XBBPLog(@"GETTER_UNSUPPORTED class=%@ selector=%@ encoding=%s",
                            NSStringFromClass([object class]),
                            name,
                            types ?: "-");
                    break;
            }
        }
    }

    id value = XBBPSafeValueForKey(object, name);
    if ([value respondsToSelector:@selector(integerValue)]) {
        *valueOut = [value integerValue];
        return YES;
    }

    return NO;
}


static BOOL XBBPReadCountField(id object,
                               NSString *baseName,
                               NSInteger *valueOut) {
    if (!object || !baseName.length || !valueOut) return NO;

    NSString *numberGetter =
        [baseName stringByAppendingString:@"Number"];

    if (XBBPReadIntegerGetter(object, numberGetter, valueOut)) {
        return YES;
    }

    return XBBPReadIntegerGetter(object, baseName, valueOut);
}

static NSString *XBBPNormalizedUserID(id value) {
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

static NSString *XBBPTryResolveUserIDFromObject(id object) {
    if (!object) return nil;

    NSArray<NSString *> *keys = @[
        @"userID", @"userId", @"restID", @"restId",
        @"accountID", @"accountId", @"activeUserID",
        @"activeAccountID", @"currentUserID", @"currentAccountID"
    ];

    for (NSString *key in keys) {
        id value = XBBPSafeValueForKey(object, key);
        NSString *resolved = XBBPNormalizedUserID(value);
        if (resolved.length) return resolved;
    }

    for (NSString *key in @[@"account", @"currentAccount", @"activeAccount"]) {
        id nested = XBBPSafeValueForKey(object, key);
        if (!nested || nested == object) continue;

        NSString *resolved = XBBPTryResolveUserIDFromObject(nested);
        if (resolved.length) return resolved;
    }

    return nil;
}

static BOOL XBBPReadAllCounts(id object,
                              NSInteger *ntab,
                              BOOL *hasNtab,
                              NSInteger *dm,
                              BOOL *hasDM,
                              NSInteger *xchat,
                              BOOL *hasXChat,
                              NSInteger *total,
                              BOOL *hasTotal) {
    if (!object) return NO;

    if (hasNtab) *hasNtab =
        XBBPReadCountField(object, @"ntabUnreadCount", ntab);

    if (hasDM) *hasDM =
        XBBPReadCountField(object, @"dmUnreadCount", dm);

    if (hasXChat) *hasXChat =
        XBBPReadCountField(object, @"xchatUnreadCount", xchat);

    if (hasTotal) *hasTotal =
        XBBPReadCountField(object, @"totalUnreadCount", total);

    return (hasNtab && *hasNtab) ||
           (hasDM && *hasDM) ||
           (hasXChat && *hasXChat) ||
           (hasTotal && *hasTotal);
}

#pragma mark - Counts / extraction

static NSUserDefaults *XBBPDefaults(void) {
    return NSUserDefaults.standardUserDefaults;
}

static NSString *XBBPKey(NSString *name) {
    return [kXBBPDefaultsPrefix stringByAppendingString:name];
}

static void XBBPPersistCounts(void) {
    NSUserDefaults *defaults = XBBPDefaults();

    [defaults setInteger:gNTabCount forKey:XBBPKey(@"ntab")];
    [defaults setInteger:gDMCount forKey:XBBPKey(@"dm")];
    [defaults setInteger:gXChatCount forKey:XBBPKey(@"xchat")];
    [defaults setInteger:gTotalCount forKey:XBBPKey(@"total")];
    [defaults setDouble:NSDate.date.timeIntervalSince1970
                 forKey:XBBPKey(@"timestamp")];
}

static void XBBPLoadPersistedCounts(void) {
    if (gLoadedPersistedCounts) return;
    gLoadedPersistedCounts = YES;

    NSUserDefaults *defaults = XBBPDefaults();
    double timestamp = [defaults doubleForKey:XBBPKey(@"timestamp")];

    if (timestamp <= 0) return;

    NSTimeInterval age = NSDate.date.timeIntervalSince1970 - timestamp;
    if (age > 24.0 * 60.0 * 60.0) {
        XBBPLog(@"PERSISTED_COUNTS ignored age=%.0fs", age);
        return;
    }

    gNTabCount = [defaults integerForKey:XBBPKey(@"ntab")];
    gDMCount = [defaults integerForKey:XBBPKey(@"dm")];
    gXChatCount = [defaults integerForKey:XBBPKey(@"xchat")];
    gTotalCount = [defaults integerForKey:XBBPKey(@"total")];

    XBBPLog(@"PERSISTED_COUNTS loaded ntab=%ld dm=%ld xchat=%ld total=%ld age=%.0fs",
            (long)gNTabCount,
            (long)gDMCount,
            (long)gXChatCount,
            (long)gTotalCount,
            age);
}

static NSInteger XBBPChatDisplayCount(void) {
    if (gXChatCount > 0) return gXChatCount;
    if (gDMCount >= 0) return gDMCount;
    if (gXChatCount >= 0) return gXChatCount;
    return -1;
}

static void XBBPRefreshVisibleBadges(void);

static void XBBPSetCounts(NSInteger ntab,
                          BOOL hasNtab,
                          NSInteger dm,
                          BOOL hasDM,
                          NSInteger xchat,
                          BOOL hasXChat,
                          NSInteger total,
                          BOOL hasTotal,
                          NSString *source) {
    BOOL changed = NO;

    if (hasNtab && gNTabCount != MAX((NSInteger)0, ntab)) {
        gNTabCount = MAX((NSInteger)0, ntab);
        changed = YES;
    }

    if (hasDM && gDMCount != MAX((NSInteger)0, dm)) {
        gDMCount = MAX((NSInteger)0, dm);
        changed = YES;
    }

    if (hasXChat && gXChatCount != MAX((NSInteger)0, xchat)) {
        gXChatCount = MAX((NSInteger)0, xchat);
        changed = YES;
    }

    if (hasTotal && gTotalCount != MAX((NSInteger)0, total)) {
        gTotalCount = MAX((NSInteger)0, total);
        changed = YES;
    }

    XBBPLog(@"COUNTS source=%@ ntab=%ld(%d) dm=%ld(%d) xchat=%ld(%d) total=%ld(%d) changed=%d",
            source ?: @"-",
            (long)gNTabCount,
            hasNtab,
            (long)gDMCount,
            hasDM,
            (long)gXChatCount,
            hasXChat,
            (long)gTotalCount,
            hasTotal,
            changed);

    if (changed) {
        XBBPPersistCounts();
        dispatch_async(dispatch_get_main_queue(), ^{
            XBBPRefreshVisibleBadges();
        });
    }
}

static BOOL XBBPClassLooksLikeBadgeCounts(id object) {
    if (!object) return NO;

    NSString *name = NSStringFromClass([object class]);
    NSString *lower = name.lowercaseString;

    return [lower containsString:@"badgecounts"] ||
           [lower containsString:@"badgecountresponse"];
}

static void XBBPExtractCountsFromObject(id object,
                                        NSString *source,
                                        NSUInteger depth);

static void XBBPSelectCountsForAccountMap(NSDictionary *dictionary,
                                          NSString *source);


static BOOL XBBPLooksLikeAccountBadgeMap(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:NSDictionary.class] || dictionary.count == 0)
        return NO;

    NSUInteger badgeObjects = 0;
    for (id key in dictionary) {
        id value = dictionary[key];
        if (XBBPClassLooksLikeBadgeCounts(value)) badgeObjects++;
    }

    return badgeObjects > 0 && badgeObjects == dictionary.count;
}

static void XBBPApplyCountsObjectForUser(id object,
                                         NSString *userID,
                                         NSString *source) {
    NSInteger ntab = 0, dm = 0, xchat = 0, total = 0;
    BOOL hasNtab = NO, hasDM = NO, hasXChat = NO, hasTotal = NO;

    XBBPReadAllCounts(object,
                      &ntab, &hasNtab,
                      &dm, &hasDM,
                      &xchat, &hasXChat,
                      &total, &hasTotal);

    XBBPLog(@"ACCOUNT_COUNTS_SELECT userID=%@ source=%@ class=%@ values(ntab=%ld/%d dm=%ld/%d xchat=%ld/%d total=%ld/%d)",
            userID ?: @"-",
            source ?: @"-",
            NSStringFromClass([object class]),
            (long)ntab, hasNtab,
            (long)dm, hasDM,
            (long)xchat, hasXChat,
            (long)total, hasTotal);

    if (userID.length) gActiveUserID = [userID copy];

    XBBPSetCounts(ntab, hasNtab,
                  dm, hasDM,
                  xchat, hasXChat,
                  total, hasTotal,
                  source);
}

static void XBBPSelectCountsForAccountMap(NSDictionary *dictionary,
                                          NSString *source) {
    if (!XBBPLooksLikeAccountBadgeMap(dictionary)) return;

    gLastBadgeCountsByUserID = [dictionary copy];

    if (gActiveUserID.length) {
        id exact = dictionary[gActiveUserID];
        if (!exact) exact = dictionary[@(gActiveUserID.longLongValue)];

        if (exact) {
            XBBPApplyCountsObjectForUser(
                exact,
                gActiveUserID,
                [source stringByAppendingString:@".activeUserID"]);
            return;
        }
    }

    if (gLastRootBadgeCount >= 0) {
        id selectedObject = nil;
        NSString *selectedUserID = nil;
        NSUInteger matchCount = 0;

        for (id key in dictionary) {
            id object = dictionary[key];
            NSInteger total = -1;
            BOOL hasTotal =
                XBBPReadCountField(object, @"totalUnreadCount", &total);

            if (hasTotal && total == gLastRootBadgeCount) {
                selectedObject = object;
                selectedUserID = XBBPNormalizedUserID(key);
                matchCount++;
            }
        }

        if (matchCount == 1 && selectedObject) {
            XBBPLog(@"ACCOUNT_MATCH_BY_ROOT_BADGE root=%ld userID=%@",
                    (long)gLastRootBadgeCount,
                    selectedUserID ?: @"-");

            XBBPApplyCountsObjectForUser(
                selectedObject,
                selectedUserID,
                [source stringByAppendingString:@".rootBadgeMatch"]);
            return;
        }

        XBBPLog(@"ACCOUNT_MATCH_BY_ROOT_BADGE_AMBIGUOUS root=%ld matches=%lu",
                (long)gLastRootBadgeCount,
                (unsigned long)matchCount);
    }

    if (dictionary.count == 1) {
        id key = dictionary.allKeys.firstObject;
        id object = dictionary[key];

        XBBPApplyCountsObjectForUser(
            object,
            XBBPNormalizedUserID(key),
            [source stringByAppendingString:@".singleAccount"]);
        return;
    }

    XBBPLog(@"ACCOUNT_SELECTION_PENDING source=%@ activeUserID=%@ rootBadge=%ld accounts=%lu",
            source ?: @"-",
            gActiveUserID ?: @"-",
            (long)gLastRootBadgeCount,
            (unsigned long)dictionary.count);
}

static void XBBPExtractCountsFromDictionary(NSDictionary *dictionary,
                                            NSString *source,
                                            NSUInteger depth) {
    if (!dictionary || depth > 4) return;

    id appIconBadge = dictionary[@"AppIconBadgeCountDidChangeUpdatedValue"];
    if ([appIconBadge respondsToSelector:@selector(integerValue)]) {
        gLastRootBadgeCount = [appIconBadge integerValue];
        XBBPLog(@"ROOT_BADGE_NOTIFICATION value=%ld", (long)gLastRootBadgeCount);

        if (gLastBadgeCountsByUserID) {
            XBBPSelectCountsForAccountMap(
                gLastBadgeCountsByUserID,
                [source stringByAppendingString:@".rootBadgeNotification"]);
        }
    }

    if (XBBPLooksLikeAccountBadgeMap(dictionary)) {
        XBBPSelectCountsForAccountMap(dictionary, source);
        return;
    }

    NSInteger ntab = 0, dm = 0, xchat = 0, total = 0;
    BOOL hasNtab = NO, hasDM = NO, hasXChat = NO, hasTotal = NO;

    NSArray<NSString *> *ntabKeys =
        @[@"ntabUnreadCount", @"ntab", @"notificationTabBadgeCount",
          @"notificationBadgeCount"];

    NSArray<NSString *> *dmKeys =
        @[@"dmUnreadCount", @"dm", @"dmBadgeCount"];

    NSArray<NSString *> *xchatKeys =
        @[@"xchatUnreadCount", @"xchat", @"xChatUnreadCount",
          @"xchatBadgeCount"];

    NSArray<NSString *> *totalKeys =
        @[@"totalUnreadCount", @"total", @"totalBadgeCount",
          @"appBadgeCount"];

    for (NSString *key in ntabKeys) {
        id value = dictionary[key];
        if ([value respondsToSelector:@selector(integerValue)]) {
            ntab = [value integerValue];
            hasNtab = YES;
            break;
        }
    }

    for (NSString *key in dmKeys) {
        id value = dictionary[key];
        if ([value respondsToSelector:@selector(integerValue)]) {
            dm = [value integerValue];
            hasDM = YES;
            break;
        }
    }

    for (NSString *key in xchatKeys) {
        id value = dictionary[key];
        if ([value respondsToSelector:@selector(integerValue)]) {
            xchat = [value integerValue];
            hasXChat = YES;
            break;
        }
    }

    for (NSString *key in totalKeys) {
        id value = dictionary[key];
        if ([value respondsToSelector:@selector(integerValue)]) {
            total = [value integerValue];
            hasTotal = YES;
            break;
        }
    }

    if (hasNtab || hasDM || hasXChat || hasTotal) {
        XBBPSetCounts(ntab, hasNtab,
                      dm, hasDM,
                      xchat, hasXChat,
                      total, hasTotal,
                      source);
    }

    NSUInteger inspected = 0;
    for (id key in dictionary) {
        if (inspected++ > 40) break;

        id value = dictionary[key];
        NSString *keyText = [[key description] lowercaseString];

        if ([keyText containsString:@"badge"] ||
            [keyText containsString:@"count"] ||
            [keyText containsString:@"unread"] ||
            [keyText containsString:@"ntab"] ||
            [keyText containsString:@"xchat"] ||
            [keyText containsString:@"dm"]) {
            XBBPLog(@"DICT_CANDIDATE source=%@ key=%@ valueClass=%@ value=%@",
                    source,
                    XBBPText(key),
                    value ? NSStringFromClass([value class]) : @"nil",
                    XBBPText(value));
        }

        if ([value isKindOfClass:NSDictionary.class] ||
            [value isKindOfClass:NSArray.class] ||
            XBBPClassLooksLikeBadgeCounts(value)) {
            XBBPExtractCountsFromObject(
                value,
                [source stringByAppendingFormat:@".%@", XBBPText(key)],
                depth + 1);
        }
    }
}

static void XBBPExtractCountsFromBadgeCountsObject(id object,
                                                   NSString *source) {
    NSInteger ntab = 0, dm = 0, xchat = 0, total = 0;
    BOOL hasNtab = NO, hasDM = NO, hasXChat = NO, hasTotal = NO;

    XBBPReadAllCounts(object,
                      &ntab, &hasNtab,
                      &dm, &hasDM,
                      &xchat, &hasXChat,
                      &total, &hasTotal);

    XBBPLog(@"BADGE_COUNTS_OBJECT source=%@ ptr=%p class=%@ desc=%@ values(ntab=%ld/%d dm=%ld/%d xchat=%ld/%d total=%ld/%d)",
            source,
            object,
            NSStringFromClass([object class]),
            XBBPText(object),
            (long)ntab, hasNtab,
            (long)dm, hasDM,
            (long)xchat, hasXChat,
            (long)total, hasTotal);
}

static void XBBPExtractCountsFromObject(id object,
                                        NSString *source,
                                        NSUInteger depth) {
    if (!object || depth > 4) return;

    if ([object isKindOfClass:NSDictionary.class]) {
        XBBPExtractCountsFromDictionary(object, source, depth);
        return;
    }

    if ([object isKindOfClass:NSArray.class]) {
        NSUInteger index = 0;
        for (id value in (NSArray *)object) {
            if (index >= 30) break;

            XBBPExtractCountsFromObject(
                value,
                [source stringByAppendingFormat:@"[%lu]",
                 (unsigned long)index],
                depth + 1);

            index++;
        }
        return;
    }

    if ([object isKindOfClass:NSNotification.class]) {
        NSNotification *notification = object;

        XBBPLog(@"NOTIFICATION_OBJECT source=%@ name=%@ objectClass=%@ userInfo=%@",
                source,
                notification.name,
                notification.object
                    ? NSStringFromClass([notification.object class])
                    : @"nil",
                XBBPText(notification.userInfo));

        XBBPExtractCountsFromObject(
            notification.object,
            [source stringByAppendingString:@".object"],
            depth + 1);

        XBBPExtractCountsFromObject(
            notification.userInfo,
            [source stringByAppendingString:@".userInfo"],
            depth + 1);

        return;
    }

    if (XBBPClassLooksLikeBadgeCounts(object)) {
        XBBPExtractCountsFromBadgeCountsObject(object, source);
    }

    for (NSString *key in @[@"badgeCounts",
                             @"badgeCountsForUserID",
                             @"currentBadgeCounts",
                             @"remoteBadgeCounts"]) {
        id value = XBBPSafeValueForKey(object, key);
        if (value && value != object) {
            XBBPLog(@"KVC_CANDIDATE source=%@ objectClass=%@ key=%@ valueClass=%@ value=%@",
                    source,
                    NSStringFromClass([object class]),
                    key,
                    NSStringFromClass([value class]),
                    XBBPText(value));

            XBBPExtractCountsFromObject(
                value,
                [source stringByAppendingFormat:@".%@", key],
                depth + 1);
        }
    }
}

#pragma mark - Badge rendering

static NSArray<UIWindow *> *XBBPWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;

        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window) [windows addObject:window];
        }
    }

    return windows;
}

static NSArray<UIView *> *XBBPSubviewsMatching(UIView *root,
                                               NSString *className) {
    if (!root || !className.length) return @[];

    NSMutableArray<UIView *> *queue =
        [NSMutableArray arrayWithObject:root];
    NSMutableArray<UIView *> *result =
        [NSMutableArray array];

    for (NSUInteger i = 0; i < queue.count && i < 4096; i++) {
        UIView *view = queue[i];

        if ([NSStringFromClass(view.class) isEqualToString:className]) {
            [result addObject:view];
        }

        [queue addObjectsFromArray:view.subviews ?: @[]];
    }

    return result;
}

static UIImageView *XBBPImageViewForItem(UIView *item) {
    for (UIView *subview in item.subviews ?: @[]) {
        if ([subview isKindOfClass:UIImageView.class]) {
            return (UIImageView *)subview;
        }
    }

    return nil;
}

static UILabel *XBBPBadgeLabelForItem(UIView *item) {
    UILabel *label =
        objc_getAssociatedObject(item, &kXBBPBadgeLabelKey);

    if (label) return label;

    label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.userInteractionEnabled = NO;
    label.hidden = YES;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = UIColor.systemRedColor;
    label.font = [UIFont boldSystemFontOfSize:10.0];
    label.layer.cornerRadius = 8.0;
    label.layer.masksToBounds = YES;
    label.accessibilityIdentifier = @"XLiquidGlassBadgeBridge";

    [item addSubview:label];

    objc_setAssociatedObject(item,
                             &kXBBPBadgeLabelKey,
                             label,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    XBBPLog(@"BADGE_VIEW_CREATED item=%p label=%@",
            item,
            XBBPText(item.accessibilityLabel));

    return label;
}

static NSInteger XBBPCountForItem(UIView *item) {
    NSString *label = item.accessibilityLabel.lowercaseString ?: @"";

    if ([label containsString:@"notifica"]) {
        return gNTabCount;
    }

    if ([label containsString:@"bate-papo"] ||
        [label containsString:@"chat"] ||
        [label containsString:@"mensag"] ||
        [label containsString:@"messages"]) {
        return XBBPChatDisplayCount();
    }

    return -1;
}

static void XBBPApplyBadgeToItem(UIView *item, NSString *event) {
    if (!item) return;

    NSInteger count = XBBPCountForItem(item);
    UILabel *badge = XBBPBadgeLabelForItem(item);

    if (count <= 0) {
        if (!badge.hidden) {
            XBBPLog(@"BADGE_HIDE event=%@ item=%@ count=%ld",
                    event,
                    XBBPText(item.accessibilityLabel),
                    (long)count);
        }

        badge.hidden = YES;
        return;
    }

    NSString *text =
        count > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)count];

    badge.text = text;

    CGSize textSize =
        [text sizeWithAttributes:@{NSFontAttributeName: badge.font}];

    CGFloat width = MAX(16.0, ceil(textSize.width) + 7.0);
    CGFloat height = 16.0;

    UIImageView *imageView = XBBPImageViewForItem(item);

    if (imageView) {
        CGFloat x = CGRectGetMaxX(imageView.frame) - 8.0;
        CGFloat y = CGRectGetMinY(imageView.frame) - 4.0;

        badge.frame = CGRectIntegral(
            CGRectMake(x, y, width, height));
    } else {
        badge.frame = CGRectIntegral(
            CGRectMake(CGRectGetMidX(item.bounds) + 4.0,
                       8.0,
                       width,
                       height));
    }

    badge.layer.cornerRadius = height / 2.0;
    badge.hidden = NO;

    [item bringSubviewToFront:badge];

    XBBPLog(@"BADGE_APPLY event=%@ item=%@ count=%ld text=%@ frame=%@ iconFrame=%@",
            event,
            XBBPText(item.accessibilityLabel),
            (long)count,
            text,
            NSStringFromCGRect(badge.frame),
            imageView ? NSStringFromCGRect(imageView.frame) : @"-");
}

static void XBBPRefreshVisibleBadges(void) {
    for (UIWindow *window in XBBPWindows()) {
        if (window.hidden) continue;

        NSArray<UIView *> *items =
            XBBPSubviewsMatching(window, @"XNavigation.TabBarItemView");

        for (UIView *item in items) {
            XBBPApplyBadgeToItem(item, @"refresh");
        }
    }
}

static void XBBPXNavItemLayout(id self, SEL cmd) {
    if (gOrigXNavItemLayout) {
        ((void(*)(id,SEL))gOrigXNavItemLayout)(self, cmd);
    }

    if ([self isKindOfClass:UIView.class]) {
        XBBPApplyBadgeToItem((UIView *)self, @"layoutSubviews");
    }
}

static void XBBPInstallXNavItemHook(void) {
    Class cls = XBBPClassByAnyName(@[
        @"XNavigation.TabBarItemView",
        @"_TtC11XNavigation14TabBarItemView"
    ]);

    if (!cls) return;

    if (!gOrigXNavItemLayout &&
        XBBPHookMethod(cls,
                       @selector(layoutSubviews),
                       (IMP)XBBPXNavItemLayout,
                       &gOrigXNavItemLayout)) {
        XBBPLog(@"Installed XNavigation.TabBarItemView badge renderer.");
    }
}

#pragma mark - Generic source hooks

static IMP XBBPOriginalObjectHook(id self, SEL cmd) {
    Class cls = [self class];

    while (cls) {
        NSValue *value =
            gObjectHookOriginals[XBBPHookKey(cls, cmd)];

        if (value) return [value pointerValue];

        cls = class_getSuperclass(cls);
    }

    return NULL;
}

static IMP XBBPOriginalIntegerHook(id self, SEL cmd) {
    Class cls = [self class];

    while (cls) {
        NSValue *value =
            gIntegerHookOriginals[XBBPHookKey(cls, cmd)];

        if (value) return [value pointerValue];

        cls = class_getSuperclass(cls);
    }

    return NULL;
}

static void XBBPObjectArgumentHook(id self, SEL cmd, id argument) {
    NSString *event =
        [NSString stringWithFormat:@"%@.%@",
         NSStringFromClass([self class]),
         NSStringFromSelector(cmd)];

    XBBPLog(@"SOURCE_OBJECT event=%@ self=%p argClass=%@ arg=%@",
            event,
            self,
            argument ? NSStringFromClass([argument class]) : @"nil",
            XBBPText(argument));

    NSString *resolvedUserID =
        XBBPTryResolveUserIDFromObject(self);
    if (!resolvedUserID.length)
        resolvedUserID = XBBPTryResolveUserIDFromObject(argument);

    if (resolvedUserID.length &&
        ![resolvedUserID isEqualToString:gActiveUserID]) {
        gActiveUserID = [resolvedUserID copy];
        XBBPLog(@"ACTIVE_USER_RESOLVED source=%@ userID=%@",
                event,
                gActiveUserID);

        if (gLastBadgeCountsByUserID)
            XBBPSelectCountsForAccountMap(
                gLastBadgeCountsByUserID,
                [event stringByAppendingString:@".resolvedActiveUser"]);
    }

    XBBPExtractCountsFromObject(argument,
                                [event stringByAppendingString:@".arg"],
                                0);

    XBBPExtractCountsFromObject(self,
                                [event stringByAppendingString:@".self.before"],
                                0);

    IMP original = XBBPOriginalObjectHook(self, cmd);

    if (original) {
        ((void(*)(id,SEL,id))original)(self, cmd, argument);
    }

    XBBPExtractCountsFromObject(self,
                                [event stringByAppendingString:@".self.after"],
                                0);
}

static void XBBPIntegerArgumentHook(id self, SEL cmd, NSInteger value) {
    NSString *event =
        [NSString stringWithFormat:@"%@.%@",
         NSStringFromClass([self class]),
         NSStringFromSelector(cmd)];

    XBBPLog(@"SOURCE_INTEGER event=%@ self=%p value=%ld",
            event,
            self,
            (long)value);

    if ([NSStringFromSelector(cmd) isEqualToString:@"updateBadgeCount:"] &&
        [NSStringFromClass([self class]) containsString:@"RootBadger"]) {
        gLastRootBadgeCount = value;
        XBBPLog(@"ROOT_BADGE_UPDATE class=%@ value=%ld",
                NSStringFromClass([self class]),
                (long)value);

        if (gLastBadgeCountsByUserID)
            XBBPSelectCountsForAccountMap(
                gLastBadgeCountsByUserID,
                [event stringByAppendingString:@".rootBadgeUpdate"]);
    }

    IMP original = XBBPOriginalIntegerHook(self, cmd);

    if (original) {
        ((void(*)(id,SEL,NSInteger))original)(self, cmd, value);
    }

    XBBPExtractCountsFromObject(self,
                                [event stringByAppendingString:@".self.after"],
                                0);
}

static BOOL XBBPEncodingIsOneObjectArg(Method method) {
    if (!method) return NO;

    NSMethodSignature *signature =
        [NSMethodSignature signatureWithObjCTypes:
            method_getTypeEncoding(method)];

    if (!signature || signature.numberOfArguments != 3) return NO;

    const char *arg = [signature getArgumentTypeAtIndex:2];
    return arg && arg[0] == '@';
}

static BOOL XBBPEncodingIsOneIntegerArg(Method method) {
    if (!method) return NO;

    NSMethodSignature *signature =
        [NSMethodSignature signatureWithObjCTypes:
            method_getTypeEncoding(method)];

    if (!signature || signature.numberOfArguments != 3) return NO;

    const char *arg = [signature getArgumentTypeAtIndex:2];

    if (!arg) return NO;

    return strchr("qQiIlLsScCB", arg[0]) != NULL;
}

static void XBBPInstallGenericSourceHooks(void) {
    if (!gObjectHookOriginals)
        gObjectHookOriginals = [NSMutableDictionary dictionary];

    if (!gIntegerHookOriginals)
        gIntegerHookOriginals = [NSMutableDictionary dictionary];

    NSArray<NSString *> *selectors = @[
        @"_t1_badgeCountDidUpdate:",
        @"_updateBadgeCountFromNotification:",
        @"setBadgeCounts:",
        @"setBadgeCountsForUserID:",
        @"updateBadgeCount:"
    ];

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes =
        (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);

    NSUInteger installed = 0;

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *className = NSStringFromClass(cls);

        if (!className.length) continue;

        NSString *lowerClass = className.lowercaseString;

        BOOL classRelevant =
            [lowerClass containsString:@"twitter"] ||
            [lowerClass containsString:@"badge"] ||
            [lowerClass containsString:@"notification"] ||
            [lowerClass containsString:@"appevent"];

        if (!classRelevant) continue;

        for (NSString *selectorName in selectors) {
            SEL sel = NSSelectorFromString(selectorName);

            Method directMethod = NULL;
            if (!XBBPDirectMethod(cls, sel, &directMethod)) continue;

            NSString *key = XBBPHookKey(cls, sel);
            if (gObjectHookOriginals[key] ||
                gIntegerHookOriginals[key]) {
                continue;
            }

            IMP original = class_getMethodImplementation(cls, sel);

            if (XBBPEncodingIsOneObjectArg(directMethod)) {
                gObjectHookOriginals[key] =
                    [NSValue valueWithPointer:original];

                class_replaceMethod(
                    cls,
                    sel,
                    (IMP)XBBPObjectArgumentHook,
                    method_getTypeEncoding(directMethod));

                XBBPLog(@"HOOK_SOURCE_OBJECT class=%@ selector=%@ encoding=%s",
                        className,
                        selectorName,
                        method_getTypeEncoding(directMethod));

                installed++;
                continue;
            }

            if (XBBPEncodingIsOneIntegerArg(directMethod)) {
                gIntegerHookOriginals[key] =
                    [NSValue valueWithPointer:original];

                class_replaceMethod(
                    cls,
                    sel,
                    (IMP)XBBPIntegerArgumentHook,
                    method_getTypeEncoding(directMethod));

                XBBPLog(@"HOOK_SOURCE_INTEGER class=%@ selector=%@ encoding=%s",
                        className,
                        selectorName,
                        method_getTypeEncoding(directMethod));

                installed++;
            } else {
                XBBPLog(@"HOOK_SOURCE_SKIPPED class=%@ selector=%@ encoding=%s",
                        className,
                        selectorName,
                        method_getTypeEncoding(directMethod));
            }
        }
    }

    free(classes);

    XBBPLog(@"SOURCE_HOOK_SCAN installed=%lu",
            (unsigned long)installed);
}

#pragma mark - Runtime probe

static void XBBPDumpCandidateClass(Class cls) {
    if (!cls) return;

    NSString *className = NSStringFromClass(cls);
    XBBPLog(@"CANDIDATE_CLASS_BEGIN %@", className);

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);

    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *name = ivar_getName(ivars[i]);
        const char *type = ivar_getTypeEncoding(ivars[i]);

        XBBPLog(@"CANDIDATE_IVAR class=%@ name=%s type=%s offset=%td",
                className,
                name ?: "-",
                type ?: "-",
                ivar_getOffset(ivars[i]));
    }

    free(ivars);

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);

    for (unsigned int i = 0; i < methodCount; i++) {
        NSString *name =
            NSStringFromSelector(method_getName(methods[i]));

        NSString *lower = name.lowercaseString;

        if (![lower containsString:@"badge"] &&
            ![lower containsString:@"unread"] &&
            ![lower containsString:@"count"] &&
            ![lower containsString:@"notification"]) {
            continue;
        }

        XBBPLog(@"CANDIDATE_METHOD class=%@ selector=%@ encoding=%s",
                className,
                name,
                method_getTypeEncoding(methods[i]) ?: "-");
    }

    free(methods);

    XBBPLog(@"CANDIDATE_CLASS_END %@", className);
}

static void XBBPRuntimeProbe(void) {
    XBBPLog(@"RUNTIME_PROBE_BEGIN");

    NSArray<NSString *> *exactNames = @[
        @"TwitterNotifications.TFSTwitterBadgeCounts",
        @"_TtC20TwitterNotifications21TFSTwitterBadgeCounts",
        @"TFSTwitterAPIBadgeCountsCommand",
        @"TFSTwitterAPIBadgeCountResponseBuilder",
        @"TFSTwitterCore.BadgeCountsQueryAdapter",
        @"_TtC14TFSTwitterCore23BadgeCountsQueryAdapter",
        @"T1AppEventHandler",
        @"T1AppDelegate",
        @"XNavigation.TabBarController",
        @"XNavigation.TabBarView",
        @"XNavigation.TabBarItemView"
    ];

    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (NSString *name in exactNames) {
        Class cls = NSClassFromString(name);

        if (!cls && [name hasPrefix:@"_TtC"]) {
            cls = objc_getClass(name.UTF8String);
        }

        if (!cls) continue;

        NSString *actual = NSStringFromClass(cls);
        if ([seen containsObject:actual]) continue;

        [seen addObject:actual];
        XBBPDumpCandidateClass(cls);
    }

    int count = objc_getClassList(NULL, 0);
    if (count > 0) {
        Class *classes =
            (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
        count = objc_getClassList(classes, count);

        for (int i = 0; i < count; i++) {
            Class cls = classes[i];
            NSString *name = NSStringFromClass(cls);
            NSString *lower = name.lowercaseString;

            if (![lower containsString:@"badgecount"] &&
                ![lower containsString:@"unreadbadge"]) {
                continue;
            }

            if ([seen containsObject:name]) continue;

            [seen addObject:name];
            XBBPDumpCandidateClass(cls);
        }

        free(classes);
    }

    XBBPLog(@"RUNTIME_PROBE_END");
}

#pragma mark - Notification observer

static BOOL XBBPInterestingNotificationName(NSString *name) {
    NSString *lower = name.lowercaseString ?: @"";

    return [lower containsString:@"badge"] ||
           [lower containsString:@"unread"] ||
           [lower containsString:@"notificationcount"] ||
           [lower containsString:@"messagecount"];
}

static void XBBPInstallNotificationObserver(void) {
    if (gNotificationObserver) return;

    gNotificationObserver =
        [NSNotificationCenter.defaultCenter
            addObserverForName:nil
                       object:nil
                        queue:nil
                   usingBlock:^(NSNotification *notification) {
        if (!XBBPInterestingNotificationName(notification.name)) return;

        XBBPLog(@"OBSERVED_NOTIFICATION name=%@ objectClass=%@ object=%@ userInfo=%@",
                notification.name,
                notification.object
                    ? NSStringFromClass([notification.object class])
                    : @"nil",
                XBBPText(notification.object),
                XBBPText(notification.userInfo));

        XBBPExtractCountsFromObject(
            notification,
            [NSString stringWithFormat:@"NSNotification:%@",
             notification.name ?: @"-"],
            0);
    }];

    XBBPLog(@"Installed filtered NSNotification badge observer.");
}

#pragma mark - NFB UI

@interface XLiquidGlassBadgeBridgeProbeViewController : UITableViewController
@end

@implementation XLiquidGlassBadgeBridgeProbeViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Badge Bridge Probe";
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;

    return @"Experimental: captura contadores do subsistema de badges e os espelha na Tab Bar Liquid Glass. O relatório mostra a fonte usada.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"XBBPCell";

    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {
        cell =
            [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleSubtitle
              reuseIdentifier:identifier];
    }

    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (indexPath.row == 0) {
        cell.textLabel.text = @"Estado atual";
        cell.detailTextLabel.text =
            [NSString stringWithFormat:
                @"Notificações: %ld · DM: %ld · XChat: %ld · Total: %ld · Conta: %@",
                (long)gNTabCount,
                (long)gDMCount,
                (long)gXChatCount,
                (long)gTotalCount,
                gActiveUserID ?: @"?"];
    } else if (indexPath.row == 1) {
        cell.textLabel.text = @"Atualizar badges";
        cell.detailTextLabel.text =
            @"Reaplica os valores capturados.";
    } else if (indexPath.row == 2) {
        cell.textLabel.text = @"Copiar relatório";
        cell.detailTextLabel.text = kXBBPLogFileName;
    } else {
        cell.textLabel.text = @"Limpar relatório";
        cell.detailTextLabel.text =
            @"Mantém a correção ativa.";
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.row == 0) {
        XBBPRuntimeProbe();
        [tableView reloadData];
        return;
    }

    if (indexPath.row == 1) {
        XBBPRefreshVisibleBadges();
        XBBPLog(@"MANUAL_REFRESH ntab=%ld dm=%ld xchat=%ld total=%ld",
                (long)gNTabCount,
                (long)gDMCount,
                (long)gXChatCount,
                (long)gTotalCount);
        [tableView reloadData];
        return;
    }

    if (indexPath.row == 2) {
        NSString *report =
            [NSString stringWithContentsOfFile:XBBPLogPath()
                                      encoding:NSUTF8StringEncoding
                                         error:nil] ?: @"";

        UIPasteboard.generalPasteboard.string = report;

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:@"Badge Bridge Probe"
                                 message:
                    [NSString stringWithFormat:
                        @"Relatório copiado (%lu caracteres).",
                        (unsigned long)report.length]
                          preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction actionWithTitle:@"OK"
                                     style:UIAlertActionStyleDefault
                                   handler:nil]];

        [self presentViewController:alert
                           animated:YES
                         completion:nil];
        return;
    }

    [[NSFileManager defaultManager]
        removeItemAtPath:XBBPLogPath()
                   error:nil];

    XBBPLog(@"LOG RESET ntab=%ld dm=%ld xchat=%ld total=%ld",
            (long)gNTabCount,
            (long)gDMCount,
            (long)gXChatCount,
            (long)gTotalCount);

    [tableView reloadData];
}

@end

static BOOL XBBPSectionsContainEntry(NSArray *sections) {
    for (id entry in sections) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;

        if ([entry[@"action"]
                isEqualToString:@"showXLiquidGlassBadgeBridgeProbe"]) {
            return YES;
        }
    }

    return NO;
}

static void XBBPInjectNFBSection(id controller) {
    NSArray *sections = nil;

    @try {
        sections = [controller valueForKey:@"sections"];
    } @catch (__unused NSException *exception) {
        return;
    }

    if (![sections isKindOfClass:NSArray.class] ||
        XBBPSectionsContainEntry(sections)) {
        return;
    }

    NSMutableArray *updated = [sections mutableCopy];

    [updated addObject:@{
        @"title": @"Badge Bridge Probe",
        @"subtitle": @"Correção experimental + diagnóstico.",
        @"icon": @"bell",
        @"action": @"showXLiquidGlassBadgeBridgeProbe"
    }];

    @try {
        [controller setValue:[updated copy]
                      forKey:@"sections"];
    } @catch (__unused NSException *exception) {
    }
}

static void XBBPNFBSetupSections(id self, SEL cmd) {
    if (gOrigNFBSetupSections) {
        ((void(*)(id,SEL))gOrigNFBSetupSections)(self, cmd);
    }

    XBBPInjectNFBSection(self);
}

static void XBBPNFBViewWillAppear(id self,
                                  SEL cmd,
                                  BOOL animated) {
    if (gOrigNFBViewWillAppear) {
        ((void(*)(id,SEL,BOOL))gOrigNFBViewWillAppear)(
            self, cmd, animated);
    }

    XBBPInjectNFBSection(self);

    UITableView *tableView = nil;

    @try {
        tableView = [self valueForKey:@"tableView"];
    } @catch (__unused NSException *exception) {
    }

    [tableView reloadData];
}

static void XBBPShowSettings(id self, SEL cmd) {
    (void)cmd;

    if (![self isKindOfClass:UIViewController.class]) return;

    XLiquidGlassBadgeBridgeProbeViewController *vc =
        [XLiquidGlassBadgeBridgeProbeViewController new];

    UINavigationController *nav =
        ((UIViewController *)self).navigationController;

    if (nav) {
        [nav pushViewController:vc animated:YES];
    } else {
        UINavigationController *wrapper =
            [[UINavigationController alloc]
                initWithRootViewController:vc];

        [(UIViewController *)self
            presentViewController:wrapper
                         animated:YES
                       completion:nil];
    }
}

static void XBBPInstallNFBIntegration(void) {
    Class cls =
        NSClassFromString(@"ModernSettingsViewController");

    if (!cls) return;

    class_addMethod(
        cls,
        NSSelectorFromString(@"showXLiquidGlassBadgeBridgeProbe"),
        (IMP)XBBPShowSettings,
        "v@:");

    if (!gOrigNFBSetupSections) {
        XBBPHookMethod(cls,
                       NSSelectorFromString(@"setupSections"),
                       (IMP)XBBPNFBSetupSections,
                       &gOrigNFBSetupSections);
    }

    if (!gOrigNFBViewWillAppear) {
        XBBPHookMethod(cls,
                       @selector(viewWillAppear:),
                       (IMP)XBBPNFBViewWillAppear,
                       &gOrigNFBViewWillAppear);
    }
}

#pragma mark - Install

static void XBBPInstallAll(void) {
    XBBPInstallXNavItemHook();
    XBBPInstallGenericSourceHooks();
    XBBPInstallNotificationObserver();
    XBBPInstallNFBIntegration();
}

static void XBBPRetry(NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            XBBPInstallAll();
            XBBPRefreshVisibleBadges();
        });
}

__attribute__((constructor))
static void XLiquidGlassBadgeBridgeProbeInit(void) {
    @autoreleasepool {
        XBBPLog(@"========== XLiquidGlass Badge Bridge Probe 0.1.1 loaded ==========");
        XBBPLog(@"logPath=%@", XBBPLogPath());

        XBBPLoadPersistedCounts();
        XBBPInstallAll();

        XBBPRetry(0.05);
        XBBPRetry(0.20);
        XBBPRetry(0.50);
        XBBPRetry(1.00);
        XBBPRetry(2.00);
        XBBPRetry(4.00);

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(2.5 * NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{
                XBBPRuntimeProbe();
                XBBPRefreshVisibleBadges();
            });
    }
}
