#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdatomic.h>

static NSString *const kVersion=@"0.6";
static NSString *const kReportName=@"XLiquidGlassCommentsTransitionProbe.txt";
static const NSTimeInterval kPrep=8.0;
static const NSTimeInterval kCapture=15.0;
static const double kTransitionWindow=0.25;

static IMP gTreatmentLayout=NULL;
static IMP gTreatmentNeeds=NULL;
static IMP gSettingsSetup=NULL;
static IMP gSettingsWillAppear=NULL;
static BOOL gHooksInstalled=NO,gSettingsInstalled=NO;
static _Atomic(bool) gActive=false;
static BOOL gArmed=NO;
static NSUInteger gSerial=0;
static CFTimeInterval gStart=0;
static NSString *gLastReport=nil;
static CADisplayLink *gDisplayLink=nil;
static UIScrollView *gTrackedTable=nil;
static CGFloat gLastOffset=0;
static int gLastDir=0;
static BOOL gWasMoving=NO;
static NSUInteger gStillFrames=0;
static CFTimeInterval gLastTick=0;
static NSMutableArray<NSMutableDictionary *> *gEvents=nil;
static NSMutableDictionary *gGlobal=nil;
static CFTimeInterval gTransitionUntil=0;
static NSMutableDictionary *gCurrentEvent=nil;

static NSString *ReportPath(void){
    NSString *d=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject ?: NSTemporaryDirectory();
    return [d stringByAppendingPathComponent:kReportName];
}
static NSString *Stamp(void){
    static NSDateFormatter *f; static dispatch_once_t once; dispatch_once(&once,^{ f=[NSDateFormatter new]; f.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; f.dateFormat=@"yyyy-MM-dd HH:mm:ss.SSS";});
    return [f stringFromDate:NSDate.date];
}
static NSString *ImageForIMP(IMP imp){ if(!imp) return @"-"; Dl_info i={0}; if(!dladdr((const void*)imp,&i)||!i.dli_fname) return @"-"; NSString *p=[NSString stringWithUTF8String:i.dli_fname]; return p.lastPathComponent ?: p; }
static NSString *Stack(void){
    NSMutableString *s=[NSMutableString string]; NSUInteger out=0;
    for(NSNumber *n in NSThread.callStackReturnAddresses){ if(out>=16) break; uintptr_t a=(uintptr_t)n.unsignedLongLongValue; Dl_info i={0}; if(!dladdr((const void*)a,&i)||!i.dli_fname) continue; NSString *img=[[NSString stringWithUTF8String:i.dli_fname] lastPathComponent]?:@"?"; NSString *sym=i.dli_sname?[NSString stringWithUTF8String:i.dli_sname]:@"?"; uintptr_t base=i.dli_saddr?(uintptr_t)i.dli_saddr:a; [s appendFormat:@"  %02lu %@!%@+0x%llx\n",(unsigned long)out,img,sym,(unsigned long long)(a-base)]; out++; }
    return s.length?s:@"  - unavailable\n";
}
static UIScrollView *TableAncestor(UIView *v){ for(UIView *c=v;c;c=c.superview){ if([NSStringFromClass(c.class) isEqualToString:@"TFNTableView"]&&[c isKindOfClass:UIScrollView.class]) return (UIScrollView*)c; } return nil; }
static BOOL IsComments(UIView *v){
    if(!TableAncestor(v)) return NO; BOOL u=NO,c=NO; UIResponder *r=v;
    for(NSUInteger i=0;r&&i<40;i++,r=r.nextResponder){ if(![r isKindOfClass:UIViewController.class]) continue; NSString *n=NSStringFromClass(r.class); if([n isEqualToString:@"T1URTViewController"])u=YES; if([n isEqualToString:@"T1ConversationContainerViewController"])c=YES; }
    return u&&c;
}
static UIScrollView *FindCommentsTableInView(UIView *root){
    if([NSStringFromClass(root.class) isEqualToString:@"TFNTableView"]&&[root isKindOfClass:UIScrollView.class]&&IsComments(root)) return (UIScrollView*)root;
    for(UIView *v in root.subviews){ UIScrollView *x=FindCommentsTableInView(v); if(x) return x; }
    return nil;
}
static UIScrollView *FindCommentsTable(void){
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){ if(![scene isKindOfClass:UIWindowScene.class]) continue; for(UIWindow *w in ((UIWindowScene*)scene).windows){ UIScrollView *t=FindCommentsTableInView(w); if(t) return t; }}
    return nil;
}
static UIView *TreatmentForTable(UIScrollView *table){
    for(UIView *v in table.subviews){ if([NSStringFromClass(v.class) isEqualToString:@"XDesignSystem.ScrollEdgeTreatment"]) return v; }
    return nil;
}
static uint64_t Mix(uint64_t h,uint64_t v){ h^=v; h*=1099511628211ULL; return h; }
static NSArray *SafeArray(CALayer *l,NSString *key){ @try{ id v=[l valueForKey:key]; return [v isKindOfClass:NSArray.class]?v:nil; }@catch(__unused NSException *e){ return nil; }}
static id SafeValue(CALayer *l,NSString *key){ @try{return [l valueForKey:key];}@catch(__unused NSException *e){return nil;} }
static uint64_t SubtreeSig(UIView *v,NSUInteger depth,NSUInteger *views,NSUInteger *filters){
    if(!v||depth>5) return 1469598103934665603ULL; uint64_t h=1469598103934665603ULL; (*views)++;
    h=Mix(h,(uintptr_t)(__bridge void*)v); h=Mix(h,(uintptr_t)v.class);
    CGRect f=v.frame,b=v.bounds; h=Mix(h,(uint64_t)llround(f.origin.x*10)); h=Mix(h,(uint64_t)llround(f.origin.y*10)); h=Mix(h,(uint64_t)llround(f.size.width*10)); h=Mix(h,(uint64_t)llround(f.size.height*10)); h=Mix(h,(uint64_t)llround(b.origin.y*10)); h=Mix(h,(uint64_t)llround(v.alpha*1000)); h=Mix(h,v.hidden?1:0);
    CALayer *l=v.layer; NSArray *fa=SafeArray(l,@"filters")?:@[]; NSArray *ba=SafeArray(l,@"backgroundFilters")?:@[]; id comp=SafeValue(l,@"compositingFilter"); *filters += fa.count+ba.count+(comp?1:0); h=Mix(h,fa.count);h=Mix(h,ba.count);h=Mix(h,(uintptr_t)(__bridge void*)comp); h=Mix(h,l.sublayers.count);h=Mix(h,(uintptr_t)(__bridge void*)l.mask);
    for(UIView *c in v.subviews){ NSUInteger cv=0,cf=0; uint64_t ch=SubtreeSig(c,depth+1,&cv,&cf); *views+=cv;*filters+=cf;h=Mix(h,ch);} return h;
}
typedef struct { CGRect frame,bounds; CGAffineTransform transform; CGFloat alpha; BOOL hidden; NSUInteger subviews,views,filters; uint64_t sig; } Snap;
static Snap Snapshot(UIView *v){ Snap s={0}; if(!v)return s; s.frame=v.frame;s.bounds=v.bounds;s.transform=v.transform;s.alpha=v.alpha;s.hidden=v.hidden;s.subviews=v.subviews.count;NSUInteger vc=0,fc=0;s.sig=SubtreeSig(v,0,&vc,&fc);s.views=vc;s.filters=fc;return s; }
static BOOL SameTransform(CGAffineTransform a,CGAffineTransform b){ return CGAffineTransformEqualToTransform(a,b); }
static NSString *SnapDelta(Snap a,Snap b){
    NSMutableArray *p=[NSMutableArray array]; if(!CGRectEqualToRect(a.frame,b.frame))[p addObject:[NSString stringWithFormat:@"frame %@ -> %@",NSStringFromCGRect(a.frame),NSStringFromCGRect(b.frame)]]; if(!CGRectEqualToRect(a.bounds,b.bounds))[p addObject:[NSString stringWithFormat:@"bounds %@ -> %@",NSStringFromCGRect(a.bounds),NSStringFromCGRect(b.bounds)]]; if(!SameTransform(a.transform,b.transform))[p addObject:@"transform changed"]; if(a.alpha!=b.alpha||a.hidden!=b.hidden)[p addObject:@"visibility changed"]; if(a.subviews!=b.subviews)[p addObject:[NSString stringWithFormat:@"subviews %lu->%lu",(unsigned long)a.subviews,(unsigned long)b.subviews]]; if(a.views!=b.views)[p addObject:[NSString stringWithFormat:@"treeViews %lu->%lu",(unsigned long)a.views,(unsigned long)b.views]]; if(a.filters!=b.filters)[p addObject:[NSString stringWithFormat:@"filters %lu->%lu",(unsigned long)a.filters,(unsigned long)b.filters]]; if(a.sig!=b.sig)[p addObject:[NSString stringWithFormat:@"treeSig %llx->%llx",(unsigned long long)a.sig,(unsigned long long)b.sig]]; return p.count?[p componentsJoinedByString:@" | "]:@"NO OBSERVED MUTATION";
}
static void Inc(NSMutableDictionary *d,NSString *k){ d[k]=@([d[k] unsignedLongLongValue]+1); }
static void RecordNeeds(UIView *v){
    if(!atomic_load(&gActive)||![NSThread isMainThread]||!IsComments(v)) return; Inc(gGlobal,@"needsTotal"); if(CACurrentMediaTime()<=gTransitionUntil&&gCurrentEvent){ Inc(gCurrentEvent,@"needs"); NSMutableArray *a=gCurrentEvent[@"needsStacks"]; if(a.count<2)[a addObject:Stack()]; }
}
static void RecordLayout(UIView *v,SEL cmd){
    if(!gTreatmentLayout) return; BOOL rel=atomic_load(&gActive)&&[NSThread isMainThread]&&IsComments(v); if(!rel){((void(*)(id,SEL))gTreatmentLayout)(v,cmd);return;}
    Snap a=Snapshot(v); CFTimeInterval t=CACurrentMediaTime(); ((void(*)(id,SEL))gTreatmentLayout)(v,cmd); double ms=(CACurrentMediaTime()-t)*1000.0; Snap b=Snapshot(v); Inc(gGlobal,@"layoutTotal"); gGlobal[@"layoutMs"]=@([gGlobal[@"layoutMs"] doubleValue]+ms); gGlobal[@"layoutMax"]=@(MAX([gGlobal[@"layoutMax"] doubleValue],ms));
    if(CACurrentMediaTime()<=gTransitionUntil&&gCurrentEvent){ Inc(gCurrentEvent,@"layouts"); gCurrentEvent[@"layoutMs"]=@([gCurrentEvent[@"layoutMs"] doubleValue]+ms); gCurrentEvent[@"layoutMax"]=@(MAX([gCurrentEvent[@"layoutMax"] doubleValue],ms)); NSString *delta=SnapDelta(a,b); if(![delta isEqualToString:@"NO OBSERVED MUTATION"]) Inc(gCurrentEvent,@"mutations"); NSMutableArray *samples=gCurrentEvent[@"layoutSamples"]; if((ms>0.30||![delta isEqualToString:@"NO OBSERVED MUTATION"])&&samples.count<5)[samples addObject:[NSString stringWithFormat:@"%.3f ms | %@",ms,delta]]; }
}
static void TreatmentLayout(id self,SEL cmd){ RecordLayout((UIView*)self,cmd); }
static void TreatmentNeeds(id self,SEL cmd){ RecordNeeds((UIView*)self); if(gTreatmentNeeds)((void(*)(id,SEL))gTreatmentNeeds)(self,cmd); }
static BOOL Hook(Class cls,SEL sel,IMP repl,IMP *orig){ Method m=class_getInstanceMethod(cls,sel); if(!m)return NO; IMP cur=class_getMethodImplementation(cls,sel); if(cur==repl)return YES; if(orig&&!*orig)*orig=cur; class_replaceMethod(cls,sel,repl,method_getTypeEncoding(m)); return class_getMethodImplementation(cls,sel)==repl; }
static void InstallVisual(void){ if(gHooksInstalled)return; Class c=NSClassFromString(@"XDesignSystem.ScrollEdgeTreatment"); if(!c)return; NSLog(@"[TransitionProbe] layout owner=%@ needs owner=%@",ImageForIMP(class_getMethodImplementation(c,@selector(layoutSubviews))),ImageForIMP(class_getMethodImplementation(c,@selector(setNeedsLayout)))); BOOL a=Hook(c,@selector(layoutSubviews),(IMP)TreatmentLayout,&gTreatmentLayout); BOOL b=Hook(c,@selector(setNeedsLayout),(IMP)TreatmentNeeds,&gTreatmentNeeds); gHooksInstalled=a||b; }
static NSMutableDictionary *NewEvent(NSString *type,double dy,UIScrollView *t){
    UIView *tr=TreatmentForTable(t); Snap s=Snapshot(tr); NSMutableDictionary *e=[@{@"time":@(CACurrentMediaTime()-gStart),@"type":type,@"dy":@(dy),@"offset":@(t.contentOffset.y),@"treatment":@((uintptr_t)(__bridge void*)tr),@"frame":tr?NSStringFromCGRect(tr.frame):@"-",@"treeViews":@(s.views),@"filters":@(s.filters),@"treeSig":@(s.sig),@"layouts":@0,@"needs":@0,@"layoutMs":@0.0,@"layoutMax":@0.0,@"mutations":@0,@"maxFrameMs":@0.0,@"frameOver16":@0,@"frameOver25":@0,@"frameOver33":@0,@"layoutSamples":[NSMutableArray array],@"needsStacks":[NSMutableArray array]} mutableCopy]; [gEvents addObject:e]; gCurrentEvent=e; gTransitionUntil=CACurrentMediaTime()+kTransitionWindow; return e;
}
static void Tick(CADisplayLink *link){
    if(!atomic_load(&gActive)) return; CFTimeInterval now=CACurrentMediaTime(); double frameMs=gLastTick>0?(now-gLastTick)*1000.0:0; gLastTick=now; if(!gTrackedTable||!gTrackedTable.window) gTrackedTable=FindCommentsTable(); UIScrollView *t=gTrackedTable; if(!t)return; CGFloat y=t.contentOffset.y,dy=y-gLastOffset; gLastOffset=y; int dir=(dy>0.75)?1:(dy<-0.75)?-1:0; BOOL moving=fabs(dy)>0.75;
    if(moving){ gStillFrames=0; if(!gWasMoving){ NewEvent(@"SCROLL_START",dy,t); } else if(dir&&gLastDir&&dir!=gLastDir){ NewEvent(@"DIRECTION_CHANGE",dy,t); } gWasMoving=YES; if(dir)gLastDir=dir; }
    else { if(gWasMoving){ gStillFrames++; if(gStillFrames>=3){ NewEvent(@"SCROLL_STOP",dy,t); gWasMoving=NO; gLastDir=0; gStillFrames=0; }} }
    if(gCurrentEvent&&now<=gTransitionUntil&&frameMs>0){ gCurrentEvent[@"maxFrameMs"]=@(MAX([gCurrentEvent[@"maxFrameMs"] doubleValue],frameMs)); if(frameMs>16.7)Inc(gCurrentEvent,@"frameOver16"); if(frameMs>25.0)Inc(gCurrentEvent,@"frameOver25"); if(frameMs>33.3)Inc(gCurrentEvent,@"frameOver33"); }
}
static NSString *BuildReport(double duration){
    NSDictionary *i=NSBundle.mainBundle.infoDictionary; NSMutableString *r=[NSMutableString string]; [r appendString:@"============================================================\n"]; [r appendFormat:@"XLiquidGlass Comments Transition Probe %@ - captura #%lu\n",kVersion,(unsigned long)gSerial]; [r appendFormat:@"Data: %@\nApp: %@ build %@ | bundle=%@\nDuracao real: %.3f s\n",Stamp(),i[@"CFBundleShortVersionString"]?:@"-",i[@"CFBundleVersion"]?:@"-",NSBundle.mainBundle.bundleIdentifier?:@"-",duration]; [r appendFormat:@"ScrollEdge layout owner antes da probe=%@\n",ImageForIMP(gTreatmentLayout)]; [r appendString:@"Janela por evento: 250 ms. Mede frame time + ScrollEdgeTreatment layout/setNeeds/geometria/subarvore.\n============================================================\n\n"];
    [r appendFormat:@"global layout=%llu setNeeds=%llu layout total=%.3f ms max=%.3f ms | eventos=%lu\n\n",[gGlobal[@"layoutTotal"] unsignedLongLongValue],[gGlobal[@"needsTotal"] unsignedLongLongValue],[gGlobal[@"layoutMs"] doubleValue],[gGlobal[@"layoutMax"] doubleValue],(unsigned long)gEvents.count];
    NSUInteger idx=0; for(NSDictionary *e in gEvents){ [r appendFormat:@"#%lu %.3fs %@ dy=%+.2f offset=%.1f treatment=0x%llx frame=%@ treeViews=%lu filters=%lu sig=%llx\n",(unsigned long)++idx,[e[@"time"] doubleValue],e[@"type"],[e[@"dy"] doubleValue],[e[@"offset"] doubleValue],[e[@"treatment"] unsignedLongLongValue],e[@"frame"],[e[@"treeViews"] unsignedLongValue],[e[@"filters"] unsignedLongValue],[e[@"treeSig"] unsignedLongLongValue]]; [r appendFormat:@"  frame max=%.2f ms >16.7=%llu >25=%llu >33.3=%llu | layouts=%llu needs=%llu mutations=%llu layoutMs=%.3f max=%.3f\n",[e[@"maxFrameMs"] doubleValue],[e[@"frameOver16"] unsignedLongLongValue],[e[@"frameOver25"] unsignedLongLongValue],[e[@"frameOver33"] unsignedLongLongValue],[e[@"layouts"] unsignedLongLongValue],[e[@"needs"] unsignedLongLongValue],[e[@"mutations"] unsignedLongLongValue],[e[@"layoutMs"] doubleValue],[e[@"layoutMax"] doubleValue]]; for(NSString *s in e[@"layoutSamples"])[r appendFormat:@"  layout: %@\n",s]; NSUInteger n=0; for(NSString *s in e[@"needsStacks"]){[r appendFormat:@"  needs stack %lu:\n%@",(unsigned long)++n,s];} [r appendString:@"\n"]; }
    [r appendString:@"[FIM DA CAPTURA]\n============================================================\n"]; return r;
}
static UIViewController *TopVC(void){ UIWindow *w=nil; for(UIScene *s in UIApplication.sharedApplication.connectedScenes){ if(![s isKindOfClass:UIWindowScene.class])continue; for(UIWindow *x in ((UIWindowScene*)s).windows)if(x.isKeyWindow){w=x;break;} if(w)break;} UIViewController *v=w.rootViewController; while(v.presentedViewController)v=v.presentedViewController; return v; }
static void Finish(void){ if(!atomic_exchange(&gActive,false))return; [gDisplayLink invalidate];gDisplayLink=nil; double d=CACurrentMediaTime()-gStart; gLastReport=BuildReport(d); [gLastReport writeToFile:ReportPath() atomically:YES encoding:NSUTF8StringEncoding error:nil]; UIPasteboard.generalPasteboard.string=gLastReport; UIViewController *v=TopVC(); if(v){ UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Transition Probe" message:@"Captura concluida e relatorio copiado." preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [v presentViewController:a animated:YES completion:nil]; }}
static void Begin(void){ if(!gArmed)return; gArmed=NO; gSerial++; gEvents=[NSMutableArray array]; gGlobal=[@{@"layoutTotal":@0,@"needsTotal":@0,@"layoutMs":@0.0,@"layoutMax":@0.0} mutableCopy]; gTrackedTable=FindCommentsTable(); gLastOffset=gTrackedTable?gTrackedTable.contentOffset.y:0; gLastDir=0;gWasMoving=NO;gStillFrames=0;gLastTick=0;gStart=CACurrentMediaTime();atomic_store(&gActive,true); gDisplayLink=[CADisplayLink displayLinkWithTarget:[NSBlockOperation blockOperationWithBlock:^{}] selector:@selector(main)]; [gDisplayLink invalidate]; gDisplayLink=[CADisplayLink displayLinkWithTarget:[XLGTicker shared] selector:@selector(tick:)]; [gDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes]; dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(kCapture*NSEC_PER_SEC)),dispatch_get_main_queue(),^{Finish();}); }

@interface XLGTicker:NSObject + (instancetype)shared; - (void)tick:(CADisplayLink*)link; @end
@implementation XLGTicker + (instancetype)shared{ static XLGTicker *x; static dispatch_once_t once; dispatch_once(&once,^{x=[XLGTicker new];}); return x;} - (void)tick:(CADisplayLink*)link{Tick(link);} @end

@interface XLGTransitionProbeVC:UITableViewController @end
@implementation XLGTransitionProbeVC
- (instancetype)init{return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad{[super viewDidLoad];self.title=@"Transition Probe";}
- (NSInteger)tableView:(UITableView*)t numberOfRowsInSection:(NSInteger)s{return 3;}
- (NSInteger)numberOfSectionsInTableView:(UITableView*)t{return 1;}
- (NSString*)tableView:(UITableView*)t titleForFooterInSection:(NSInteger)s{return @"Aguarde 8 s. Nos comentarios, faca varias inversoes de direcao por 15 s.";}
- (UITableViewCell*)tableView:(UITableView*)t cellForRowAtIndexPath:(NSIndexPath*)p{UITableViewCell*c=[t dequeueReusableCellWithIdentifier:@"c"];if(!c)c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"]; if(p.row==0){c.textLabel.text=@"Iniciar diagnostico";c.detailTextLabel.text=@"8 s + 15 s";}else if(p.row==1){c.textLabel.text=@"Copiar relatorio";}else{c.textLabel.text=@"Limpar relatorio";}return c;}
- (void)tableView:(UITableView*)t didSelectRowAtIndexPath:(NSIndexPath*)p{[t deselectRowAtIndexPath:p animated:YES]; if(p.row==0){UIAlertController*a=[UIAlertController alertControllerWithTitle:@"Transition Probe" message:@"Volte aos comentarios em 8 segundos. Depois alterne a direcao varias vezes." preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]]; [a addAction:[UIAlertAction actionWithTitle:@"Comecar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction*x){gArmed=YES;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(kPrep*NSEC_PER_SEC)),dispatch_get_main_queue(),^{Begin();});}]]; [self presentViewController:a animated:YES completion:nil];} else if(p.row==1){NSString*x=gLastReport;if(!x.length)x=[NSString stringWithContentsOfFile:ReportPath() encoding:NSUTF8StringEncoding error:nil];if(x.length)UIPasteboard.generalPasteboard.string=x;}else{gLastReport=nil;[[NSFileManager defaultManager]removeItemAtPath:ReportPath() error:nil];}}
@end
static BOOL HasEntry(NSArray*a){for(id x in a)if([x isKindOfClass:NSDictionary.class]&&[x[@"action"] isEqualToString:@"showXLiquidGlassTransitionProbe"])return YES;return NO;}
static void InjectMenu(id c){NSArray*a=nil;@try{a=[c valueForKey:@"sections"];}@catch(__unused NSException*e){return;}if(![a isKindOfClass:NSArray.class]||HasEntry(a))return;NSMutableArray*m=[a mutableCopy];[m addObject:@{@"title":@"Transition Probe",@"subtitle":@"Inicio/inversao do scroll nos comentarios.",@"icon":@"arrow.up.arrow.down",@"action":@"showXLiquidGlassTransitionProbe"}];@try{[c setValue:[m copy] forKey:@"sections"];}@catch(__unused NSException*e){}}
static void SettingsSetup(id self,SEL cmd){if(gSettingsSetup)((void(*)(id,SEL))gSettingsSetup)(self,cmd);InjectMenu(self);}
static void SettingsWillAppear(id self,SEL cmd,BOOL a){if(gSettingsWillAppear)((void(*)(id,SEL,BOOL))gSettingsWillAppear)(self,cmd,a);InjectMenu(self);UITableView*t=nil;@try{t=[self valueForKey:@"tableView"];}@catch(__unused NSException*e){}[t reloadData];}
static void Show(id self,SEL cmd){if(![self isKindOfClass:UIViewController.class])return;UIViewController*v=self;XLGTransitionProbeVC*p=[XLGTransitionProbeVC new];if(v.navigationController)[v.navigationController pushViewController:p animated:YES];else[v presentViewController:[[UINavigationController alloc]initWithRootViewController:p] animated:YES completion:nil];}
static void InstallSettings(void){if(gSettingsInstalled)return;Class c=NSClassFromString(@"ModernSettingsViewController");if(!c)return;class_addMethod(c,NSSelectorFromString(@"showXLiquidGlassTransitionProbe"),(IMP)Show,"v@:");BOOL a=Hook(c,NSSelectorFromString(@"setupSections"),(IMP)SettingsSetup,&gSettingsSetup);BOOL b=Hook(c,@selector(viewWillAppear:),(IMP)SettingsWillAppear,&gSettingsWillAppear);gSettingsInstalled=a||b;}
static void Install(void){InstallVisual();InstallSettings();}
__attribute__((constructor)) static void Init(void){@autoreleasepool{NSLog(@"[XLiquidGlassCommentsTransitionProbe] %@ loaded",kVersion);Install();for(NSNumber*d in @[@0.05,@0.2,@0.5,@1,@2,@4,@8])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(d.doubleValue*NSEC_PER_SEC)),dispatch_get_main_queue(),^{Install();});}}
