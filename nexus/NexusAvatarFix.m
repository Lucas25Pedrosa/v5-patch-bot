#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>

// Nexus 1.0.2 avatar fix, carried over from the validated FBOLED 0.2.4 test.
// It targets only the composite community/group avatar variant diagnosed on
// Facebook 578.1 and leaves the existing 0.2.2 A/B logic in OLEDTweak.m intact.

static const void *kNexusAvatarMaskKey = &kNexusAvatarMaskKey;
static NSTimer *gNexusAvatarTimer;

static BOOL NexusAvatarOLEDEnabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:@"iQFaceOLEDEnabled"] == nil) return YES;
    return [defaults boolForKey:@"iQFaceOLEDEnabled"];
}

static BOOL NexusAvatarDarkMode(UIView *view) {
    return view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
}

static BOOL NexusAvatarHasDirectChildNamed(UIView *view, NSString *className) {
    for (UIView *child in view.subviews) {
        if ([NSStringFromClass(child.class) isEqualToString:className]) return YES;
    }
    return NO;
}

static UIView *NexusAvatarDirectChildNamed(UIView *view, NSString *className) {
    for (UIView *child in view.subviews) {
        if ([NSStringFromClass(child.class) isEqualToString:className]) return child;
    }
    return nil;
}

static BOOL NexusAvatarHasDescendantNamed(UIView *view, NSString *className, NSUInteger depth) {
    if (!view || depth > 5) return NO;
    for (UIView *child in view.subviews) {
        if ([NSStringFromClass(child.class) isEqualToString:className]) return YES;
        if (NexusAvatarHasDescendantNamed(child, className, depth + 1)) return YES;
    }
    return NO;
}

static BOOL NexusIsCompositeCommunityAvatar(UIView *view) {
    if (!view || ![NSStringFromClass(view.class) isEqualToString:@"FBPassthroughView"]) return NO;

    CGFloat width = fabs(view.bounds.size.width);
    CGFloat height = fabs(view.bounds.size.height);
    if (!isfinite(width) || !isfinite(height)) return NO;
    if (width < 34.0 || width > 38.0 || height < 34.0 || height > 38.0) return NO;
    if (fabs(width - height) > 1.5) return NO;

    CGFloat radius = view.layer.cornerRadius;
    if (radius < 6.0 || radius > 10.0) return NO;

    // The small overlaid profile avatar owns this mask and must stay untouched.
    if (NexusAvatarHasDirectChildNamed(view, @"_FBMaskedRoundedCornerView")) return NO;

    UIView *parent = view.superview;
    if (!parent || ![NSStringFromClass(parent.class) isEqualToString:@"FDSTouchStateComponentView"]) return NO;
    CGFloat parentW = fabs(parent.bounds.size.width);
    CGFloat parentH = fabs(parent.bounds.size.height);
    if (parentW < 42.0 || parentW > 46.0 || parentH < 42.0 || parentH > 46.0) return NO;

    UIView *imageComponent = NexusAvatarDirectChildNamed(view, @"MRCImageComponentView");
    UIImageView *directImage = nil;
    for (UIView *child in view.subviews) {
        if ([child isKindOfClass:UIImageView.class]) {
            directImage = (UIImageView *)child;
            break;
        }
    }
    if (!imageComponent || !directImage || !directImage.image) return NO;
    if (!NexusAvatarHasDescendantNamed(imageComponent, @"MRCAnimatedImageView", 0)) return NO;

    CGFloat imageW = fabs(directImage.bounds.size.width);
    CGFloat imageH = fabs(directImage.bounds.size.height);
    if (fabs(imageW - width) > 2.0 || fabs(imageH - height) > 2.0) return NO;
    return YES;
}

static void NexusApplyCommunityAvatarFix(UIView *view) {
    if (!view || !NexusAvatarOLEDEnabled() || !NexusAvatarDarkMode(view)) return;
    if (!NexusIsCompositeCommunityAvatar(view)) return;

    if (!view.layer.masksToBounds) {
        view.layer.masksToBounds = YES;
        objc_setAssociatedObject(view, kNexusAvatarMaskKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void NexusRestoreIfReused(UIView *view) {
    if (![objc_getAssociatedObject(view, kNexusAvatarMaskKey) boolValue]) return;
    if (NexusAvatarOLEDEnabled() && NexusAvatarDarkMode(view) && NexusIsCompositeCommunityAvatar(view)) return;

    view.layer.masksToBounds = NO;
    objc_setAssociatedObject(view, kNexusAvatarMaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@interface UIView (NexusAvatarImmediate)
- (void)nexus_avatar_addSubview:(UIView *)view;
@end

@implementation UIView (NexusAvatarImmediate)
- (void)nexus_avatar_addSubview:(UIView *)view {
    [self nexus_avatar_addSubview:view];
    NexusApplyCommunityAvatarFix(self);
    NexusApplyCommunityAvatarFix(view);
}
@end

@interface UIImageView (NexusAvatarImmediate)
- (void)nexus_avatar_setImage:(UIImage *)image;
@end

@implementation UIImageView (NexusAvatarImmediate)
- (void)nexus_avatar_setImage:(UIImage *)image {
    [self nexus_avatar_setImage:image];
    UIView *node = self;
    for (NSUInteger depth = 0; node && depth < 6; depth++, node = node.superview) {
        NexusApplyCommunityAvatarFix(node);
    }
}
@end

static void NexusAvatarInstallImmediateHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method addSubviewOriginal = class_getInstanceMethod(UIView.class, @selector(addSubview:));
        Method addSubviewReplacement = class_getInstanceMethod(UIView.class, @selector(nexus_avatar_addSubview:));
        if (addSubviewOriginal && addSubviewReplacement) {
            method_exchangeImplementations(addSubviewOriginal, addSubviewReplacement);
        }

        Method setImageOriginal = class_getInstanceMethod(UIImageView.class, @selector(setImage:));
        Method setImageReplacement = class_getInstanceMethod(UIImageView.class, @selector(nexus_avatar_setImage:));
        if (setImageOriginal && setImageReplacement) {
            method_exchangeImplementations(setImageOriginal, setImageReplacement);
        }
    });
}

static void NexusAvatarScanView(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.01) return;
    NexusRestoreIfReused(view);
    NexusApplyCommunityAvatarFix(view);
    for (UIView *child in view.subviews) NexusAvatarScanView(child);
}

static void NexusAvatarRunPass(void) {
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) NexusAvatarScanView(window);
    }
}

__attribute__((constructor))
static void NexusAvatarFixInitialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.Facebook"] ||
            [NSBundle.mainBundle.bundlePath hasSuffix:@".appex"]) return;

        NexusAvatarInstallImmediateHooks();
        dispatch_async(dispatch_get_main_queue(), ^{
            NexusAvatarRunPass();
            gNexusAvatarTimer = [NSTimer timerWithTimeInterval:0.75 repeats:YES block:^(__unused NSTimer *timer) {
                NexusAvatarRunPass();
            }];
            gNexusAvatarTimer.tolerance = 0.15;
            [NSRunLoop.mainRunLoop addTimer:gNexusAvatarTimer forMode:NSRunLoopCommonModes];
        });
    }
}
