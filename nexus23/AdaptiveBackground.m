#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

static NSString * const NX23OLEDKey=@"iQFaceOLEDEnabled";
static NSString * const NX23CustomEnabledKey=@"NexusCustomBackgroundEnabled";
static NSString * const NX23CustomColorKey=@"NexusCustomBackgroundColor";
static const void *NX23OriginalViewColorKey=&NX23OriginalViewColorKey;
static const void *NX23OriginalLayerColorKey=&NX23OriginalLayerColorKey;
static BOOL NX23Enabled=YES; static NSTimer *NX23Timer;

static BOOL NX23OLEDPreference(void) {
    Class prefs=NSClassFromString(@"IQFPrefs"); SEL sel=NSSelectorFromString(@"boolForKey:defaultValue:");
    if (prefs&&[prefs respondsToSelector:sel]) { typedef BOOL(*Fn)(id,SEL,id,BOOL); return ((Fn)(void*)objc_msgSend)(prefs,sel,NX23OLEDKey,YES); }
    id v=[NSUserDefaults.standardUserDefaults objectForKey:NX23OLEDKey]; return v?[v boolValue]:YES;
}
static BOOL NX23CustomEnabled(void) { return [NSUserDefaults.standardUserDefaults boolForKey:NX23CustomEnabledKey]; }
static NSString *NX23CustomHex(void) { id v=[NSUserDefaults.standardUserDefaults objectForKey:NX23CustomColorKey]; return [v isKindOfClass:NSString.class]?v:nil; }
static UIColor *NX23ResolveDark(UIColor *color) { if(!color)return nil; @try{return [color resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]];}@catch(__unused NSException*e){return color;} }
static BOOL NX23Components(UIColor *color,CGFloat*r,CGFloat*g,CGFloat*b,CGFloat*a){UIColor*c=NX23ResolveDark(color);if(!c)return NO;if([c getRed:r green:g blue:b alpha:a])return YES;CGFloat w=0;if([c getWhite:&w alpha:a]){*r=*g=*b=w;return YES;}return NO;}
static BOOL NX23ShouldTransform(UIColor *color,CGFloat *alphaOut){CGFloat r=0,g=0,b=0,a=0;if(!NX23Components(color,&r,&g,&b,&a)||a<=.001)return NO;if(alphaOut)*alphaOut=a;CGFloat maxc=MAX(r,MAX(g,b)),minc=MIN(r,MIN(g,b));CGFloat lum=.2126*r+.7152*g+.0722*b,chroma=maxc-minc;return lum<=.205&&maxc<=.235&&chroma<=.055;}
static UIColor *NX23ColorFromHex(NSString *hex){if(![hex isKindOfClass:NSString.class])return nil;NSString*s=[[hex stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]uppercaseString];if([s hasPrefix:@"#"])s=[s substringFromIndex:1];if(s.length!=6)return nil;unsigned x=0;if(![[NSScanner scannerWithString:s]scanHexInt:&x])return nil;return[UIColor colorWithRed:((x>>16)&255)/255.0 green:((x>>8)&255)/255.0 blue:(x&255)/255.0 alpha:1];}
static UIColor *NX23Destination(UIColor *source){CGFloat a=1;if(!NX23ShouldTransform(source,&a))return nil;UIColor*base=NX23CustomEnabled()?NX23ColorFromHex(NX23CustomHex()):nil;if(!base)base=UIColor.blackColor;CGFloat r=0,g=0,b=0,z=0;if(![base getRed:&r green:&g blue:&b alpha:&z])return[UIColor colorWithWhite:0 alpha:a];return[UIColor colorWithRed:r green:g blue:b alpha:a];}
static BOOL NX23SameColor(UIColor*a,UIColor*b){if(!a||!b)return a==b;CGFloat ar=0,ag=0,ab=0,aa=0,br=0,bg=0,bb=0,ba=0;return NX23Components(a,&ar,&ag,&ab,&aa)&&NX23Components(b,&br,&bg,&bb,&ba)&&fabs(ar-br)<.002&&fabs(ag-bg)<.002&&fabs(ab-bb)<.002&&fabs(aa-ba)<.002;}
static BOOL NX23Excluded(UIView*v){NSString*n=NSStringFromClass(v.class);return[n hasPrefix:@"Nexus2"]||[n hasPrefix:@"NX22"]||[n hasPrefix:@"NX23"];}
@interface UIView(NX23Background)-(void)nx23_setBackgroundColor:(UIColor*)color;@end
@implementation UIView(NX23Background)
-(void)nx23_setBackgroundColor:(UIColor*)color{NX23Enabled=NX23OLEDPreference();UIColor*saved=objc_getAssociatedObject(self,NX23OriginalViewColorKey);if(NX23Enabled&&!NX23Excluded(self)){UIColor*dest=NX23Destination(color);if(dest){if(!saved&&color)objc_setAssociatedObject(self,NX23OriginalViewColorKey,color,OBJC_ASSOCIATION_RETAIN_NONATOMIC);[self nx23_setBackgroundColor:dest];return;}}if(saved&&!NX23Enabled){[self nx23_setBackgroundColor:saved];objc_setAssociatedObject(self,NX23OriginalViewColorKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);return;}[self nx23_setBackgroundColor:color];}
@end
static void NX23Transform(UIView*v){if(!v||v.hidden||v.alpha<.01)return;UIColor*saved=objc_getAssociatedObject(v,NX23OriginalViewColorKey);if(NX23Enabled&&!NX23Excluded(v)){UIColor*source=saved?:v.backgroundColor,*dest=NX23Destination(source);if(dest){if(!saved&&source)objc_setAssociatedObject(v,NX23OriginalViewColorKey,source,OBJC_ASSOCIATION_RETAIN_NONATOMIC);if(!NX23SameColor(v.backgroundColor,dest))[v nx23_setBackgroundColor:dest];}}else if(saved){[v nx23_setBackgroundColor:saved];objc_setAssociatedObject(v,NX23OriginalViewColorKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}if(!NX23Excluded(v)&&v.layer.backgroundColor){UIColor*sl=objc_getAssociatedObject(v.layer,NX23OriginalLayerColorKey);UIColor*cur=[UIColor colorWithCGColor:v.layer.backgroundColor];if(NX23Enabled){UIColor*source=sl?:cur,*dest=NX23Destination(source);if(dest){if(!sl)objc_setAssociatedObject(v.layer,NX23OriginalLayerColorKey,source,OBJC_ASSOCIATION_RETAIN_NONATOMIC);v.layer.backgroundColor=dest.CGColor;}}else if(sl){v.layer.backgroundColor=sl.CGColor;objc_setAssociatedObject(v.layer,NX23OriginalLayerColorKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}}for(UIView*c in v.subviews.copy)NX23Transform(c);}
static void NX23RunPass(void){if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{NX23RunPass();});return;}NX23Enabled=NX23OLEDPreference();@try{for(UIScene*s in UIApplication.sharedApplication.connectedScenes)if([s isKindOfClass:UIWindowScene.class])for(UIWindow*w in((UIWindowScene*)s).windows)NX23Transform(w);}@catch(__unused NSException*e){}}
__attribute__((used,visibility("default")))const char*Nexus23BackgroundEngine="adaptive-dark-neutral-custom-color-alpha-preserving";
__attribute__((constructor))static void NX23Init(void){@autoreleasepool{Method a=class_getInstanceMethod(UIView.class,@selector(setBackgroundColor:)),b=class_getInstanceMethod(UIView.class,@selector(nx23_setBackgroundColor:));if(a&&b)method_exchangeImplementations(a,b);dispatch_async(dispatch_get_main_queue(),^{NX23RunPass();NX23Timer=[NSTimer timerWithTimeInterval:.85 repeats:YES block:^(__unused NSTimer*t){NX23RunPass();}];NX23Timer.tolerance=.20;[NSRunLoop.mainRunLoop addTimer:NX23Timer forMode:NSRunLoopCommonModes];[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification*n){NX23RunPass();}];[NSNotificationCenter.defaultCenter addObserverForName:@"NexusSettingsDidChange" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification*n){NX23RunPass();}];});}}
