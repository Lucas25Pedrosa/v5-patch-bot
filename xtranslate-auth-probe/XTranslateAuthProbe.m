#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kLogName = @"XTranslateGrokPrivateFactoryFix.log";
static const NSTimeInterval kWindow = 15.0;
static const NSUInteger kMaxBytes = 3 * 1024 * 1024;

static IMP gOrigDataTask = NULL;
static IMP gOrigDataTaskCompletion = NULL;
static IMP gOrigUploadData = NULL;
static IMP gOrigUploadFile = NULL;
static IMP gOrigResume = NULL;
static IMP gOrigPrivateDataTaskDelegate = NULL;
static IMP gOrigPrivateDataTaskDelegateCompletion = NULL;
static IMP gOrigDataTaskUniqueIdentifier = NULL;
static IMP gOrigNFBSetup = NULL;
static IMP gOrigNFBAppear = NULL;

static BOOL gHooked = NO;
static BOOL gNFBHooked = NO;
static NSTimeInterval gArmedUntil = 0;
static NSString *gLabel = nil;
static NSUInteger gReqSeq = 0;
static NSString *gCapturedNativeBearer = nil;
static char kTaskMetaKey;

static NSString *MaskedUID(id account);
static id CurrentAccount(void);

static NSString *LogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs.length) docs = NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:kLogName];
}

static NSString *Stamp(void) {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSDateFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [f stringFromDate:NSDate.date];
}

static void Trim(void) {
    NSString *p = LogPath();
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    unsigned long long s = [a fileSize];
    if (s <= kMaxBytes) return;
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (d.length <= kMaxBytes) return;
    NSUInteger keep = kMaxBytes / 2;
    [[d subdataWithRange:NSMakeRange(d.length-keep, keep)] writeToFile:p atomically:YES];
}

static void Log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void Log(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", Stamp(), body ?: @""];
    NSLog(@"[XTranslateAuthProbe] %@", body ?: @"");
    @synchronized([NSFileManager defaultManager]) {
        NSString *p = LogPath();
        if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
            [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
        Trim();
    }
}

static BOOL Armed(void) {
    return gLabel.length && NSDate.date.timeIntervalSince1970 < gArmedUntil;
}

static BOOL Hook(Class cls, SEL sel, IMP replacement, IMP *orig) {
    if (!cls || !sel || !replacement) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP current = class_getMethodImplementation(cls, sel);
    if (current == replacement) return YES;
    if (orig && !*orig) *orig = current;
    const char *types = method_getTypeEncoding(m);
    if (!types) return NO;
    class_replaceMethod(cls, sel, replacement, types);
    return class_getMethodImplementation(cls, sel) == replacement;
}

static NSString *Header(NSURLRequest *r, NSString *name) {
    NSString *v = [r valueForHTTPHeaderField:name];
    if (!v.length) v = [r valueForHTTPHeaderField:name.lowercaseString];
    return v ?: @"";
}

static NSString *MaskUID(NSString *uid) {
    if (!uid.length) return @"-";
    if (uid.length <= 4) return uid;
    return [NSString stringWithFormat:@"…%@", [uid substringFromIndex:uid.length - 4]];
}

static NSString *OAuthUIDFull(NSURLRequest *r) {
    NSString *a = Header(r, @"Authorization");
    if (!a.length) return nil;
    NSRange m = [a rangeOfString:@"oauth_token=\""];
    if (m.location == NSNotFound) return nil;
    NSString *rest = [a substringFromIndex:NSMaxRange(m)];
    NSRange q = [rest rangeOfString:@"\""];
    if (q.location == NSNotFound) return nil;
    NSString *token = [rest substringToIndex:q.location];
    NSRange dash = [token rangeOfString:@"-"];
    return dash.location != NSNotFound ? [token substringToIndex:dash.location] : token;
}

static NSString *OAuthUID(NSURLRequest *r) {
    return MaskUID(OAuthUIDFull(r));
}

static BOOL IsCookieLoginUID(NSString *uid) {
    if (!uid.length) return NO;
    NSArray *uids = [[NSUserDefaults standardUserDefaults] arrayForKey:@"nfb_cookie_login_userids"];
    return [uids isKindOfClass:NSArray.class] && [uids containsObject:uid];
}

static NSDictionary *CachedWebPair(NSString *uid) {
    if (!uid.length) return nil;
    NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"nfb_web_account_cookies"];
    id pair = [all isKindOfClass:NSDictionary.class] ? all[uid] : nil;
    return [pair isKindOfClass:NSDictionary.class] ? pair : nil;
}

static void ObserveNativeBearer(NSURLRequest *r) {
    NSString *auth = Header(r, @"Authorization");
    if (!auth.length) return;
    if (![auth.lowercaseString hasPrefix:@"bearer "]) return;
    if (Header(r, @"x-twitter-auth-type").length) return;
    gCapturedNativeBearer = [auth copy];
}

static NSString *CookieUID(NSURLRequest *r) {
    NSString *c = Header(r, @"Cookie");
    if (!c.length) return @"-";
    NSRange m = [c rangeOfString:@"twid=" options:NSCaseInsensitiveSearch];
    if (m.location == NSNotFound) return @"-";
    NSString *rest = [c substringFromIndex:NSMaxRange(m)];
    NSRange semi = [rest rangeOfString:@";"];
    NSString *twid = semi.location == NSNotFound ? rest : [rest substringToIndex:semi.location];
    NSString *decoded = [twid stringByRemovingPercentEncoding] ?: twid;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    NSString *uid = [[decoded componentsSeparatedByCharactersInSet:nonDigits] componentsJoinedByString:@""];
    return MaskUID(uid);
}

static NSString *AuthShape(NSURLRequest *r) {
    NSString *a = Header(r, @"Authorization");
    if (!a.length) return @"none";
    NSString *l = a.lowercaseString;
    if ([l hasPrefix:@"oauth "]) return [l containsString:@"oauth_token="] ? @"oauth1(token)" : @"oauth1";
    if ([l hasPrefix:@"bearer "]) return @"bearer";
    return @"other";
}

static NSString *CookieShape(NSURLRequest *r) {
    NSString *c = Header(r, @"Cookie").lowercaseString;
    NSMutableArray *p=[NSMutableArray array];
    if ([c containsString:@"auth_token="]) [p addObject:@"auth_token"];
    if ([c containsString:@"ct0="]) [p addObject:@"ct0"];
    if ([c containsString:@"twid="]) [p addObject:@"twid"];
    if ([c containsString:@"auth_multi="]) [p addObject:@"auth_multi"];
    return p.count ? [p componentsJoinedByString:@","] : @"none";
}

static NSString *KeywordHint(NSURLRequest *r) {
    NSMutableString *s=[NSMutableString string];
    if (r.URL.absoluteString) [s appendString:r.URL.absoluteString.lowercaseString];
    NSData *body=r.HTTPBody;
    if (body.length && body.length < 65536) {
        NSString *b=[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (b.length) [s appendString:b.lowercaseString];
    }
    NSMutableArray *hits=[NSMutableArray array];
    for (NSString *k in @[@"translate",@"translation",@"grok",@"language"]) {
        if ([s containsString:k]) [hits addObject:k];
    }
    return hits.count ? [hits componentsJoinedByString:@","] : @"-";
}

static BOOL IsXHost(NSURLRequest *r) {
    NSString *h=r.URL.host.lowercaseString ?: @"";
    return [h containsString:@"twitter.com"] || [h hasSuffix:@"x.com"] || [h containsString:@"api.x.com"];
}

static NSString *Operation(NSURLRequest *r) {
    NSString *path=r.URL.path ?: @"";
    NSArray *parts=[path componentsSeparatedByString:@"/"];
    if ([path containsString:@"/graphql/"] && parts.count) return parts.lastObject ?: @"-";
    NSString *last = [parts.lastObject isKindOfClass:NSString.class] ? (NSString *)parts.lastObject : nil;
    return last.length ? last : path;
}

static NSString *BootstrapTag(NSURLRequest *r) {
    NSString *op=Operation(r);
    if ([op isEqualToString:@"GrokAccountJwt"]) return @"GROK_JWT";
    if ([op isEqualToString:@"ViewerUser"]) return @"VIEWER_USER";
    return nil;
}

static void LogBootstrapStack(NSUInteger seq, NSURLRequest *r) {
    NSString *tag=BootstrapTag(r);
    if (!tag.length) return;
    Log(@"========== BOOTSTRAP %@ #%lu ==========", tag, (unsigned long)seq);
    Log(@"BOOTSTRAP account=%@ op=%@ host=%@ path=%@ auth=%@ oauthUID=%@ cookieUID=%@",
        MaskedUID(CurrentAccount()), Operation(r), r.URL.host ?: @"-", r.URL.path ?: @"-",
        AuthShape(r), OAuthUID(r), CookieUID(r));
    NSArray<NSString*> *stack=[NSThread callStackSymbols];
    NSUInteger limit=MIN((NSUInteger)28, stack.count);
    for (NSUInteger i=0;i<limit;i++) {
        Log(@"STACK %@ #%lu frame=%02lu %@", tag, (unsigned long)seq,
            (unsigned long)i, stack[i]);
    }
}

static NSString *JoinedSortedStrings(NSArray *values) {
    if (![values isKindOfClass:NSArray.class] || values.count==0) return @"-";
    NSMutableArray *clean=[NSMutableArray array];
    for (id v in values) if ([v isKindOfClass:NSString.class] && [v length]) [clean addObject:v];
    if (!clean.count) return @"-";
    [clean sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return [clean componentsJoinedByString:@","];
}

static NSString *HeaderNames(NSURLRequest *r) {
    return JoinedSortedStrings(r.allHTTPHeaderFields.allKeys ?: @[]);
}

static NSString *QueryKeys(NSURLRequest *r) {
    NSURLComponents *c=[NSURLComponents componentsWithURL:r.URL resolvingAgainstBaseURL:NO];
    NSMutableOrderedSet *names=[NSMutableOrderedSet orderedSet];
    for (NSURLQueryItem *q in c.queryItems ?: @[]) if (q.name.length) [names addObject:q.name];
    return JoinedSortedStrings(names.array);
}

static NSString *BodyKeys(NSURLRequest *r) {
    NSData *d=r.HTTPBody;
    if (!d.length || d.length > 131072) return d.length?@"(opaque)":@"-";
    NSString *ct=Header(r,@"content-type").lowercaseString ?: @"";
    if ([ct containsString:@"application/json"]) {
        id obj=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if ([obj isKindOfClass:NSDictionary.class]) return JoinedSortedStrings([(NSDictionary*)obj allKeys]);
        return @"(json)";
    }
    if ([ct containsString:@"application/x-www-form-urlencoded"]) {
        NSString *body=[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        NSMutableOrderedSet *names=[NSMutableOrderedSet orderedSet];
        for (NSString *part in [body componentsSeparatedByString:@"&"]) {
            NSString *name=[[part componentsSeparatedByString:@"="] firstObject];
            if (name.length) [names addObject:name.stringByRemovingPercentEncoding ?: name];
        }
        return JoinedSortedStrings(names.array);
    }
    return @"(opaque)";
}

static void LogTaskShape(NSString *phase, NSUInteger seq, NSURLSessionTask *task, NSURLRequest *r) {
    if (!r) {
        Log(@"TASKSHAPE %@ #%lu class=%@ request=nil",phase,(unsigned long)seq,NSStringFromClass(task.class));
        return;
    }
    Log(@"TASKSHAPE %@ #%lu class=%@ headers=[%@] queryKeys=[%@] bodyKeys=[%@] contentType=%@",
        phase,(unsigned long)seq,NSStringFromClass(task.class),HeaderNames(r),QueryKeys(r),BodyKeys(r),
        Header(r,@"content-type").length?Header(r,@"content-type"):@"-");
}

static void LogExternalRequest(NSString *phase, NSUInteger seq, NSURLRequest *r) {
    if (!r) { Log(@"EXT %@ #%lu nil", phase, (unsigned long)seq); return; }
    Log(@"EXT %@ #%lu label=%@ method=%@ host=%@ path=%@ body=%lu hint=%@",
        phase, (unsigned long)seq, gLabel ?: @"-",
        r.HTTPMethod ?: @"GET",
        r.URL.host ?: @"-",
        r.URL.path ?: @"-",
        (unsigned long)r.HTTPBody.length,
        KeywordHint(r));
}

static void LogRequest(NSString *phase, NSUInteger seq, NSURLRequest *r) {
    if (!r) { Log(@"REQ %@ #%lu nil", phase, (unsigned long)seq); return; }
    if (!IsXHost(r)) { LogExternalRequest(phase, seq, r); return; }
    Log(@"REQ %@ #%lu label=%@ method=%@ host=%@ op=%@ path=%@ auth=%@ oauthUID=%@ authTypeHdr=%@ csrf=%d cookies=%@ cookieUID=%@ xtid=%d body=%lu hint=%@",
        phase, (unsigned long)seq, gLabel ?: @"-",
        r.HTTPMethod ?: @"GET",
        r.URL.host ?: @"-",
        Operation(r),
        r.URL.path ?: @"-",
        AuthShape(r),
        OAuthUID(r),
        Header(r, @"x-twitter-auth-type").length ? Header(r, @"x-twitter-auth-type") : @"-",
        Header(r, @"x-csrf-token").length > 0,
        CookieShape(r),
        CookieUID(r),
        Header(r, @"x-client-transaction-id").length > 0,
        (unsigned long)r.HTTPBody.length,
        KeywordHint(r));
}

static NSString *MaskedUID(id account) {
    if (!account || ![account respondsToSelector:NSSelectorFromString(@"userID")]) return @"-";
    long long uid=((long long(*)(id,SEL))objc_msgSend)(account, NSSelectorFromString(@"userID"));
    NSString *s=[NSString stringWithFormat:@"%lld",uid];
    if (s.length<=4) return s;
    return [NSString stringWithFormat:@"…%@",[s substringFromIndex:s.length-4]];
}

static id CurrentAccount(void) {
    Class c=NSClassFromString(@"T1HostViewController");
    SEL shared=NSSelectorFromString(@"sharedHostViewController");
    if (!c || ![c respondsToSelector:shared]) return nil;
    id host=((id(*)(id,SEL))objc_msgSend)(c,shared);
    SEL cur=NSSelectorFromString(@"currentAccount");
    if (host && [host respondsToSelector:cur]) return ((id(*)(id,SEL))objc_msgSend)(host,cur);
    return nil;
}

static void LogAccountState(void) {
    id acct=CurrentAccount();
    NSString *uidFull=@"";
    if (acct && [acct respondsToSelector:NSSelectorFromString(@"userID")]) {
        long long uid=((long long(*)(id,SEL))objc_msgSend)(acct,NSSelectorFromString(@"userID"));
        uidFull=[NSString stringWithFormat:@"%lld",uid];
    }
    NSArray *cookieUsers=[[NSUserDefaults standardUserDefaults] arrayForKey:@"nfb_cookie_login_userids"] ?: @[];
    BOOL cookieLogin=uidFull.length && [cookieUsers containsObject:uidFull];
    Log(@"ACCOUNT label=%@ class=%@ uid=%@ cookieLogin=%d cookieLoginCount=%lu",
        gLabel ?: @"-", acct?NSStringFromClass([acct class]):@"nil", MaskedUID(acct),
        cookieLogin, (unsigned long)cookieUsers.count);

    Class sw=NSClassFromString(@"TFSAccountFeatureSwitches");
    SEL last=NSSelectorFromString(@"lastUsedAccountFeatureSwitches");
    id accsw=(sw && [sw respondsToSelector:last]) ? ((id(*)(id,SEL))objc_msgSend)(sw,last) : nil;
    id provider=nil;
    if (accsw && [accsw respondsToSelector:NSSelectorFromString(@"provider")])
        provider=((id(*)(id,SEL))objc_msgSend)(accsw,NSSelectorFromString(@"provider"));
    if (provider && [provider respondsToSelector:NSSelectorFromString(@"boolForKey:")]) {
        for (NSString *key in @[@"grok_translations_notification_auto_translation_is_enabled",
                                @"grok_translations_immersive_auto_translate_is_enabled"]) {
            BOOL v=((BOOL(*)(id,SEL,id))objc_msgSend)(provider,NSSelectorFromString(@"boolForKey:"),key);
            Log(@"FEATURE %@=%d",key,v);
        }
    }
}

static NSDictionary *MetaForTask(NSURLSessionTask *task) {
    return objc_getAssociatedObject(task, &kTaskMetaKey);
}

static void AttachTask(NSURLSessionTask *task, NSUInteger seq) {
    if (!task) return;
    NSDictionary *m=@{@"seq":@(seq),@"label":gLabel ?: @"-"};
    objc_setAssociatedObject(task,&kTaskMetaKey,m,OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak NSURLSessionTask *weakTask=task;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        for (int i=0;i<100;i++) {
            NSURLSessionTask *t=weakTask;
            if (!t) return;
            if (t.state==NSURLSessionTaskStateCompleted) {
                NSHTTPURLResponse *resp=[t.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse*)t.response : nil;
                NSError *err=t.error;
                Log(@"DONE #%lu label=%@ status=%ld errorDomain=%@ errorCode=%ld",
                    (unsigned long)seq, m[@"label"], (long)resp.statusCode,
                    err.domain ?: @"-", (long)err.code);
                return;
            }
            [NSThread sleepForTimeInterval:0.2];
        }
    });
}

static NSURLSessionDataTask *ProbeDataTask(NSURLSession *self, SEL _cmd, NSURLRequest *request) {
    if (!gOrigDataTask) return nil;
    ObserveNativeBearer(request);
    BOOL special=BootstrapTag(request).length > 0;
    if (!Armed() && !special)
        return ((id(*)(id,SEL,id))gOrigDataTask)(self,_cmd,request);

    NSUInteger seq=++gReqSeq;
    LogRequest(@"IN",seq,request);
    if (special) LogBootstrapStack(seq,request);
    NSURLSessionDataTask *task=((id(*)(id,SEL,id))gOrigDataTask)(self,_cmd,request);
    LogRequest(@"TASK",seq,task.currentRequest ?: task.originalRequest);
    AttachTask(task,seq);
    return task;
}

static NSURLSessionDataTask *ProbeDataTaskCompletion(NSURLSession *self, SEL _cmd, NSURLRequest *request, id completion) {
    if (!gOrigDataTaskCompletion) return nil;
    ObserveNativeBearer(request);
    BOOL special=BootstrapTag(request).length > 0;
    if (!Armed() && !special)
        return ((id(*)(id,SEL,id,id))gOrigDataTaskCompletion)(self,_cmd,request,completion);

    NSUInteger seq=++gReqSeq;
    LogRequest(@"IN",seq,request);
    if (special) LogBootstrapStack(seq,request);
    NSURLSessionDataTask *task=((id(*)(id,SEL,id,id))gOrigDataTaskCompletion)(self,_cmd,request,completion);
    LogRequest(@"TASK",seq,task.currentRequest ?: task.originalRequest);
    AttachTask(task,seq);
    return task;
}

static NSURLSessionUploadTask *ProbeUploadData(NSURLSession *self, SEL _cmd, NSURLRequest *request, NSData *data) {
    if (!gOrigUploadData) return nil;
    if (!Armed())
        return ((id(*)(id,SEL,id,id))gOrigUploadData)(self,_cmd,request,data);
    NSUInteger seq=++gReqSeq;
    LogRequest(@"IN-UPLOAD",seq,request);
    NSURLSessionUploadTask *task=((id(*)(id,SEL,id,id))gOrigUploadData)(self,_cmd,request,data);
    LogRequest(@"TASK-UPLOAD",seq,task.currentRequest ?: task.originalRequest);
    AttachTask(task,seq);
    return task;
}

static NSURLSessionUploadTask *ProbeUploadFile(NSURLSession *self, SEL _cmd, NSURLRequest *request, NSURL *fileURL) {
    if (!gOrigUploadFile) return nil;
    if (!Armed())
        return ((id(*)(id,SEL,id,id))gOrigUploadFile)(self,_cmd,request,fileURL);
    NSUInteger seq=++gReqSeq;
    LogRequest(@"IN-UPLOADFILE",seq,request);
    NSURLSessionUploadTask *task=((id(*)(id,SEL,id,id))gOrigUploadFile)(self,_cmd,request,fileURL);
    LogRequest(@"TASK-UPLOADFILE",seq,task.currentRequest ?: task.originalRequest);
    AttachTask(task,seq);
    return task;
}

static BOOL IsGrokRESTRequest(NSURLRequest *r) {
    NSString *path = r.URL.path ?: @"";
    return [path hasPrefix:@"/2/grok/"];
}

static NSURLRequest *RewritePrivateGrokRequestIfNeeded(NSURLRequest *request) {
    if (!IsGrokRESTRequest(request)) return request;

    NSString *uid = OAuthUIDFull(request);
    if (!uid.length || !IsCookieLoginUID(uid)) {
        Log(@"GROK_PRIVATE_FIX skip op=%@ uid=%@ reason=not-web-login",
            Operation(request), MaskUID(uid));
        return request;
    }

    NSDictionary *pair = CachedWebPair(uid);
    NSString *authToken = [pair[@"auth_token"] isKindOfClass:NSString.class] ? pair[@"auth_token"] : nil;
    NSString *ct0 = [pair[@"ct0"] isKindOfClass:NSString.class] ? pair[@"ct0"] : nil;
    if (!authToken.length || !ct0.length || !gCapturedNativeBearer.length) {
        Log(@"GROK_PRIVATE_FIX skip op=%@ uid=%@ reason=missing-context auth=%d ct0=%d bearer=%d",
            Operation(request), MaskUID(uid), authToken.length>0, ct0.length>0, gCapturedNativeBearer.length>0);
        return request;
    }

    NSMutableURLRequest *out = [request mutableCopy];
    out.HTTPShouldHandleCookies = NO;
    [out setValue:nil forHTTPHeaderField:@"Authorization"];
    [out setValue:nil forHTTPHeaderField:@"authorization"];
    [out setValue:nil forHTTPHeaderField:@"X-B3-TraceId"];
    [out setValue:nil forHTTPHeaderField:@"Host"];
    [out setValue:gCapturedNativeBearer forHTTPHeaderField:@"authorization"];
    [out setValue:ct0 forHTTPHeaderField:@"x-csrf-token"];
    [out setValue:[NSString stringWithFormat:@"auth_token=%@; ct0=%@; twid=u%%3D%@",
                   authToken, ct0, uid]
forHTTPHeaderField:@"Cookie"];

    Log(@"GROK_PRIVATE_FIX rewrite op=%@ uid=%@ path=%@ auth=%@ csrf=%d cookies=%@",
        Operation(out), MaskUID(uid), out.URL.path ?: @"-",
        AuthShape(out), Header(out, @"x-csrf-token").length>0, CookieShape(out));
    return out;
}

static NSURLSessionDataTask *PrivateDataTaskDelegate(NSURLSession *self, SEL _cmd, NSURLRequest *request, id delegate) {
    ObserveNativeBearer(request);
    NSURLRequest *effective = RewritePrivateGrokRequestIfNeeded(request);
    if (effective != request) {
        NSUInteger seq = ++gReqSeq;
        LogRequest(@"PRIVATE_IN", seq, request);
        LogRequest(@"PRIVATE_OUT", seq, effective);
        NSURLSessionDataTask *task = ((id(*)(id,SEL,id,id))gOrigPrivateDataTaskDelegate)(self,_cmd,effective,delegate);
        AttachTask(task, seq);
        return task;
    }
    if (IsGrokRESTRequest(request)) {
        Log(@"PRIVATE_FACTORY pass op=%@ sessionClass=%@ delegateClass=%@",
            Operation(request),NSStringFromClass(self.class),delegate?NSStringFromClass([delegate class]):@"nil");
    }
    return ((id(*)(id,SEL,id,id))gOrigPrivateDataTaskDelegate)(self,_cmd,request,delegate);
}

static NSURLSessionDataTask *PrivateDataTaskDelegateCompletion(NSURLSession *self, SEL _cmd, NSURLRequest *request, id delegate, id completion) {
    ObserveNativeBearer(request);
    NSURLRequest *effective = RewritePrivateGrokRequestIfNeeded(request);
    if (effective != request) {
        NSUInteger seq = ++gReqSeq;
        LogRequest(@"PRIVATE_COMPLETION_IN", seq, request);
        LogRequest(@"PRIVATE_COMPLETION_OUT", seq, effective);
        NSURLSessionDataTask *task = ((id(*)(id,SEL,id,id,id))gOrigPrivateDataTaskDelegateCompletion)(self,_cmd,effective,delegate,completion);
        AttachTask(task, seq);
        return task;
    }
    return ((id(*)(id,SEL,id,id,id))gOrigPrivateDataTaskDelegateCompletion)(self,_cmd,request,delegate,completion);
}

static NSURLSessionDataTask *DataTaskUniqueIdentifier(NSURLSession *self, SEL _cmd, NSURLRequest *request, id identifier) {
    ObserveNativeBearer(request);
    return ((id(*)(id,SEL,id,id))gOrigDataTaskUniqueIdentifier)(self,_cmd,request,identifier);
}

static void ProbeResume(NSURLSessionTask *self, SEL _cmd) {
    NSDictionary *m=MetaForTask(self);
    NSURLRequest *r=self.currentRequest ?: self.originalRequest;
    if (m) {
        NSUInteger seq=[m[@"seq"] unsignedIntegerValue];
        LogRequest(@"RESUME",seq,r);
        if (Armed()) LogTaskShape(@"RESUME",seq,self,r);
    } else if (Armed()) {
        NSUInteger seq=++gReqSeq;
        LogRequest(@"RESUME-UNTRACKED",seq,r);
        LogTaskShape(@"RESUME-UNTRACKED",seq,self,r);
        AttachTask(self,seq);
    }
    if (gOrigResume) ((void(*)(id,SEL))gOrigResume)(self,_cmd);
}

static BOOL SelectorLooksRelevant(NSString *name) {
    NSString *n=name.lowercaseString ?: @"";
    return [n containsString:@"task"] || [n containsString:@"request"] ||
           [n containsString:@"resume"] || [n containsString:@"session"];
}

static void DumpRelevantMethodsForClassName(NSString *className) {
    Class c=NSClassFromString(className);
    if (!c) {
        Log(@"FACTORY class=%@ missing",className);
        return;
    }
    for (Class k=c; k && k!=NSObject.class; k=class_getSuperclass(k)) {
        unsigned int count=0;
        Method *methods=class_copyMethodList(k,&count);
        NSMutableArray *rows=[NSMutableArray array];
        for (unsigned int i=0;i<count;i++) {
            SEL sel=method_getName(methods[i]);
            NSString *name=NSStringFromSelector(sel);
            if (!SelectorLooksRelevant(name)) continue;
            const char *enc=method_getTypeEncoding(methods[i]);
            [rows addObject:[NSString stringWithFormat:@"%@|%@",name,enc?@(enc):@"?"]];
        }
        if (methods) free(methods);
        [rows sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        Log(@"FACTORY class=%@ owner=%@ count=%lu",className,NSStringFromClass(k),(unsigned long)rows.count);
        for (NSString *row in rows) Log(@"FACTORY_METHOD class=%@ owner=%@ %@",className,NSStringFromClass(k),row);
    }
}

static void DumpFocusedTaskFactories(void) {
    Log(@"========== FOCUSED TASK FACTORIES ==========");
    for (NSString *name in @[@"__NSURLSessionLocal",@"__NSCFURLSession",@"__NSCFLocalDataTask"]) {
        DumpRelevantMethodsForClassName(name);
    }
}

static void InstallNetworkHooks(void) {
    if (gHooked) return;
    BOOL any=NO;
    any |= Hook(NSURLSession.class,@selector(dataTaskWithRequest:),(IMP)ProbeDataTask,&gOrigDataTask);
    any |= Hook(NSURLSession.class,@selector(dataTaskWithRequest:completionHandler:),(IMP)ProbeDataTaskCompletion,&gOrigDataTaskCompletion);
    any |= Hook(NSURLSession.class,@selector(uploadTaskWithRequest:fromData:),(IMP)ProbeUploadData,&gOrigUploadData);
    any |= Hook(NSURLSession.class,@selector(uploadTaskWithRequest:fromFile:),(IMP)ProbeUploadFile,&gOrigUploadFile);
    any |= Hook(NSURLSessionTask.class,@selector(resume),(IMP)ProbeResume,&gOrigResume);
    any |= Hook(NSURLSession.class,NSSelectorFromString(@"_dataTaskWithRequest:delegate:"),(IMP)PrivateDataTaskDelegate,&gOrigPrivateDataTaskDelegate);
    any |= Hook(NSURLSession.class,NSSelectorFromString(@"_dataTaskWithRequest:delegate:completionHandler:"),(IMP)PrivateDataTaskDelegateCompletion,&gOrigPrivateDataTaskDelegateCompletion);
    any |= Hook(NSURLSession.class,NSSelectorFromString(@"dataTaskWithRequest:uniqueIdentifier:"),(IMP)DataTaskUniqueIdentifier,&gOrigDataTaskUniqueIdentifier);
    gHooked=any;
    Log(@"HOOKS network=%d",gHooked);
}

static void Arm(NSString *label) {
    gLabel=[label copy];
    gArmedUntil=NSDate.date.timeIntervalSince1970+kWindow;
    Log(@"========== CAPTURE %@ BEGIN %.0fs ==========",gLabel,kWindow);
    LogAccountState();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(kWindow*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if ([gLabel isEqualToString:label] && !Armed()) {
            Log(@"========== CAPTURE %@ END ==========",label);
        }
    });
}

@interface XTranslateAuthProbeVC : UITableViewController @end
@implementation XTranslateAuthProbeVC
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"Grok Private Factory Fix"; }
- (NSInteger)numberOfSectionsInTableView:(UITableView*)t { return 2; }
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s { return s==0?1:2; }
- (NSString*)tableView:(UITableView*)t titleForHeaderInSection:(NSInteger)s { return s==0?@"Grok":@"Relatório"; }
- (NSString*)tableView:(UITableView*)t titleForFooterInSection:(NSInteger)s {
    if (s==0) return @"Arme na conta Web Login e toque em Traduzir post. O fix atua no factory privado antes de __NSURLSessionLocal criar a task.";
    return @"Reescreve somente /2/grok/ de contas Web Login no factory privado; o log não mostra valores de credenciais.";
}
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)i {
    static NSString *rid=@"XTAPCell";
    UITableViewCell *c=[t dequeueReusableCellWithIdentifier:rid];
    if (!c) c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
    c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    if (i.section==0) { c.textLabel.text=@"Capturar WEB_GROK"; c.detailTextLabel.text=@"15 s — abra Grok ou toque em Traduzir post"; }
    else if (i.row==0) { c.textLabel.text=@"Copiar relatório"; c.detailTextLabel.text=kLogName; }
    else { c.textLabel.text=@"Limpar relatório"; c.detailTextLabel.text=@"Apaga as capturas anteriores"; }
    return c;
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)i {
    [t deselectRowAtIndexPath:i animated:YES];
    if (i.section==0) {
        NSString *label=@"WEB_GROK";
        Arm(label);
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Grok Private Factory Fix"
            message:@"WEB_GROK armado por 15 segundos. Feche e abra o Grok ou toque em “Traduzir post” em um post novo."
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    if (i.row==0) {
        NSString *r=[NSString stringWithContentsOfFile:LogPath() encoding:NSUTF8StringEncoding error:nil] ?: @"";
        UIPasteboard.generalPasteboard.string=r;
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Grok Private Factory Fix"
            message:[NSString stringWithFormat:@"Comparação copiada (%lu caracteres).",(unsigned long)r.length]
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:LogPath() error:nil];
        gReqSeq=0; gLabel=nil; gArmedUntil=0;
        Log(@"LOG RESET");
    }
}
@end

static BOOL SectionsHave(NSArray *sections) {
    for (id e in sections) if ([e isKindOfClass:NSDictionary.class] && [e[@"action"] isEqualToString:@"showXTranslateAuthProbe"]) return YES;
    return NO;
}
static void InjectNFB(id controller) {
    NSArray *sections=nil;
    @try { sections=[controller valueForKey:@"sections"]; } @catch (__unused NSException *e) { return; }
    if (![sections isKindOfClass:NSArray.class] || SectionsHave(sections)) return;
    NSMutableArray *u=[sections mutableCopy];
    [u addObject:@{@"title":@"Grok Private Factory Fix",@"subtitle":@"Corrigir o OAuth placeholder do Grok antes da criação da task.",@"icon":@"flask",@"action":@"showXTranslateAuthProbe"}];
    @try { [controller setValue:[u copy] forKey:@"sections"]; } @catch (__unused NSException *e) {}
}
static void NFBSetup(id self, SEL _cmd) {
    if (gOrigNFBSetup) ((void(*)(id,SEL))gOrigNFBSetup)(self,_cmd);
    InjectNFB(self);
}
static void NFBAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigNFBAppear) ((void(*)(id,SEL,BOOL))gOrigNFBAppear)(self,_cmd,animated);
    InjectNFB(self);
    UITableView *tv=nil; @try { tv=[self valueForKey:@"tableView"]; } @catch (__unused NSException *e) {}
    [tv reloadData];
}
static void ShowProbe(id self, SEL _cmd) {
    if (![self isKindOfClass:UIViewController.class]) return;
    XTranslateAuthProbeVC *vc=[XTranslateAuthProbeVC new];
    UINavigationController *nav=((UIViewController*)self).navigationController;
    if (nav) [nav pushViewController:vc animated:YES];
    else [(UIViewController*)self presentViewController:[[UINavigationController alloc] initWithRootViewController:vc] animated:YES completion:nil];
}
static void InstallNFB(void) {
    if (gNFBHooked) return;
    Class c=NSClassFromString(@"ModernSettingsViewController"); if (!c) return;
    class_addMethod(c,NSSelectorFromString(@"showXTranslateAuthProbe"),(IMP)ShowProbe,"v@:");
    BOOL a=Hook(c,NSSelectorFromString(@"setupSections"),(IMP)NFBSetup,&gOrigNFBSetup);
    BOOL b=Hook(c,@selector(viewWillAppear:),(IMP)NFBAppear,&gOrigNFBAppear);
    gNFBHooked=a||b;
    Log(@"HOOKS nfb=%d",gNFBHooked);
}
static void InstallAll(void) { InstallNetworkHooks(); InstallNFB(); }
static void Retry(NSTimeInterval d) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(d*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ InstallAll(); });
}
__attribute__((constructor))
static void Init(void) {
    @autoreleasepool {
        NSBundle *b=NSBundle.mainBundle;
        Log(@"========== Grok Private Factory Fix 1.0.0 Stable loaded ==========");
        Log(@"ENV appVersion=%@ build=%@ os=%@ mode=grok-private-factory-weblogin-fix no-secrets",
            [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"-",
            [b objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"-",
            UIDevice.currentDevice.systemVersion);
        InstallAll();
        DumpFocusedTaskFactories();
        for (NSNumber *n in @[@0.05,@0.2,@0.5,@1.0,@2.0,@4.0]) Retry(n.doubleValue);
    }
}

// Build trigger 0.11 Stable R2
