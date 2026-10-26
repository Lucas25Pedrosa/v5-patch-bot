#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *const kVersion = @"2.7";
static NSString *const kLogName = @"XLiquidGlass1238Probe.log";
static IMP gOrigSetup = NULL, gOrigAppear = NULL, gOrigGate = NULL, gOrigEnabled = NULL;
static BOOL gGateHooked = NO, gEnabledHooked = NO, gDumpedMethods = NO;

static NSString *LogPath(void){NSString*d=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject?:NSTemporaryDirectory();return[d stringByAppendingPathComponent:kLogName];}
static void Log(NSString*fmt,...){va_list a;va_start(a,fmt);NSString*b=[[NSString alloc]initWithFormat:fmt arguments:a];va_end(a);NSString*l=[NSString stringWithFormat:@"[%@] %@\n",NSDate.date,b?:@""];@synchronized(NSFileManager.defaultManager){NSString*p=LogPath();if(![NSFileManager.defaultManager fileExistsAtPath:p])[@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];NSFileHandle*h=[NSFileHandle fileHandleForWritingAtPath:p];if(h){[h seekToEndOfFile];[h writeData:[l dataUsingEncoding:NSUTF8StringEncoding]];[h closeFile];}}NSLog(@"[XLiquidGlass1238ProbeV27] %@",b?:@"");}
static Class AppearanceClass(void){return NSClassFromString(@"XAppearance.Appearance");}

static NSString *AddrInfo(const void *p){if(!p)return @"nil";Dl_info d={0};if(dladdr(p,&d)&&d.dli_fbase){uintptr_t off=(uintptr_t)p-(uintptr_t)d.dli_fbase;NSString*img=d.dli_fname?[[NSString stringWithUTF8String:d.dli_fname] lastPathComponent]:@"?";return[NSString stringWithFormat:@"%@+0x%llx",img,(unsigned long long)off];}return[NSString stringWithFormat:@"%p",p];}
static BOOL RelevantName(const char *n){if(!n)return NO;NSString*s=[[NSString stringWithUTF8String:n] lowercaseString];return[s containsString:@"liquidglass"]||[s containsString:@"redesign"]||[s containsString:@"gate"]||[s containsString:@"glass"];} 

static void DumpMethodsForClass(Class c, BOOL classMethods){if(!c)return;Class target=classMethods?object_getClass(c):c;unsigned count=0;Method *ms=class_copyMethodList(target,&count);Log(@"METHOD_LIST_BEGIN class=%@ kind=%@ count=%u",NSStringFromClass(c),classMethods?@"class":@"instance",count);for(unsigned i=0;i<count;i++){SEL s=method_getName(ms[i]);const char*n=sel_getName(s);if(!RelevantName(n))continue;IMP imp=method_getImplementation(ms[i]);Log(@"METHOD kind=%@ selector=%s types=%s imp=%p addr=%@",classMethods?@"class":@"instance",n?:"?",method_getTypeEncoding(ms[i])?:"?",imp,AddrInfo((const void*)imp));}free(ms);Log(@"METHOD_LIST_END class=%@ kind=%@",NSStringFromClass(c),classMethods?@"class":@"instance");}
static void DumpAppearanceMethods(void){Class c=AppearanceClass();Log(@"RUNTIME_CLASS present=%d name=%@",c?1:0,c?NSStringFromClass(c):@"nil");if(!c)return;DumpMethodsForClass(c,YES);DumpMethodsForClass(c,NO);gDumpedMethods=YES;}

static void LogState(NSString *where){Class c=AppearanceClass();if(!c){Log(@"STATE where=%@ class=0",where);return;}NSArray*names=@[@"isLiquidGlassEnabled",@"isLiquidGlassChromeActive",@"isLiquidGlassForcedBySystem"];NSMutableArray*out=[NSMutableArray array];for(NSString*n in names){SEL s=NSSelectorFromString(n);Method m=class_getClassMethod(c,s);if(!m){[out addObject:[NSString stringWithFormat:@"%@=missing",n]];continue;}IMP imp=method_getImplementation(m);BOOL v=((BOOL(*)(id,SEL))imp)(c,s);[out addObject:[NSString stringWithFormat:@"%@=%d@%@",n,v?1:0,AddrInfo((const void*)imp)]];}Log(@"STATE where=%@ %@",where,[out componentsJoinedByString:@" "]);}

static BOOL EnabledHook(id self,SEL _cmd){void *caller=__builtin_return_address(0);BOOL native=gOrigEnabled?((BOOL(*)(id,SEL))gOrigEnabled)(self,_cmd):NO;Log(@"ENABLED_CALL native=%d caller=%@ callerPtr=%p",native?1:0,AddrInfo(caller),caller);return native;}
static void InstallEnabledHook(void){if(gEnabledHooked)return;Class c=AppearanceClass();if(!c)return;SEL s=NSSelectorFromString(@"isLiquidGlassEnabled");Method m=class_getClassMethod(c,s);if(!m)return;Class meta=object_getClass(c);IMP cur=class_getMethodImplementation(meta,s);if(cur==(IMP)EnabledHook){gEnabledHooked=YES;return;}gOrigEnabled=cur;Log(@"ENABLED_ORIGINAL imp=%p addr=%@ types=%s",cur,AddrInfo((const void*)cur),method_getTypeEncoding(m)?:"?");class_replaceMethod(meta,s,(IMP)EnabledHook,method_getTypeEncoding(m));gEnabledHooked=class_getMethodImplementation(meta,s)==(IMP)EnabledHook;Log(@"ENABLED_HOOK result=%d",gEnabledHooked);}

static void GateHook(id self,SEL _cmd,id account){void*caller=__builtin_return_address(0);Log(@"GATE_BEGIN accountClass=%@ caller=%@",account?NSStringFromClass([account class]):@"nil",AddrInfo(caller));LogState(@"before-installGateForAccount");if(gOrigGate)((void(*)(id,SEL,id))gOrigGate)(self,_cmd,account);LogState(@"after-installGateForAccount");Log(@"GATE_END");}
static void InstallGateHook(void){if(gGateHooked)return;Class c=NSClassFromString(@"T1LiquidGlassGateInstaller");if(!c)return;SEL s=NSSelectorFromString(@"installGateForAccount:");Method m=class_getClassMethod(c,s);if(!m)return;Class meta=object_getClass(c);IMP cur=class_getMethodImplementation(meta,s);if(cur==(IMP)GateHook){gGateHooked=YES;return;}gOrigGate=cur;Log(@"GATE_ORIGINAL imp=%p addr=%@ types=%s",cur,AddrInfo((const void*)cur),method_getTypeEncoding(m)?:"?");class_replaceMethod(meta,s,(IMP)GateHook,method_getTypeEncoding(m));gGateHooked=class_getMethodImplementation(meta,s)==(IMP)GateHook;Log(@"GATE_HOOK result=%d",gGateHooked);}

@interface XLGV27VC:UITableViewController@end
@implementation XLGV27VC
- (instancetype)init{return[super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad{[super viewDidLoad];self.title=@"Liquid Glass 12.38 Probe";}
- (NSInteger)numberOfSectionsInTableView:(UITableView*)t{return 2;}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s{return s==0?1:4;}
- (NSString*)tableView:(UITableView*)t titleForFooterInSection:(NSInteger)s{return s==0?@"Autópsia enxuta do XAppearance: sem forçar flags. Registra métodos, IMPs e o chamador real de isLiquidGlassEnabled.":nil;}
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)p{UITableViewCell*c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];if(p.section==0){c.textLabel.text=@"Versão 2.7";c.detailTextLabel.text=@"Alvo: X 12.38 • Autópsia XAppearance";c.selectionStyle=UITableViewCellSelectionStyleNone;}else{NSArray*a=@[@"Capturar autópsia agora",@"Registrar estado atual",@"Compartilhar log",@"Limpar log"];c.textLabel.text=a[p.row];c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}return c;}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)p{[t deselectRowAtIndexPath:p animated:YES];if(p.section!=1)return;if(p.row==0){DumpAppearanceMethods();LogState(@"nfb-autopsy");}else if(p.row==1)LogState(@"nfb-state");else if(p.row==2){NSURL*u=[NSURL fileURLWithPath:LogPath()];UIActivityViewController*a=[[UIActivityViewController alloc]initWithActivityItems:@[u] applicationActivities:nil];[self presentViewController:a animated:YES completion:nil];}else{[@"" writeToFile:LogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];Log(@"NEW_SESSION version=%@ source=NFB_AFTER_CLEAR",kVersion);}}
@end

static BOOL HasEntry(NSArray*s){for(id e in s)if([e isKindOfClass:NSDictionary.class]&&[e[@"action"] isEqual:@"showXLiquidGlass1238V27"])return YES;return NO;}
static void InjectMenu(id c){NSArray*s=nil;@try{s=[c valueForKey:@"sections"];}@catch(...){return;}if(![s isKindOfClass:NSArray.class]||HasEntry(s))return;NSMutableArray*m=[s mutableCopy];[m insertObject:@{@"title":@"Liquid Glass 12.38 Probe",@"subtitle":@"Versão 2.7 • Autópsia XAppearance",@"icon":@"flask",@"action":@"showXLiquidGlass1238V27"} atIndex:MIN((NSUInteger)2,m.count)];@try{[c setValue:[m copy] forKey:@"sections"];}@catch(...){} }
static void SetupHook(id self,SEL _cmd){if(gOrigSetup)((void(*)(id,SEL))gOrigSetup)(self,_cmd);InjectMenu(self);}
static void AppearHook(id self,SEL _cmd,BOOL a){if(gOrigAppear)((void(*)(id,SEL,BOOL))gOrigAppear)(self,_cmd,a);InjectMenu(self);UITableView*t=nil;@try{t=[self valueForKey:@"tableView"];}@catch(...){}[t reloadData];}
static void Show(id self,SEL _cmd){XLGV27VC*v=[XLGV27VC new];UINavigationController*n=[self navigationController];if(n)[n pushViewController:v animated:YES];else{UINavigationController*w=[[UINavigationController alloc]initWithRootViewController:v];[self presentViewController:w animated:YES completion:nil];}}
static void InstallNFB(void){Class c=NSClassFromString(@"ModernSettingsViewController");if(!c)return;class_addMethod(c,NSSelectorFromString(@"showXLiquidGlass1238V27"),(IMP)Show,"v@:");Method m=class_getInstanceMethod(c,NSSelectorFromString(@"setupSections"));if(m&&class_getMethodImplementation(c,method_getName(m))!=(IMP)SetupHook){gOrigSetup=class_getMethodImplementation(c,method_getName(m));class_replaceMethod(c,method_getName(m),(IMP)SetupHook,method_getTypeEncoding(m));}Method a=class_getInstanceMethod(c,@selector(viewWillAppear:));if(a&&class_getMethodImplementation(c,@selector(viewWillAppear:))!=(IMP)AppearHook){gOrigAppear=class_getMethodImplementation(c,@selector(viewWillAppear:));class_replaceMethod(c,@selector(viewWillAppear:),(IMP)AppearHook,method_getTypeEncoding(a));}Log(@"NFB_MENU installed=1 version=%@",kVersion);}

static void InstallAll(void){InstallNFB();InstallEnabledHook();InstallGateHook();if(!gDumpedMethods&&AppearanceClass())DumpAppearanceMethods();}
@interface XLGV27Bootstrap:NSObject@end
@implementation XLGV27Bootstrap
+ (void)load{@autoreleasepool{Log(@"NEW_SESSION version=%@ target=X_12.38 mode=XAPPEARANCE_AUTOPSY bootstrap=+load",kVersion);NSArray*d=@[@0.0,@0.15,@0.4,@0.8,@1.5,@3.0];for(NSNumber*x in d)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(x.doubleValue*NSEC_PER_SEC)),dispatch_get_main_queue(),^{InstallAll();});}}
@end
