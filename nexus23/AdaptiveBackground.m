#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

// Nexus 2.3 Beta 1 — adaptive background engine.
// Keeps the validated Nexus 2.2 dark-neutral classifier and adds a custom
// destination color. Original alpha is always preserved.

static NSString * const NX23OLEDKey = @"iQFaceOLEDEnabled";
static NSString * const NX23CustomEnabledKey = @"NexusCustomBackgroundEnabled";
static NSString * const NX23CustomColorKey = @"NexusCustomBackgroundColor";
static const void *NX23OriginalViewColorKey = &NX23OriginalViewColorKey;
static const void *NX23OriginalLayerColorKey = &NX23OriginalLayerColorKey;
static BOOL NX23Enabled = YES;
static NSTimer *NX23Timer;

static id NX23PrefObject(NSString *key) {
    Class prefs=NSClassFromString(@"IQFPrefs");
    SEL sel=NSSelectorFromString(@"objectForKey:");
    if (prefs && [prefs respondsToSelector:sel]) {
        typedef id (*Fn)(id,SEL,id);
        id v=((Fn)(void *)objc_msgSend)(prefs,sel,key);
        if (v) return v;
    }
    return [NSUserDefaults.standardUserDefaults objectForKey:key];
}
static BOOL NX23PrefBool(NSString *key, BOOL fallback) {
    Class prefs=NSClassFromString(@"IQFPrefs");
    SEL sel=NSSelectorFromString(@"boolForKey:defaultValue:");
    if (prefs && [prefs respondsToSelector:sel]) {
        typedef BOOL (*Fn)(id,SEL,id,BOOL);
        return ((Fn)(void *)objc_msgSend)(prefs,sel,key,fallback);
    }
    id v=[NSUserDefaults.standardUserDefaults objectForKey:key];
    return v ? [v boolValue] : fallback;
}
static UIColor *NX23ResolveDark(UIColor *color) {
    if (!color) return nil;
    @try { return [color resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]]; }
    @catch (__unused NSException *e) { return color; }
}
static BOOL NX23Components(UIColor *color, CGFloat *r, CGFloat *g, CGFloat *b, CGFloat *a) {
    UIColor *c=NX23ResolveDark(color); if (!c) return NO;
    if ([c getRed:r green:g blue:b alpha:a]) return YES;
    CGFloat w=0; if ([c getWhite:&w alpha:a]) { *r=*g=*b=w; return YES; }
    return NO;
}
static BOOL NX23ShouldTransform(UIColor *color, CGFloat *alphaOut) {
    CGFloat r=0,g=0,b=0,a=0;
    if (!NX23Components(color,&r,&g,&b,&a) || a<=0.001) return NO;
    if (alphaOut) *alphaOut=a;
    CGFloat maxc=MAX(r,MAX(g,b)), minc=MIN(r,MIN(g,b));
    CGFloat luminance=0.2126*r+0.7152*g+0.0722*b;
    CGFloat chroma=maxc-minc;
    return luminance<=0.205 && maxc<=0.235 && chroma<=0.055;
}
static UIColor *NX23ColorFromHex(NSString *hex) {
    if (![hex isKindOfClass:NSString.class]) return nil;
    NSString *s=[[hex stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if ([s hasPrefix:@"#"]) s=[s substringFromIndex:1];
    if (s.length!=6) return nil;
    unsigned value=0; NSScanner *scanner=[NSScanner scannerWithString:s];
    if (![scanner scanHexInt:&value]) return nil;
    return [UIColor colorWithRed:((value>>16)&0xFF)/255.0 green:((value>>8)&0xFF)/255.0 blue:(value&0xFF)/255.0 alpha:1.0];
}
static UIColor *NX23Destination(UIColor *source) {
    CGFloat a=1.0; if (!NX23ShouldTransform(source,&a)) return nil;
    UIColor *base=nil;
    if (NX23PrefBool(NX23CustomEnabledKey,NO)) base=NX23ColorFromHex(NX23PrefObject(NX23CustomColorKey));
    if (!base) base=[UIColor blackColor];
    CGFloat r=0,g=0,b=0,ignored=0;
    if (![base getRed:&r green:&g blue:&b alpha:&ignored]) return [UIColor colorWithWhite:0 alpha:a];
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}
static BOOL NX23SameColor(UIColor *a, UIColor *b) {
    CGFloat ar=0,ag=0,ab=0,aa=0,br=0,bg=0,bb=0,ba=0;
    return NX23Components(a,&ar,&ag,&ab,&aa) && NX23Components(b,&br,&bg,&bb,&ba) && fabs(ar-br)<0.002 && fabs(ag-bg)<0.002 && fabs(ab-bb)<0.002 && fabs(aa-ba)<0.002;
}
static BOOL NX23Excluded(UIView *view) {
    NSString *n=NSStringFromClass(view.class);
    return [n hasPrefix:@"Nexus2"] || [n hasPrefix:@"NX22"] || [n hasPrefix:@"NX23"];
}
@interface UIView (NX23Background)
- (void)nx23_setBackgroundColor:(UIColor *)color;
@end
@implementation UIView (NX23Background)
- (void)nx23_setBackgroundColor:(UIColor *)color {
    NX23Enabled=NX23PrefBool(NX23OLEDKey,YES);
    UIColor *saved=objc_getAssociatedObject(self,NX23OriginalViewColorKey);
    if (NX23Enabled && !NX23Excluded(self)) {
        UIColor *dest=NX23Destination(color);
        if (dest) {
            if (!saved) objc_setAssociatedObject(self,NX23OriginalViewColorKey,color,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [self nx23_setBackgroundColor:dest]; return;
        }
    }
    if (!(saved && NX23SameColor(color,NX23Destination(saved)))) objc_setAssociatedObject(self,NX23OriginalViewColorKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self nx23_setBackgroundColor:color];
}
@end
static void NX23Transform(UIView *view) {
    if (!view || view.hidden || view.alpha<0.01) return;
    UIColor *saved=objc_getAssociatedObject(view,NX23OriginalViewColorKey);
    if (NX23Enabled && !NX23Excluded(view)) {
        UIColor *source=saved ?: view.backgroundColor;
        UIColor *dest=NX23Destination(source);
        if (dest) {
            if (!saved && source) objc_setAssociatedObject(view,NX23OriginalViewColorKey,source,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!NX23SameColor(view.backgroundColor,dest)) [view nx23_setBackgroundColor:dest];
        }
    } else if (saved) {
        [view nx23_setBackgroundColor:saved];
        objc_setAssociatedObject(view,NX23OriginalViewColorKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!NX23Excluded(view) && view.layer.backgroundColor) {
        UIColor *savedLayer=objc_getAssociatedObject(view.layer,NX23OriginalLayerColorKey);
        UIColor *current=[UIColor colorWithCGColor:view.layer.backgroundColor];
        if (NX23Enabled) {
            UIColor *source=savedLayer ?: current, *dest=NX23Destination(source);
            if (dest) {
                if (!savedLayer) objc_setAssociatedObject(view.layer,NX23OriginalLayerColorKey,source,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                view.layer.backgroundColor=dest.CGColor;
            }
        } else if (savedLayer) {
            view.layer.backgroundColor=savedLayer.CGColor;
            objc_setAssociatedObject(view.layer,NX23OriginalLayerColorKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    for (UIView *child in view.subviews.copy) NX23Transform(child);
}
static void NX23RunPass(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{ NX23RunPass(); }); return; }
    NX23Enabled=NX23PrefBool(NX23OLEDKey,YES);
    @try { for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) if ([scene isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)scene).windows) NX23Transform(w); } @catch (__unused NSException *e) {}
}
__attribute__((used,visibility("default"))) const char *Nexus23BackgroundEngine="adaptive-dark-neutral-custom-color-alpha-preserving";
__attribute__((constructor)) static void NX23Init(void) {
    @autoreleasepool {
        Method a=class_getInstanceMethod(UIView.class,@selector(setBackgroundColor:)), b=class_getInstanceMethod(UIView.class,@selector(nx23_setBackgroundColor:));
        if (a&&b) method_exchangeImplementations(a,b);
        dispatch_async(dispatch_get_main_queue(),^{
            NX23RunPass();
            NX23Timer=[NSTimer timerWithTimeInterval:0.85 repeats:YES block:^(__unused NSTimer *t){ NX23RunPass(); }];
            NX23Timer.tolerance=0.20; [NSRunLoop.mainRunLoop addTimer:NX23Timer forMode:NSRunLoopCommonModes];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){ NX23RunPass(); }];
            [NSNotificationCenter.defaultCenter addObserverForName:@"NexusSettingsDidChange" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){ NX23RunPass(); }];
        });
    }
}
