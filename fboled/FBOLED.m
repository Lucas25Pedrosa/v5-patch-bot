#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>

// FBOLED 0.1.0
// Hook-free OLED pass for Facebook 577+.
// The palette below was measured from FBOLED_ViewMap.csv on Facebook 577.0.0.

static const void *kFBOLEDOriginalViewColorKey = &kFBOLEDOriginalViewColorKey;
static const void *kFBOLEDOriginalLayerColorKey = &kFBOLEDOriginalLayerColorKey;

static NSTimer *gFBOLEDTimer;
static id gFBOLEDActiveObserver;
static BOOL gFBOLEDModeKnown;
static BOOL gFBOLEDDarkMode;

static uint32_t FBOLEDRGBA(UIColor *color, UITraitCollection *traits) {
    if (!color) return UINT32_MAX;

    UIColor *resolved = color;
    @try {
        if (traits) resolved = [color resolvedColorWithTraitCollection:traits];
    } @catch (__unused NSException *exception) {
        return UINT32_MAX;
    }

    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![resolved getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat white = 0.0;
        if (![resolved getWhite:&white alpha:&alpha]) return UINT32_MAX;
        red = green = blue = white;
    }

    uint32_t r = (uint32_t)llround(MAX(0.0, MIN(1.0, red)) * 255.0);
    uint32_t g = (uint32_t)llround(MAX(0.0, MIN(1.0, green)) * 255.0);
    uint32_t b = (uint32_t)llround(MAX(0.0, MIN(1.0, blue)) * 255.0);
    uint32_t a = (uint32_t)llround(MAX(0.0, MIN(1.0, alpha)) * 255.0);
    return (r << 24) | (g << 16) | (b << 8) | a;
}

static BOOL FBOLEDIsMappedDark(uint32_t rgba) {
    switch (rgba) {
        case 0x101011FF: // Feed and feed cells
        case 0x1F1F22FF: // Full-screen auxiliary surface
        case 0x252728FF: // Main Facebook dark surface
        case 0x28292CFF: // Auxiliary raised surface
            return YES;
        default:
            return NO;
    }
}

static BOOL FBOLEDIsLightAnchor(uint32_t rgba) {
    switch (rgba) {
        case 0xFFFFFFFF:
        case 0xC9CCD1FF:
        case 0xF8F9FBFF:
            return YES;
        default:
            return NO;
    }
}

static BOOL FBOLEDIsBlack(uint32_t rgba) {
    return rgba == 0x000000FF;
}

static BOOL FBOLEDIsThemeAnchor(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return [name isEqualToString:@"FBTopBarAndContentView"] ||
           [name isEqualToString:@"FBTabBarAndContentView"] ||
           [name isEqualToString:@"FBMovableNavigationBarView"] ||
           [name isEqualToString:@"FBNewsFeedView"] ||
           [name isEqualToString:@"FBNewsFeedCollectionView"] ||
           [name isEqualToString:@"FBTabBar"];
}

static UIColor *FBOLEDSourceViewColor(UIView *view) {
    UIColor *current = view.backgroundColor;
    UIColor *original = objc_getAssociatedObject(view, kFBOLEDOriginalViewColorKey);
    if (!original) return current;

    uint32_t currentRGBA = FBOLEDRGBA(current, view.traitCollection);
    if (FBOLEDIsBlack(currentRGBA)) return original;

    // Facebook reassigned the view while it was on screen. The new value wins.
    objc_setAssociatedObject(view, kFBOLEDOriginalViewColorKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return current;
}

static void FBOLEDCountThemeAnchors(UIView *view, NSUInteger *dark, NSUInteger *light) {
    if (view.hidden || view.alpha < 0.01) return;

    if (FBOLEDIsThemeAnchor(view)) {
        uint32_t rgba = FBOLEDRGBA(FBOLEDSourceViewColor(view), view.traitCollection);
        if (FBOLEDIsMappedDark(rgba)) (*dark)++;
        if (FBOLEDIsLightAnchor(rgba)) (*light)++;
    }

    for (UIView *child in view.subviews) {
        FBOLEDCountThemeAnchors(child, dark, light);
    }
}

static NSArray<UIWindow *> *FBOLEDWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIApplication *application = UIApplication.sharedApplication;

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateUnattached) continue;
        [windows addObjectsFromArray:windowScene.windows];
    }
    return windows;
}

static void FBOLEDResolveMode(NSArray<UIWindow *> *windows) {
    NSUInteger dark = 0;
    NSUInteger light = 0;
    for (UIWindow *window in windows) {
        FBOLEDCountThemeAnchors(window, &dark, &light);
    }

    if (dark > light) {
        gFBOLEDDarkMode = YES;
        gFBOLEDModeKnown = YES;
    } else if (light > dark) {
        gFBOLEDDarkMode = NO;
        gFBOLEDModeKnown = YES;
    } else if (!gFBOLEDModeKnown) {
        for (UIWindow *window in windows) {
            if (window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                gFBOLEDDarkMode = YES;
                gFBOLEDModeKnown = YES;
                break;
            }
        }
    }
}

static void FBOLEDTransformView(UIView *view) {
    if (view.hidden || view.alpha < 0.01) return;

    UIColor *original = objc_getAssociatedObject(view, kFBOLEDOriginalViewColorKey);

    if (gFBOLEDDarkMode) {
        UIColor *source = FBOLEDSourceViewColor(view);
        original = objc_getAssociatedObject(view, kFBOLEDOriginalViewColorKey);
        if (FBOLEDIsMappedDark(FBOLEDRGBA(source, view.traitCollection))) {
            if (!original) {
                objc_setAssociatedObject(view, kFBOLEDOriginalViewColorKey, source,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (!FBOLEDIsBlack(FBOLEDRGBA(view.backgroundColor, view.traitCollection))) {
                view.backgroundColor = UIColor.blackColor;
            }
        }
    } else if (original) {
        view.backgroundColor = original;
        objc_setAssociatedObject(view, kFBOLEDOriginalViewColorKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Some custom Facebook views paint directly into CALayer without a UIColor.
    // Handle only layer-only backgrounds so the normal UIView path is never doubled.
    if (!view.backgroundColor && view.layer.backgroundColor) {
        UIColor *layerCurrent = [UIColor colorWithCGColor:view.layer.backgroundColor];
        UIColor *layerOriginal = objc_getAssociatedObject(view.layer,
                                                           kFBOLEDOriginalLayerColorKey);
        if (gFBOLEDDarkMode) {
            UIColor *source = layerOriginal ?: layerCurrent;
            if (FBOLEDIsMappedDark(FBOLEDRGBA(source, view.traitCollection))) {
                if (!layerOriginal) {
                    objc_setAssociatedObject(view.layer, kFBOLEDOriginalLayerColorKey, source,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                view.layer.backgroundColor = UIColor.blackColor.CGColor;
            }
        } else if (layerOriginal) {
            view.layer.backgroundColor = layerOriginal.CGColor;
            objc_setAssociatedObject(view.layer, kFBOLEDOriginalLayerColorKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    for (UIView *child in view.subviews) {
        FBOLEDTransformView(child);
    }
}

static void FBOLEDRunPass(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ FBOLEDRunPass(); });
        return;
    }

    @autoreleasepool {
        @try {
            NSArray<UIWindow *> *windows = FBOLEDWindows();
            FBOLEDResolveMode(windows);
            if (!gFBOLEDModeKnown) return;
            for (UIWindow *window in windows) FBOLEDTransformView(window);
        } @catch (__unused NSException *exception) {
            // A transient view-tree mutation must never take Facebook down.
        }
    }
}

static void FBOLEDStart(void) {
    FBOLEDRunPass();
    if (!gFBOLEDTimer) {
        gFBOLEDTimer = [NSTimer timerWithTimeInterval:0.75
                                              repeats:YES
                                                block:^(__unused NSTimer *timer) {
            FBOLEDRunPass();
        }];
        gFBOLEDTimer.tolerance = 0.15;
        [NSRunLoop.mainRunLoop addTimer:gFBOLEDTimer forMode:NSRunLoopCommonModes];
    }

    if (!gFBOLEDActiveObserver) {
        gFBOLEDActiveObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
            FBOLEDRunPass();
        }];
    }
}

__attribute__((constructor)) static void FBOLEDInit(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"]) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            FBOLEDStart();
        });
    }
}
