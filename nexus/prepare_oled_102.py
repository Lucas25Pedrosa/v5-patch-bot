from pathlib import Path
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
s = src.read_text(encoding="utf-8")

old = '''        dispatch_async(dispatch_get_main_queue(), ^{
            IQFOLEDStartEngine();
            IQFOLEDTryInstallSettingsHook();
        });'''
assert old in s
s = s.replace(old, '''        dispatch_async(dispatch_get_main_queue(), ^{
            IQFOLEDStartEngine();
        });''', 1)

old_avatar = '''static void IQFOLEDUpdateAvatarClip(UIView *view) {
    BOOL changedByIQFOLED = [objc_getAssociatedObject(view, kIQFOLEDAvatarMaskKey) boolValue];
    BOOL target = gIQFOLEDEnabled && gIQFOLEDDarkMode && IQFOLEDIsUnmaskedAvatarVariant(view);
'''

new_avatar = r'''static BOOL IQFOLEDIsCompositeCommunityAvatarVariant(UIView *view) {
    if (!view) return NO;
    if (![NSStringFromClass(view.class) isEqualToString:@"FBPassthroughView"]) return NO;

    CGRect bounds = view.bounds;
    CGFloat width = fabs(bounds.size.width);
    CGFloat height = fabs(bounds.size.height);
    if (!isfinite(width) || !isfinite(height)) return NO;
    if (width < 34.0 || width > 38.0 || height < 34.0 || height > 38.0) return NO;
    if (fabs(width - height) > 1.5) return NO;

    CGFloat radius = view.layer.cornerRadius;
    if (radius < 6.0 || radius > 10.0) return NO;
    if (IQFOLEDHasDirectChildNamed(view, @"_FBMaskedRoundedCornerView")) return NO;

    UIView *parent = view.superview;
    if (!parent || ![NSStringFromClass(parent.class) isEqualToString:@"FDSTouchStateComponentView"]) return NO;
    CGFloat parentW = fabs(parent.bounds.size.width);
    CGFloat parentH = fabs(parent.bounds.size.height);
    if (parentW < 42.0 || parentW > 46.0 || parentH < 42.0 || parentH > 46.0) return NO;

    UIView *imageComponent = IQFOLEDDirectChildNamed(view, @"MRCImageComponentView");
    UIImageView *directImage = nil;
    for (UIView *child in view.subviews) {
        if ([child isKindOfClass:UIImageView.class]) { directImage = (UIImageView *)child; break; }
    }
    if (!imageComponent || !directImage || !directImage.image) return NO;
    if (!IQFOLEDHasDescendantNamed(imageComponent, @"MRCAnimatedImageView", 0)) return NO;

    CGFloat imageWidth = fabs(directImage.bounds.size.width);
    CGFloat imageHeight = fabs(directImage.bounds.size.height);
    if (fabs(imageWidth - width) > 2.0 || fabs(imageHeight - height) > 2.0) return NO;
    return YES;
}

static void IQFOLEDApplyImmediateCompositeAvatarClip(UIView *candidate) {
    if (!candidate || !gIQFOLEDEnabled) return;
    if (![NSStringFromClass(candidate.class) isEqualToString:@"FBPassthroughView"]) return;
    BOOL darkNow = gIQFOLEDModeKnown ? gIQFOLEDDarkMode : (candidate.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    if (!darkNow || !IQFOLEDIsCompositeCommunityAvatarVariant(candidate)) return;
    if (!candidate.layer.masksToBounds) {
        candidate.layer.masksToBounds = YES;
        objc_setAssociatedObject(candidate, kIQFOLEDAvatarMaskKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

@interface UIView (NexusOLEDImmediateAvatar)
- (void)nexus_oled_avatar_addSubview:(UIView *)view;
@end
@implementation UIView (NexusOLEDImmediateAvatar)
- (void)nexus_oled_avatar_addSubview:(UIView *)view {
    [self nexus_oled_avatar_addSubview:view];
    IQFOLEDApplyImmediateCompositeAvatarClip(self);
    IQFOLEDApplyImmediateCompositeAvatarClip(view);
}
@end

@interface UIImageView (NexusOLEDImmediateAvatar)
- (void)nexus_oled_avatar_setImage:(UIImage *)image;
@end
@implementation UIImageView (NexusOLEDImmediateAvatar)
- (void)nexus_oled_avatar_setImage:(UIImage *)image {
    [self nexus_oled_avatar_setImage:image];
    UIView *node = self;
    for (NSUInteger depth = 0; node && depth < 6; depth++, node = node.superview) {
        IQFOLEDApplyImmediateCompositeAvatarClip(node);
    }
}
@end

static void IQFOLEDInstallImmediateAvatarHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method a = class_getInstanceMethod(UIView.class, @selector(addSubview:));
        Method b = class_getInstanceMethod(UIView.class, @selector(nexus_oled_avatar_addSubview:));
        if (a && b) method_exchangeImplementations(a, b);
        Method c = class_getInstanceMethod(UIImageView.class, @selector(setImage:));
        Method d = class_getInstanceMethod(UIImageView.class, @selector(nexus_oled_avatar_setImage:));
        if (c && d) method_exchangeImplementations(c, d);
    });
}

static void IQFOLEDUpdateAvatarClip(UIView *view) {
    BOOL changedByIQFOLED = [objc_getAssociatedObject(view, kIQFOLEDAvatarMaskKey) boolValue];
    BOOL target = gIQFOLEDEnabled && gIQFOLEDDarkMode &&
                  (IQFOLEDIsUnmaskedAvatarVariant(view) || IQFOLEDIsCompositeCommunityAvatarVariant(view));
'''
if old_avatar not in s:
    raise SystemExit("avatar marker not found")
s = s.replace(old_avatar, new_avatar, 1)

install_old = '''        gIQFOLEDEnabled = IQFOLEDLoadEnabledPreference();
        IQFOLEDInstallInstantSetter();
'''
install_new = '''        gIQFOLEDEnabled = IQFOLEDLoadEnabledPreference();
        IQFOLEDInstallInstantSetter();
        IQFOLEDInstallImmediateAvatarHooks();
'''
if install_old not in s:
    raise SystemExit("constructor marker not found")
s = s.replace(install_old, install_new, 1)

s += '''\n\nid NexusOLEDCreateModeSetting(void) {\n    return IQFOLEDCreateNativeIconRow(@"Modo OLED", @"circle.lefthalf.filled");\n}\nid NexusOLEDCreateSeparatorSetting(void) {\n    return IQFOLEDCreateNativeIconRow(@"Separadores no feed", @"line.3.horizontal");\n}\nvoid NexusOLEDPrepareSettingsCell(void) {\n    IQFOLEDTryInstallAccessorySwitchHook();\n}\n'''

out.write_text(s, encoding="utf-8")
