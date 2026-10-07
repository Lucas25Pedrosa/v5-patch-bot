#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

// Nexus 2.2 Beta 1 — adaptive OLED engine.
// Replaces the exact-color whitelist with dark-trait resolution plus
// luminance/neutrality classification while preserving source alpha.

static NSString * const NX22OLEDKey = @"iQFaceOLEDEnabled";
static const void *NX22OriginalViewColorKey = &NX22OriginalViewColorKey;
static const void *NX22OriginalLayerColorKey = &NX22OriginalLayerColorKey;
static BOOL NX22Enabled = YES;
static NSTimer *NX22Timer;

static BOOL NX22ReadEnabled(void) {
    Class prefs = NSClassFromString(@"IQFPrefs");
    SEL sel = NSSelectorFromString(@"boolForKey:defaultValue:");
    if (prefs && [prefs respondsToSelector:sel]) {
        typedef BOOL (*Fn)(id,SEL,id,BOOL);
        return ((Fn)(void *)objc_msgSend)(prefs,sel,NX22OLEDKey,YES);
    }
    id value = [NSUserDefaults.standardUserDefaults objectForKey:NX22OLEDKey];
    return value == nil ? YES : [value boolValue];
}

static UIColor *NX22ResolveDark(UIColor *color) {
    if (!color) return nil;
    @try {
        UITraitCollection *dark = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark];
        return [color resolvedColorWithTraitCollection:dark];
    } @catch (__unused NSException *e) { return color; }
}

static BOOL NX22Components(UIColor *color, CGFloat *r, CGFloat *g, CGFloat *b, CGFloat *a) {
    UIColor *c = NX22ResolveDark(color);
    if (!c) return NO;
    if ([c getRed:r green:g blue:b alpha:a]) return YES;
    CGFloat w=0;
    if ([c getWhite:&w alpha:a]) { *r=*g=*b=w; return YES; }
    return NO;
}

static BOOL NX22ShouldOLED(UIColor *color, CGFloat *alphaOut) {
    CGFloat r=0,g=0,b=0,a=0;
    if (!NX22Components(color,&r,&g,&b,&a) || a <= 0.001) return NO;
    if (alphaOut) *alphaOut=a;
    CGFloat maxc=MAX(r,MAX(g,b)), minc=MIN(r,MIN(g,b));
    CGFloat luminance=0.2126*r+0.7152*g+0.0722*b;
    CGFloat chroma=maxc-minc;
    return luminance <= 0.205 && maxc <= 0.235 && chroma <= 0.055;
}

static UIColor *NX22OLEDColor(UIColor *source) {
    CGFloat a=1.0;
    if (!NX22ShouldOLED(source,&a)) return nil;
    return [UIColor colorWithWhite:0 alpha:a];
}

static BOOL NX22IsBlack(UIColor *color) {
    CGFloat r=0,g=0,b=0,a=0;
    return NX22Components(color,&r,&g,&b,&a) && r<0.002 && g<0.002 && b<0.002 && a>0.001;
}

static BOOL NX22Excluded(UIView *view) {
    NSString *n=NSStringFromClass(view.class);
    return [n hasPrefix:@"Nexus2"] || [n hasPrefix:@"NX22"];
}

@interface UIView (NX22OLED)
- (void)nx22_setBackgroundColor:(UIColor *)color;
@end
@implementation UIView (NX22OLED)
- (void)nx22_setBackgroundColor:(UIColor *)color {
    NX22Enabled=NX22ReadEnabled();
    UIColor *saved=objc_getAssociatedObject(self,NX22OriginalViewColorKey);
    if (NX22Enabled && !NX22Excluded(self)) {
        UIColor *oled=NX22OLEDColor(color);
        if (oled) {
            if (!saved) objc_setAssociatedObject(self,NX22OriginalViewColorKey,color,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [self nx22_setBackgroundColor:oled];
            return;
        }
    }
    if (!(saved && NX22IsBlack(color))) objc_setAssociatedObject(self,NX22OriginalViewColorKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self nx22_setBackgroundColor:color];
}
@end

static void NX22Transform(UIView *view) {
    if (!view || view.hidden || view.alpha<0.01) return;
    UIColor *saved=objc_getAssociatedObject(view,NX22OriginalViewColorKey);
    if (NX22Enabled && !NX22Excluded(view)) {
        UIColor *source=saved ?: view.backgroundColor;
        UIColor *oled=NX22OLEDColor(source);
        if (oled) {
            if (!saved && source) objc_setAssociatedObject(view,NX22OriginalViewColorKey,source,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!NX22IsBlack(view.backgroundColor)) view.backgroundColor=oled;
        }
    } else if (saved) {
        [view nx22_setBackgroundColor:saved];
        objc_setAssociatedObject(view,NX22OriginalViewColorKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!NX22Excluded(view) && view.layer.backgroundColor) {
        UIColor *savedLayer=objc_getAssociatedObject(view.layer,NX22OriginalLayerColorKey);
        UIColor *current=[UIColor colorWithCGColor:view.layer.backgroundColor];
        if (NX22Enabled) {
            UIColor *source=savedLayer ?: current;
            UIColor *oled=NX22OLEDColor(source);
            if (oled) {
                if (!savedLayer) objc_setAssociatedObject(view.layer,NX22OriginalLayerColorKey,source,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                view.layer.backgroundColor=oled.CGColor;
            }
        } else if (savedLayer) {
            view.layer.backgroundColor=savedLayer.CGColor;
            objc_setAssociatedObject(view.layer,NX22OriginalLayerColorKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    for (UIView *child in view.subviews.copy) NX22Transform(child);
}

static void NX22RunPass(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{ NX22RunPass(); }); return; }
    NX22Enabled=NX22ReadEnabled();
    @try {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) NX22Transform(window);
        }
    } @catch (__unused NSException *e) {}
}

__attribute__((used,visibility("default"))) const char *Nexus22OLEDEngine="adaptive-dark-neutral-alpha-preserving";

__attribute__((constructor)) static void NX22Init(void) {
    @autoreleasepool {
        Method a=class_getInstanceMethod(UIView.class,@selector(setBackgroundColor:));
        Method b=class_getInstanceMethod(UIView.class,@selector(nx22_setBackgroundColor:));
        if (a && b) method_exchangeImplementations(a,b);
        dispatch_async(dispatch_get_main_queue(),^{
            NX22RunPass();
            NX22Timer=[NSTimer timerWithTimeInterval:0.85 repeats:YES block:^(__unused NSTimer *t){ NX22RunPass(); }];
            NX22Timer.tolerance=0.20;
            [NSRunLoop.mainRunLoop addTimer:NX22Timer forMode:NSRunLoopCommonModes];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){ NX22RunPass(); }];
            [NSNotificationCenter.defaultCenter addObserverForName:@"NexusSettingsDidChange" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){ NX22RunPass(); }];
        });
    }
}
