#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static NSString *const kVersion = @"2.3";
static NSString *const kLogName = @"XLiquidGlass1238Probe.log";
static NSString *const kForceKey = @"XLiquidGlass1238ForceEnabled";
static IMP gOrigSetup = NULL, gOrigAppear = NULL;
static IMP gOrigGate = NULL;
static NSUInteger gPostCalls = 0;

typedef struct { Class target; SEL sel; IMP orig; unsigned argc; BOOL classMethod; } HookRec;
static HookRec gFeatureHooks[512]; static NSUInteger gFeatureHookCount = 0;
static HookRec gPostHooks[128]; static NSUInteger gPostHookCount = 0;

static NSString *LogPath(void) {
    NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    return [d stringByAppendingPathComponent:kLogName];
}

static void Log(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *b = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSString *l = [NSString stringWithFormat:@"[%@] %@\n", NSDate.date, b ?: @""];
    @synchronized(NSFileManager.defaultManager) {
        NSString *p = LogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:p]) [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
        if (h) { [h seekToEndOfFile]; [h writeData:[l dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile]; }
    }
    NSLog(@"[XLiquidGlass1238ProbeV23] %@", b ?: @"");
}

static NSString *CallerText(void) {
    void *ra = __builtin_extract_return_addr(__builtin_return_address(0));
    Dl_info di = {0}; dladdr(ra, &di);
    const char *name = di.dli_fname ? strrchr(di.dli_fname, '/') : NULL;
    name = name ? name + 1 : (di.dli_fname ?: "?");
    unsigned long long off = di.dli_fbase ? (unsigned long long)((uintptr_t)ra - (uintptr_t)di.dli_fbase) : 0;
    return [NSString stringWithFormat:@"%s+0x%llx", name ?: "?", off];
}

static BOOL ForceEnabled(void) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:kForceKey];
    return v ? [v boolValue] : NO;
}
static NSString *KeyText(id k) { if ([k isKindOfClass:NSString.class]) return k; return k ? ([k description] ?: @"") : @""; }
static BOOL IsLiquidKey(NSString *k) { return [k hasPrefix:@"ios_liquid_glass_"]; }
static BOOL IsAppClass(Class c) {
    const char *i = class_getImageName(c); if (!i) return NO;
    NSString *p = [NSString stringWithUTF8String:i] ?: @"";
    return [p containsString:@"/Twitter.app/"] || [p hasSuffix:@"/Twitter"];
}

#pragma mark - Feature switch override

static HookRec *FindFeatureHook(id self, SEL sel) {
    Class c = object_getClass(self);
    for (NSUInteger i=0;i<gFeatureHookCount;i++) if (gFeatureHooks[i].target==c && gFeatureHooks[i].sel==sel) return &gFeatureHooks[i];
    for (Class s=class_getSuperclass(c);s;s=class_getSuperclass(s)) for (NSUInteger i=0;i<gFeatureHookCount;i++) if (gFeatureHooks[i].target==s && gFeatureHooks[i].sel==sel) return &gFeatureHooks[i];
    return NULL;
}
static BOOL FeatureBool1(id self, SEL _cmd, id key) {
    HookRec *h = FindFeatureHook(self,_cmd);
    BOOL native = h && h->orig ? ((BOOL(*)(id,SEL,id))h->orig)(self,_cmd,key) : NO;
    NSString *k = KeyText(key); BOOL force = ForceEnabled() && IsLiquidKey(k); BOOL ret = force ? YES : native;
    if (IsLiquidKey(k)) Log(@"FEATURE_SWITCH selector=%@ class=%@ key=%@ native=%d returned=%d forced=%d caller=%@", NSStringFromSelector(_cmd), NSStringFromClass([self class]), k, native, ret, force, CallerText());
    return ret;
}
static BOOL FeatureBool2(id self, SEL _cmd, id key, BOOL def) {
    HookRec *h = FindFeatureHook(self,_cmd);
    BOOL native = h && h->orig ? ((BOOL(*)(id,SEL,id,BOOL))h->orig)(self,_cmd,key,def) : def;
    NSString *k = KeyText(key); BOOL force = ForceEnabled() && IsLiquidKey(k); BOOL ret = force ? YES : native;
    if (IsLiquidKey(k)) Log(@"FEATURE_SWITCH selector=%@ class=%@ key=%@ default=%d native=%d returned=%d forced=%d caller=%@", NSStringFromSelector(_cmd), NSStringFromClass([self class]), k, def, native, ret, force, CallerText());
    return ret;
}
static BOOL FeatureAlready(Class t, SEL s) { for (NSUInteger i=0;i<gFeatureHookCount;i++) if (gFeatureHooks[i].target==t && gFeatureHooks[i].sel==s) return YES; return NO; }
static void ScanFeatureHooks(void) {
    NSArray *names = @[@"boolForKey:",@"boolForKey:defaultValue:",@"tfs_boolForKey:",@"tfs_boolForKey:defaultValue:"];
    int n=objc_getClassList(NULL,0); if(n<=0) return; Class *cs=(__unsafe_unretained Class*)calloc(n,sizeof(Class)); n=objc_getClassList(cs,n);
    NSUInteger added=0,cand=0;
    for(int i=0;i<n && gFeatureHookCount<512;i++) { Class c=cs[i]; if(!IsAppClass(c)) continue;
        for(int pass=0;pass<2;pass++) { Class t=pass?object_getClass(c):c; unsigned mc=0; Method *ms=class_copyMethodList(t,&mc);
            for(unsigned j=0;j<mc;j++) { SEL s=method_getName(ms[j]); NSString *sn=NSStringFromSelector(s); if(![names containsObject:sn]) continue; cand++; if(FeatureAlready(t,s)) continue;
                const char *ty=method_getTypeEncoding(ms[j]); unsigned ac=method_getNumberOfArguments(ms[j]); if(!ty||(ty[0]!='B'&&ty[0]!='c')||(ac!=3&&ac!=4)) continue;
                IMP orig=method_getImplementation(ms[j]); IMP repl=(ac==3)?(IMP)FeatureBool1:(IMP)FeatureBool2; class_replaceMethod(t,s,repl,ty);
                if(class_getMethodImplementation(t,s)==repl){gFeatureHooks[gFeatureHookCount++]=(HookRec){t,s,orig,ac,pass?YES:NO};added++;Log(@"FEATURE_HOOK class=%@ classMethod=%d selector=%@ argc=%u image=%s",NSStringFromClass(c),pass,sn,ac,class_getImageName(c)?:"?");}
            } free(ms);
        }
    } free(cs);
    Log(@"FEATURE_HOOK_PASS version=%@ total=%lu added=%lu candidates=%lu force=%d",kVersion,(unsigned long)gFeatureHookCount,(unsigned long)added,(unsigned long)cand,ForceEnabled());
}

#pragma mark - Post feature-switch diagnostics

static HookRec *FindPostHook(id self, SEL sel) {
    Class c = object_getClass(self);
    for (NSUInteger i=0;i<gPostHookCount;i++) if (gPostHooks[i].target==c && gPostHooks[i].sel==sel) return &gPostHooks[i];
    for (Class s=class_getSuperclass(c);s;s=class_getSuperclass(s)) for (NSUInteger i=0;i<gPostHookCount;i++) if (gPostHooks[i].target==s && gPostHooks[i].sel==sel) return &gPostHooks[i];
    return NULL;
}
static BOOL PostBool0(id self, SEL _cmd) {
    HookRec *h=FindPostHook(self,_cmd);
    BOOL result=h&&h->orig?((BOOL(*)(id,SEL))h->orig)(self,_cmd):NO;
    gPostCalls++;
    if(gPostCalls<=200) Log(@"POST_BOOL call=%lu class=%@ selector=%@ result=%d caller=%@",(unsigned long)gPostCalls,NSStringFromClass([self class]),NSStringFromSelector(_cmd),result,CallerText());
    return result;
}
static BOOL PostAlready(Class t, SEL s){for(NSUInteger i=0;i<gPostHookCount;i++)if(gPostHooks[i].target==t&&gPostHooks[i].sel==s)return YES;return NO;}
static void ScanPostHooks(void) {
    NSArray *names=@[@"isLiquidGlassEnabled",@"isLiquidGlassChromeActive",@"isLiquidGlassForcedBySystem",@"isRedesignEnabled",@"isPushChromeSnapEnabled"];
    int n=objc_getClassList(NULL,0); if(n<=0)return; Class *cs=(__unsafe_unretained Class*)calloc(n,sizeof(Class)); n=objc_getClassList(cs,n); NSUInteger added=0,cand=0;
    for(int i=0;i<n&&gPostHookCount<128;i++){Class c=cs[i];if(!IsAppClass(c))continue;for(int pass=0;pass<2;pass++){Class t=pass?object_getClass(c):c;unsigned mc=0;Method*ms=class_copyMethodList(t,&mc);for(unsigned j=0;j<mc;j++){SEL s=method_getName(ms[j]);NSString*sn=NSStringFromSelector(s);if(![names containsObject:sn])continue;cand++;if(PostAlready(t,s))continue;const char*ty=method_getTypeEncoding(ms[j]);unsigned ac=method_getNumberOfArguments(ms[j]);if(!ty||(ty[0]!='B'&&ty[0]!='c')||ac!=2)continue;IMP orig=method_getImplementation(ms[j]);class_replaceMethod(t,s,(IMP)PostBool0,ty);if(class_getMethodImplementation(t,s)==(IMP)PostBool0){gPostHooks[gPostHookCount++]=(HookRec){t,s,orig,ac,pass?YES:NO};added++;Log(@"POST_HOOK class=%@ classMethod=%d selector=%@ image=%s",NSStringFromClass(c),pass,sn,class_getImageName(c)?:"?");}}free(ms);}}free(cs);Log(@"POST_HOOK_PASS version=%@ total=%lu added=%lu candidates=%lu",kVersion,(unsigned long)gPostHookCount,(unsigned long)added,(unsigned long)cand);
}
static void GateHook(id self, SEL _cmd, id account) {
    Log(@"GATE_BEGIN selector=installGateForAccount: accountClass=%@ force=%d caller=%@",account?NSStringFromClass([account class]):@"nil",ForceEnabled(),CallerText());
    if(gOrigGate)((void(*)(id,SEL,id))gOrigGate)(self,_cmd,account);
    Log(@"GATE_END selector=installGateForAccount:");
}
static void InstallGateHook(void) {
    Class c=NSClassFromString(@"T1LiquidGlassGateInstaller"); if(!c) return; SEL s=NSSelectorFromString(@"installGateForAccount:"); Method m=class_getClassMethod(c,s); if(!m) return; Class meta=object_getClass(c); IMP cur=class_getMethodImplementation(meta,s); if(cur==(IMP)GateHook) return; gOrigGate=cur; class_replaceMethod(meta,s,(IMP)GateHook,method_getTypeEncoding(m)); Log(@"GATE_HOOK class=%@ selector=installGateForAccount: result=%d",NSStringFromClass(c),class_getMethodImplementation(meta,s)==(IMP)GateHook);
}

static void Capture(NSString *r) {
    Log(@"CAPTURE version=%@ reason=%@ force=%d featureHooks=%lu postHooks=%lu postCalls=%lu",kVersion,r?:@"-",ForceEnabled(),(unsigned long)gFeatureHookCount,(unsigned long)gPostHookCount,(unsigned long)gPostCalls);
    ScanFeatureHooks(); ScanPostHooks(); InstallGateHook();
}

#pragma mark - NFB UI

@interface XLGV23VC:UITableViewController@end
@implementation XLGV23VC
- (instancetype)init{return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad{[super viewDidLoad];self.title=@"Liquid Glass 12.38 Probe";}
- (NSInteger)numberOfSectionsInTableView:(UITableView*)t{return 3;}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s{return s==0?1:(s==1?1:3);}
- (NSString*)tableView:(UITableView*)t titleForFooterInSection:(NSInteger)s{return s==1?@"Força somente ios_liquid_glass_*; os gates posteriores são apenas observados. Reinicie o X após alterar.":nil;}
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)p{
    UITableViewCell*c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if(p.section==0){c.textLabel.text=@"Versão 2.3";c.detailTextLabel.text=@"Alvo: X 12.38 • Diagnóstico pós-feature-switch";c.selectionStyle=UITableViewCellSelectionStyleNone;}
    else if(p.section==1){c.textLabel.text=@"Forçar Liquid Glass 12.38";c.detailTextLabel.text=@"Override do feature switch já comprovado.";UISwitch*sw=[UISwitch new];sw.on=ForceEnabled();[sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=sw;c.selectionStyle=UITableViewCellSelectionStyleNone;}
    else {NSArray*a=@[@"Capturar diagnóstico",@"Compartilhar log",@"Limpar log"];c.textLabel.text=a[p.row];c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
    return c;
}
- (void)toggle:(UISwitch*)s{[NSUserDefaults.standardUserDefaults setBool:s.on forKey:kForceKey];[NSUserDefaults.standardUserDefaults synchronize];Log(@"NFB_FORCE_CHANGED value=%d version=%@",s.on,kVersion);UIAlertController*a=[UIAlertController alertControllerWithTitle:@"Liquid Glass 12.38" message:@"Feche o X completamente e abra novamente para testar." preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:a animated:YES completion:nil];}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)p{[t deselectRowAtIndexPath:p animated:YES];if(p.section!=2)return;if(p.row==0)Capture(@"nfb-manual");else if(p.row==1){NSURL*u=[NSURL fileURLWithPath:LogPath()];UIActivityViewController*a=[[UIActivityViewController alloc]initWithActivityItems:@[u] applicationActivities:nil];[self presentViewController:a animated:YES completion:nil];}else{[@"" writeToFile:LogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];Log(@"NEW_SESSION version=%@ source=NFB_AFTER_CLEAR",kVersion);}}
@end

static BOOL HasEntry(NSArray*s){for(id e in s)if([e isKindOfClass:NSDictionary.class]&&[e[@"action"] isEqual:@"showXLiquidGlass1238V23"])return YES;return NO;}
static void InjectMenu(id c){NSArray*s=nil;@try{s=[c valueForKey:@"sections"];}@catch(...){return;}if(![s isKindOfClass:NSArray.class]||HasEntry(s))return;NSMutableArray*m=[s mutableCopy];[m insertObject:@{@"title":@"Liquid Glass 12.38 Probe",@"subtitle":@"Versão 2.3 • Diagnóstico pós-feature-switch",@"icon":@"flask",@"action":@"showXLiquidGlass1238V23"} atIndex:MIN((NSUInteger)2,m.count)];@try{[c setValue:[m copy] forKey:@"sections"];}@catch(...){} }
static void SetupHook(id self,SEL _cmd){if(gOrigSetup)((void(*)(id,SEL))gOrigSetup)(self,_cmd);InjectMenu(self);}
static void AppearHook(id self,SEL _cmd,BOOL a){if(gOrigAppear)((void(*)(id,SEL,BOOL))gOrigAppear)(self,_cmd,a);InjectMenu(self);UITableView*t=nil;@try{t=[self valueForKey:@"tableView"];}@catch(...){}[t reloadData];}
static void Show(id self,SEL _cmd){XLGV23VC*v=[XLGV23VC new];UINavigationController*n=[self navigationController];if(n)[n pushViewController:v animated:YES];else{UINavigationController*w=[[UINavigationController alloc]initWithRootViewController:v];[self presentViewController:w animated:YES completion:nil];}}
static void InstallNFB(void){Class c=NSClassFromString(@"ModernSettingsViewController");if(!c){Log(@"NFB_MENU class_missing");return;}class_addMethod(c,NSSelectorFromString(@"showXLiquidGlass1238V23"),(IMP)Show,"v@:");Method m=class_getInstanceMethod(c,NSSelectorFromString(@"setupSections"));if(m&&class_getMethodImplementation(c,method_getName(m))!=(IMP)SetupHook){gOrigSetup=class_getMethodImplementation(c,method_getName(m));class_replaceMethod(c,method_getName(m),(IMP)SetupHook,method_getTypeEncoding(m));}Method a=class_getInstanceMethod(c,@selector(viewWillAppear:));if(a&&class_getMethodImplementation(c,@selector(viewWillAppear:))!=(IMP)AppearHook){gOrigAppear=class_getMethodImplementation(c,@selector(viewWillAppear:));class_replaceMethod(c,@selector(viewWillAppear:),(IMP)AppearHook,method_getTypeEncoding(a));}Log(@"NFB_MENU installed=1 version=%@",kVersion);}

@interface XLGV23Bootstrap:NSObject@end
@implementation XLGV23Bootstrap
+ (void)load{@autoreleasepool{Log(@"NEW_SESSION version=%@ target=X_12.38 mode=POST_GATE force=%d bootstrap=+load",kVersion,ForceEnabled());NSArray*d=@[@0.0,@0.2,@0.7,@1.5,@3.0,@6.0,@10.0,@15.0];for(NSNumber*x in d)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(x.doubleValue*NSEC_PER_SEC)),dispatch_get_main_queue(),^{InstallNFB();ScanFeatureHooks();ScanPostHooks();InstallGateHook();});}}
@end
