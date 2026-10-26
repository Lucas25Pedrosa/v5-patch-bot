#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kVersion = @"2.6";
static NSString *const kLogName = @"XLiquidGlass1238Probe.log";
static NSString *const kForceKey = @"XLiquidGlass1238ForceEnabled";
static IMP gOrigSetup = NULL, gOrigAppear = NULL, gOrigGate = NULL;
static BOOL gGateHooked = NO;

static NSString *LogPath(void){NSString*d=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject?:NSTemporaryDirectory();return[d stringByAppendingPathComponent:kLogName];}
static void Log(NSString*fmt,...){va_list a;va_start(a,fmt);NSString*b=[[NSString alloc]initWithFormat:fmt arguments:a];va_end(a);NSString*l=[NSString stringWithFormat:@"[%@] %@\n",NSDate.date,b?:@""];@synchronized(NSFileManager.defaultManager){NSString*p=LogPath();if(![NSFileManager.defaultManager fileExistsAtPath:p])[@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];NSFileHandle*h=[NSFileHandle fileHandleForWritingAtPath:p];if(h){[h seekToEndOfFile];[h writeData:[l dataUsingEncoding:NSUTF8StringEncoding]];[h closeFile];}}NSLog(@"[XLiquidGlass1238ProbeV26] %@",b?:@"");}
static BOOL ForceEnabled(void){id v=[NSUserDefaults.standardUserDefaults objectForKey:kForceKey];return v?[v boolValue]:NO;}

static Class AppearanceClass(void){return NSClassFromString(@"XAppearance.Appearance");}
static Method AppearanceClassMethod(NSString *name){Class c=AppearanceClass();return c?class_getClassMethod(c,NSSelectorFromString(name)):NULL;}
static BOOL CallAppearanceBool(NSString *name, int *out){Class c=AppearanceClass();Method m=AppearanceClassMethod(name);if(!c||!m)return NO;SEL s=method_getName(m);IMP imp=method_getImplementation(m);BOOL v=((BOOL(*)(id,SEL))imp)(c,s);if(out)*out=v?1:0;return YES;}
static BOOL SetRedesignGate(BOOL value){Class c=AppearanceClass();Method m=AppearanceClassMethod(@"setLiquidGlassRedesignGate:");if(!c||!m)return NO;SEL s=method_getName(m);IMP imp=method_getImplementation(m);((void(*)(id,SEL,BOOL))imp)(c,s,value);return YES;}
static void LogRuntimeMethods(void){Class c=AppearanceClass();Method setter=AppearanceClassMethod(@"setLiquidGlassRedesignGate:");Method enabled=AppearanceClassMethod(@"isLiquidGlassEnabled");Method chrome=AppearanceClassMethod(@"isLiquidGlassChromeActive");Method forced=AppearanceClassMethod(@"isLiquidGlassForcedBySystem");Log(@"RUNTIME class=%d setter=%d enabledGetter=%d chromeGetter=%d forcedGetter=%d",c?1:0,setter?1:0,enabled?1:0,chrome?1:0,forced?1:0);if(setter)Log(@"RUNTIME_METHOD selector=setLiquidGlassRedesignGate: types=%s imp=%p",method_getTypeEncoding(setter)?:"?",method_getImplementation(setter));}
static void LogState(NSString *where){int e=-1,c=-1,f=-1;BOOL he=CallAppearanceBool(@"isLiquidGlassEnabled",&e);BOOL hc=CallAppearanceBool(@"isLiquidGlassChromeActive",&c);BOOL hf=CallAppearanceBool(@"isLiquidGlassForcedBySystem",&f);Log(@"STATE where=%@ enabled=%d(%d) chrome=%d(%d) forcedBySystem=%d(%d)",where?:@"-",e,he,c,hc,f,hf);}
static void ApplyGate(NSString *reason){LogRuntimeMethods();LogState([NSString stringWithFormat:@"before-%@",reason?:@"apply"]);if(ForceEnabled()){BOOL ok=SetRedesignGate(YES);Log(@"REDESIGN_GATE_SET value=1 result=%d reason=%@",ok,reason?:@"-");}else Log(@"REDESIGN_GATE_SET skipped force=0 reason=%@",reason?:@"-");LogState([NSString stringWithFormat:@"after-%@",reason?:@"apply"]);}

static void GateHook(id self,SEL _cmd,id account){Log(@"GATE_BEGIN accountClass=%@ force=%d",account?NSStringFromClass([account class]):@"nil",ForceEnabled());if(gOrigGate)((void(*)(id,SEL,id))gOrigGate)(self,_cmd,account);ApplyGate(@"installGateForAccount");Log(@"GATE_END");}
static void InstallGateHook(void){if(gGateHooked)return;Class c=NSClassFromString(@"T1LiquidGlassGateInstaller");if(!c)return;SEL s=NSSelectorFromString(@"installGateForAccount:");Method m=class_getClassMethod(c,s);if(!m)return;Class meta=object_getClass(c);IMP cur=class_getMethodImplementation(meta,s);if(cur==(IMP)GateHook){gGateHooked=YES;return;}gOrigGate=cur;class_replaceMethod(meta,s,(IMP)GateHook,method_getTypeEncoding(m));gGateHooked=class_getMethodImplementation(meta,s)==(IMP)GateHook;Log(@"GATE_HOOK result=%d",gGateHooked);}

@interface XLGV26VC:UITableViewController@end
@implementation XLGV26VC
- (instancetype)init{return[super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad{[super viewDidLoad];self.title=@"Liquid Glass 12.38 Probe";}
- (NSInteger)numberOfSectionsInTableView:(UITableView*)t{return 3;}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s{return s==0?1:(s==1?1:3);}
- (NSString*)tableView:(UITableView*)t titleForFooterInSection:(NSInteger)s{return s==1?@"Teste enxuto via runtime Objective-C: chama setLiquidGlassRedesignGate: diretamente em XAppearance.Appearance.":nil;}
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)p{UITableViewCell*c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];if(p.section==0){c.textLabel.text=@"Versão 2.6";c.detailTextLabel.text=@"Alvo: X 12.38 • Runtime setter direto";c.selectionStyle=UITableViewCellSelectionStyleNone;}else if(p.section==1){c.textLabel.text=@"Forçar Liquid Glass 12.38";c.detailTextLabel.text=@"Ativa setLiquidGlassRedesignGate: no runtime.";UISwitch*sw=[UISwitch new];sw.on=ForceEnabled();[sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=sw;c.selectionStyle=UITableViewCellSelectionStyleNone;}else{NSArray*a=@[@"Aplicar gate agora",@"Compartilhar log",@"Limpar log"];c.textLabel.text=a[p.row];c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}return c;}
- (void)toggle:(UISwitch*)s{[NSUserDefaults.standardUserDefaults setBool:s.on forKey:kForceKey];[NSUserDefaults.standardUserDefaults synchronize];Log(@"NFB_FORCE_CHANGED value=%d version=%@",s.on,kVersion);if(s.on)ApplyGate(@"toggle-on");}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)p{[t deselectRowAtIndexPath:p animated:YES];if(p.section!=2)return;if(p.row==0)ApplyGate(@"nfb-manual");else if(p.row==1){NSURL*u=[NSURL fileURLWithPath:LogPath()];UIActivityViewController*a=[[UIActivityViewController alloc]initWithActivityItems:@[u] applicationActivities:nil];[self presentViewController:a animated:YES completion:nil];}else{[@"" writeToFile:LogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];Log(@"NEW_SESSION version=%@ source=NFB_AFTER_CLEAR",kVersion);}}
@end

static BOOL HasEntry(NSArray*s){for(id e in s)if([e isKindOfClass:NSDictionary.class]&&[e[@"action"] isEqual:@"showXLiquidGlass1238V26"])return YES;return NO;}
static void InjectMenu(id c){NSArray*s=nil;@try{s=[c valueForKey:@"sections"];}@catch(...){return;}if(![s isKindOfClass:NSArray.class]||HasEntry(s))return;NSMutableArray*m=[s mutableCopy];[m insertObject:@{@"title":@"Liquid Glass 12.38 Probe",@"subtitle":@"Versão 2.6 • Runtime setter direto",@"icon":@"flask",@"action":@"showXLiquidGlass1238V26"} atIndex:MIN((NSUInteger)2,m.count)];@try{[c setValue:[m copy] forKey:@"sections"];}@catch(...){} }
static void SetupHook(id self,SEL _cmd){if(gOrigSetup)((void(*)(id,SEL))gOrigSetup)(self,_cmd);InjectMenu(self);}
static void AppearHook(id self,SEL _cmd,BOOL a){if(gOrigAppear)((void(*)(id,SEL,BOOL))gOrigAppear)(self,_cmd,a);InjectMenu(self);UITableView*t=nil;@try{t=[self valueForKey:@"tableView"];}@catch(...){}[t reloadData];}
static void Show(id self,SEL _cmd){XLGV26VC*v=[XLGV26VC new];UINavigationController*n=[self navigationController];if(n)[n pushViewController:v animated:YES];else{UINavigationController*w=[[UINavigationController alloc]initWithRootViewController:v];[self presentViewController:w animated:YES completion:nil];}}
static void InstallNFB(void){Class c=NSClassFromString(@"ModernSettingsViewController");if(!c)return;class_addMethod(c,NSSelectorFromString(@"showXLiquidGlass1238V26"),(IMP)Show,"v@:");Method m=class_getInstanceMethod(c,NSSelectorFromString(@"setupSections"));if(m&&class_getMethodImplementation(c,method_getName(m))!=(IMP)SetupHook){gOrigSetup=class_getMethodImplementation(c,method_getName(m));class_replaceMethod(c,method_getName(m),(IMP)SetupHook,method_getTypeEncoding(m));}Method a=class_getInstanceMethod(c,@selector(viewWillAppear:));if(a&&class_getMethodImplementation(c,@selector(viewWillAppear:))!=(IMP)AppearHook){gOrigAppear=class_getMethodImplementation(c,@selector(viewWillAppear:));class_replaceMethod(c,@selector(viewWillAppear:),(IMP)AppearHook,method_getTypeEncoding(a));}Log(@"NFB_MENU installed=1 version=%@",kVersion);}

@interface XLGV26Bootstrap:NSObject@end
@implementation XLGV26Bootstrap
+ (void)load{@autoreleasepool{Log(@"NEW_SESSION version=%@ target=X_12.38 mode=RUNTIME_REDESIGN_GATE force=%d bootstrap=+load",kVersion,ForceEnabled());NSArray*d=@[@0.0,@0.15,@0.4,@0.8,@1.5,@3.0];for(NSNumber*x in d)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(x.doubleValue*NSEC_PER_SEC)),dispatch_get_main_queue(),^{InstallNFB();InstallGateHook();if(ForceEnabled())ApplyGate(@"scheduled");});}}
@end
