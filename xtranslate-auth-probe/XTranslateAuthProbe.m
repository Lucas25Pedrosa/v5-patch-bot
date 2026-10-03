#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *const kLogName = @"XTranslateAuthProbe.log";
static const NSTimeInterval kWindow = 45.0;
static const NSUInteger kMaxBytes = 3 * 1024 * 1024;

static IMP gOrigDataTask = NULL;
static IMP gOrigDataTaskCompletion = NULL;
static IMP gOrigUploadData = NULL;
static IMP gOrigUploadFile = NULL;
static IMP gOrigResume = NULL;
static IMP gOrigNFBSetup = NULL;
static IMP gOrigNFBAppear = NULL;

static BOOL gHooked = NO;
static BOOL gNFBHooked = NO;
static NSTimeInterval gArmedUntil = 0;
static NSString *gLabel = nil;
static NSUInteger gReqSeq = 0;
static char kTaskMetaKey;

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

static NSString *OAuthUID(NSURLRequest *r) {
    NSString *a = Header(r, @"Authorization");
    if (!a.length) return @"-";
    NSRange m = [a rangeOfString:@"oauth_token=\""];
    if (m.location == NSNotFound) return @"-";
    NSString *rest = [a substringFromIndex:NSMaxRange(m)];
    NSRange q = [rest rangeOfString:@"\""];
    if (q.location == NSNotFound) return @"-";
    NSString *token = [rest substringToIndex:q.location];
    NSRange dash = [token rangeOfString:@"-"];
    NSString *uid = dash.location != NSNotFound ? [token substringToIndex:dash.location] : token;
    return MaskUID(uid);
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

static BOOL IsRelevantHost(NSURLRequest *r) {
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

static void LogRequest(NSString *phase, NSUInteger seq, NSURLRequest *r) {
    if (!r) { Log(@"REQ %@ #%lu nil", phase, (unsigned long)seq); return; }
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
    if (!Armed() || !IsRelevantHost(request))
        return ((id(*)(id,SEL,id))gOrigDataTask)(self,_cmd,request);

    NSUInteger seq=++gReqSeq;
    LogRequest(@"IN",seq,request);
    NSURLSessionDataTask *task=((id(*)(id,SEL,id))gOrigDataTask)(self,_cmd,request);
    LogRequest(@"TASK",seq,task.currentRequest ?: task.originalRequest);
    AttachTask(task,seq);
    return task;
}

static NSURLSessionDataTask *ProbeDataTaskCompletion(NSURLSession *self, SEL _cmd, NSURLRequest *request, id completion) {
    if (!gOrigDataTaskCompletion) return nil;
    if (!Armed() || !IsRelevantHost(request))
        return ((id(*)(id,SEL,id,id))gOrigDataTaskCompletion)(self,_cmd,request,completion);

    NSUInteger seq=++gReqSeq;
    LogRequest(@"IN",seq,request);
    NSURLSessionDataTask *task=((id(*)(id,SEL,id,id))gOrigDataTaskCompletion)(self,_cmd,request,completion);
    LogRequest(@"TASK",seq,task.currentRequest ?: task.originalRequest);
    AttachTask(task,seq);
    return task;
}

static NSURLSessionUploadTask *ProbeUploadData(NSURLSession *self, SEL _cmd, NSURLRequest *request, NSData *data) {
    if (!gOrigUploadData) return nil;
    if (!Armed() || !IsRelevantHost(request))
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
    if (!Armed() || !IsRelevantHost(request))
        return ((id(*)(id,SEL,id,id))gOrigUploadFile)(self,_cmd,request,fileURL);
    NSUInteger seq=++gReqSeq;
    LogRequest(@"IN-UPLOADFILE",seq,request);
    NSURLSessionUploadTask *task=((id(*)(id,SEL,id,id))gOrigUploadFile)(self,_cmd,request,fileURL);
    LogRequest(@"TASK-UPLOADFILE",seq,task.currentRequest ?: task.originalRequest);
    AttachTask(task,seq);
    return task;
}

static void ProbeResume(NSURLSessionTask *self, SEL _cmd) {
    NSDictionary *m=MetaForTask(self);
    if (m) {
        LogRequest(@"RESUME",[m[@"seq"] unsignedIntegerValue],self.currentRequest ?: self.originalRequest);
    }
    if (gOrigResume) ((void(*)(id,SEL))gOrigResume)(self,_cmd);
}

static void InstallNetworkHooks(void) {
    if (gHooked) return;
    BOOL any=NO;
    any |= Hook(NSURLSession.class,@selector(dataTaskWithRequest:),(IMP)ProbeDataTask,&gOrigDataTask);
    any |= Hook(NSURLSession.class,@selector(dataTaskWithRequest:completionHandler:),(IMP)ProbeDataTaskCompletion,&gOrigDataTaskCompletion);
    any |= Hook(NSURLSession.class,@selector(uploadTaskWithRequest:fromData:),(IMP)ProbeUploadData,&gOrigUploadData);
    any |= Hook(NSURLSession.class,@selector(uploadTaskWithRequest:fromFile:),(IMP)ProbeUploadFile,&gOrigUploadFile);
    any |= Hook(NSURLSessionTask.class,@selector(resume),(IMP)ProbeResume,&gOrigResume);
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
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"XTranslate Auth Probe"; }
- (NSInteger)numberOfSectionsInTableView:(UITableView*)t { return 2; }
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s { return s==0?2:2; }
- (NSString*)tableView:(UITableView*)t titleForHeaderInSection:(NSInteger)s { return s==0?@"Comparação":@"Relatório"; }
- (NSString*)tableView:(UITableView*)t titleForFooterInSection:(NSInteger)s {
    if (s==0) return @"Ative primeiro a conta correspondente. Depois toque no botão, volte ao MESMO post e use “Traduzir post” uma vez. A captura dura 45 s e não modifica nenhuma requisição.";
    return @"Não registra tokens nem valores de cookies: apenas tipo de autenticação, presença de cabeçalhos, endpoint e status HTTP.";
}
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)i {
    static NSString *rid=@"XTAPCell";
    UITableViewCell *c=[t dequeueReusableCellWithIdentifier:rid];
    if (!c) c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
    c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    if (i.section==0 && i.row==0) { c.textLabel.text=@"Capturar conta antiga (funciona)"; c.detailTextLabel.text=@"45 s — referência"; }
    else if (i.section==0) { c.textLabel.text=@"Capturar conta nova (falha)"; c.detailTextLabel.text=@"45 s — login web/cookies"; }
    else if (i.row==0) { c.textLabel.text=@"Copiar comparação"; c.detailTextLabel.text=kLogName; }
    else { c.textLabel.text=@"Limpar relatório"; c.detailTextLabel.text=@"Apaga as capturas anteriores"; }
    return c;
}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)i {
    [t deselectRowAtIndexPath:i animated:YES];
    if (i.section==0) {
        Arm(i.row==0?@"OLD_OK":@"NEW_FAIL");
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"XTranslate Auth Probe"
            message:@"Captura armada por 45 segundos. Volte ao mesmo post e toque uma vez em “Traduzir post”."
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    if (i.row==0) {
        NSString *r=[NSString stringWithContentsOfFile:LogPath() encoding:NSUTF8StringEncoding error:nil] ?: @"";
        UIPasteboard.generalPasteboard.string=r;
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"XTranslate Auth Probe"
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
    [u addObject:@{@"title":@"XTranslate Auth Probe",@"subtitle":@"Comparar autenticação da tradução.",@"icon":@"flask",@"action":@"showXTranslateAuthProbe"}];
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
        Log(@"========== XTranslate Auth Probe 0.3.0 loaded ==========");
        Log(@"ENV appVersion=%@ build=%@ os=%@ mode=read-only no-secrets",
            [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"-",
            [b objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"-",
            UIDevice.currentDevice.systemVersion);
        InstallAll();
        for (NSNumber *n in @[@0.05,@0.2,@0.5,@1.0,@2.0,@4.0]) Retry(n.doubleValue);
    }
}
