#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdint.h>

static NSString *const kVersion = @"2.5";
static NSString *const kLogName = @"XLiquidGlass1238Probe.log";
static NSString *const kForceKey = @"XLiquidGlass1238ForceEnabled";
static IMP gOrigSetup = NULL, gOrigAppear = NULL, gOrigGate = NULL;
static BOOL gGateHooked = NO;

typedef void (*SetRedesignGateFn)(uint8_t);
typedef uint8_t (*BoolGetterFn)(void);
static SetRedesignGateFn gSetGate = NULL;
static BoolGetterFn gGetEnabled = NULL, gGetChrome = NULL, gGetForced = NULL;

static NSString *LogPath(void){NSString*d=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject?:NSTemporaryDirectory();return[d stringByAppendingPathComponent:kLogName];}
static void Log(NSString*fmt,...){va_list a;va_start(a,fmt);NSString*b=[[NSString alloc]initWithFormat:fmt arguments:a];va_end(a);NSString*l=[NSString stringWithFormat:@"[%@] %@\n",NSDate.date,b?:@""];@synchronized(NSFileManager.defaultManager){NSString*p=LogPath();if(![NSFileManager.defaultManager fileExistsAtPath:p])[@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];NSFileHandle*h=[NSFileHandle fileHandleForWritingAtPath:p];if(h){[h seekToEndOfFile];[h writeData:[l dataUsingEncoding:NSUTF8StringEncoding]];[h closeFile];}}NSLog(@"[XLiquidGlass1238ProbeV25] %@",b?:@"");}
static BOOL ForceEnabled(void){id v=[NSUserDefaults.standardUserDefaults objectForKey:kForceKey];return v?[v boolValue]:NO;}

static void ResolveSymbols(void){
    if(!gSetGate)gSetGate=(SetRedesignGateFn)dlsym(RTLD_DEFAULT,"_$s11XAppearance10AppearanceC26setLiquidGlassRedesignGateyySbFZ");
    if(!gGetEnabled)gGetEnabled=(BoolGetterFn)dlsym(RTLD_DEFAULT,"_$s11XAppearance10AppearanceC20isLiquidGlassEnabledSbvgZ");
    if(!gGetChrome)gGetChrome=(BoolGetterFn)dlsym(RTLD_DEFAULT,"_$s11XAppearance10AppearanceC25isLiquidGlassChromeActiveSbvgZ");
    if(!gGetForced)gGetForced=(BoolGetterFn)dlsym(RTLD_DEFAULT,"_$s11XAppearance10AppearanceC27isLiquidGlassForcedBySystemSbvgZ");
}
static void LogState(NSString*where){ResolveSymbols();int e=gGetEnabled?(int)gGetEnabled():-1;int c=gGetChrome?(int)gGetChrome():-1;int f=gGetForced?(int)gGetForced():-1;Log(@"STATE where=%@ enabled=%d chrome=%d forcedBySystem=%d setter=%d",where?:@"-",e,c,f,gSetGate?1:0);}
static void ApplyGate(NSString*reason){ResolveSymbols();LogState([NSString stringWithFormat:@"before-%@",reason?:@"apply"]);if(ForceEnabled()&&gSetGate){gSetGate(1);Log(@"REDESIGN_GATE_SET value=1 reason=%@",reason?:@"-");}else Log(@"REDESIGN_GATE_SET skipped force=%d setter=%d reason=%@",ForceEnabled(),gSetGate?1:0,reason?:@"-");LogState([NSString stringWithFormat:@"after-%@",reason?:@"apply"]);}

static void GateHook(id self,SEL _cmd,id account){Log(@"GATE_BEGIN accountClass=%@ force=%d",account?NSStringFromClass([account class]):@"nil",ForceEnabled());if(gOrigGate)((void(*)(id,SEL,id))gOrigGate)(self,_cmd,account);ApplyGate(@"installGateForAccount");Log(@"GATE_END");}
static void InstallGateHook(void){if(gGateHooked)return;Class c=NSClassFromString(@"T1LiquidGlassGateInstaller");if(!c)return;SEL s=NSSelectorFromString(@"installGateForAccount:");Method m=class_getClassMethod(c,s);if(!m)return;Class meta=object_getClass(c);IMP cur=class_getMethodImplementation(meta,s);if(cur==(IMP)GateHook){gGateHooked=YES;return;}gOrigGate=cur;class_replaceMethod(meta,s,(IMP)GateHook,method_getTypeEncoding(m));gGateHooked=class_getMethodImplementation(meta,s)==(IMP)GateHook;Log(@"GATE_HOOK result=%d",gGateHooked);}

@interface XLGV25VC:UITableViewController@end
@implementation XLGV25VC
- (instancetype)init{return[super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad{[super viewDidLoad];self.title=@"Liquid Glass 12.38 Probe";}
- (NSInteger)numberOfSectionsInTableView:(UITableView*)t{return 3;}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s{return s==0?1:(s==1?1:3);}
- (NSString*)tableView:(UITableView*)t titleForFooterInSection:(NSInteger)s{return s==1?@"Teste enxuto: chama diretamente setLiquidGlassRedesignGate(true). Sem varredura geral de Feature Switches.":nil;}
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)p{UITableViewCell*c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];if(p.section==0){c.textLabel.text=@"Versão 2.5";c.detailTextLabel.text=@"Alvo: X 12.38 • Teste direto do redesign gate";c.selectionStyle=UITableViewCellSelectionStyleNone;}else if(p.section==1){c.textLabel.text=@"Forçar Liquid Glass 12.38";c.detailTextLabel.text=@"Ativa o setter interno do XAppearance.";UISwitch*sw=[UISwitch new];sw.on=ForceEnabled();[sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=sw;c.selectionStyle=UITableViewCellSelectionStyleNone;}else{NSArray*a=@[@"Aplicar gate agora",@"Compartilhar log",@"Limpar log"];c.textLabel.text=a[p.row];c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}return c;}
- (void)toggle:(UISwitch*)s{[NSUserDefaults.standardUserDefaults setBool:s.on forKey:kForceKey];[NSUserDefaults.standardUserDefaults synchronize];Log(@"NFB_FORCE_CHANGED value=%d version=%@",s.on,kVersion);if(s.on)ApplyGate(@"toggle-on");}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)p{[t deselectRowAtIndexPath:p animated:YES];if(p.section!=2)return;if(p.row==0)ApplyGate(@"nfb-manual");else if(p.row==1){NSURL*u=[NSURL fileURLWithPath:LogPath()];UIActivityViewController*a=[[UIActivityViewController alloc]initWithActivityItems:@[u] applicationActivities:nil];[self presentViewController:a animated:YES completion:nil];}else{[@"" writeToFile:LogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];Log(@"NEW_SESSION version=%@ source=NFB_AFTER_CLEAR",kVersion);}}
@end

static BOOL HasEntry(NSArray*s){for(id e in s)if([e isKindOfClass:NSDictionary.class]&&[e[@"action"] isEqual:@"showXLiquidGlass1238V25"])return YES;return NO;}
static void InjectMenu(id c){NSArray*s=nil;@try{s=[c valueForKey:@"sections"];}@catch(...){return;}if(![s isKindOfClass:NSArray.class]||HasEntry(s))return;NSMutableArray*m=[s mutableCopy];[m insertObject:@{@"title":@"Liquid Glass 12.38 Probe",@"subtitle":@"Versão 2.5 • Redesign gate direto",@"icon":@"flask",@"action":@"showXLiquidGlass1238V25"} atIndex:MIN((NSUInteger)2,m.count)];@try{[c setValue:[m copy] forKey:@"sections"];}@catch(...){} }
static void SetupHook(id self,SEL _cmd){if(gOrigSetup)((void(*)(id,SEL))gOrigSetup)(self,_cmd);InjectMenu(self);}
static void AppearHook(id self,SEL _cmd,BOOL a){if(gOrigAppear)((void(*)(id,SEL,BOOL))gOrigAppear)(self,_cmd,a);InjectMenu(self);UITableView*t=nil;@try{t=[self valueForKey:@"tableView"];}@catch(...){}[t reloadData];}
static void Show(id self,SEL _cmd){XLGV25VC*v=[XLGV25VC new];UINavigationController*n=[self navigationController];if(n)[n pushViewController:v animated:YES];else{UINavigationController*w=[[UINavigationController alloc]initWithRootViewController:v];[self presentViewController:w animated:YES completion:nil];}}
static void InstallNFB(void){Class c=NSClassFromString(@"ModernSettingsViewController");if(!c)return;class_addMethod(c,NSSelectorFromString(@"showXLiquidGlass1238V25"),(IMP)Show,"v@:");Method m=class_getInstanceMethod(c,NSSelectorFromString(@"setupSections"));if(m&&class_getMethodImplementation(c,method_getName(m))!=(IMP)SetupHook){gOrigSetup=class_getMethodImplementation(c,method_getName(m));class_replaceMethod(c,method_getName(m),(IMP)SetupHook,method_getTypeEncoding(m));}Method a=class_getInstanceMethod(c,@selector(viewWillAppear:));if(a&&class_getMethodImplementation(c,@selector(viewWillAppear:))!=(IMP)AppearHook){gOrigAppear=class_getMethodImplementation(c,@selector(viewWillAppear:));class_replaceMethod(c,@selector(viewWillAppear:),(IMP)AppearHook,method_getTypeEncoding(a));}Log(@"NFB_MENU installed=1 version=%@",kVersion);}

@interface XLGV25Bootstrap:NSObject@end
@implementation XLGV25Bootstrap
+ (void)load{@autoreleasepool{Log(@"NEW_SESSION version=%@ target=X_12.38 mode=DIRECT_REDESIGN_GATE force=%d bootstrap=+load",kVersion,ForceEnabled());ResolveSymbols();Log(@"SYMBOLS setter=%d enabledGetter=%d chromeGetter=%d forcedGetter=%d",gSetGate?1:0,gGetEnabled?1:0,gGetChrome?1:0,gGetForced?1:0);NSArray*d=@[@0.0,@0.15,@0.4,@0.8,@1.5,@3.0];for(NSNumber*x in d)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(x.doubleValue*NSEC_PER_SEC)),dispatch_get_main_queue(),^{InstallNFB();InstallGateHook();if(ForceEnabled())ApplyGate(@"scheduled");});}}
@end
