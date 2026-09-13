from pathlib import Path

p = Path("FBOLED.m")
s = p.read_text(encoding="utf-8")

s = s.replace("// FBOLED 0.2.2", "// FBOLED 0.2.4 TEST", 1)
s = s.replace(
    "// 0.2.2 fixes only the unmasked avatar variant discovered by diagnostics.",
    "// 0.2.4 keeps the validated 0.2.2 avatar fix, adds the diagnosed community/group composite variant, and applies that variant before the first visible frame.",
    1,
)

needle = '''static void FBOLEDUpdateAvatarClip(UIView *view) {
    BOOL changedByFBOLED = [objc_getAssociatedObject(view, kFBOLEDAvatarMaskKey) boolValue];
    BOOL target = gFBOLEDDarkMode && FBOLEDIsUnmaskedAvatarVariant(view);
'''

insert = r'''// Variant C (Facebook 578.1): composite community/group avatar.
// Diagnosed structure:
//   FDSTouchStateComponentView (~44x44)
//     -> FBPassthroughView (~36x36, cornerRadius ~8)
//        -> MRCImageComponentView -> MRCAnimatedImageView
//        -> direct UIImageView
// The small overlaid profile avatar uses _FBMaskedRoundedCornerView and is therefore
// intentionally excluded here, preserving the validated 0.2.2 A/B behavior.
static BOOL FBOLEDIsCompositeCommunityAvatarVariant(UIView *view) {
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

    // Never touch Facebook's already-correct masked avatar implementation.
    if (FBOLEDHasDirectChildNamed(view, @"_FBMaskedRoundedCornerView")) return NO;

    // This third variant was observed specifically inside a 44x44 touch-state wrapper.
    UIView *parent = view.superview;
    if (!parent || ![NSStringFromClass(parent.class) isEqualToString:@"FDSTouchStateComponentView"]) return NO;
    CGFloat parentW = fabs(parent.bounds.size.width);
    CGFloat parentH = fabs(parent.bounds.size.height);
    if (parentW < 42.0 || parentW > 46.0 || parentH < 42.0 || parentH > 46.0) return NO;

    UIView *imageComponent = FBOLEDDirectChildNamed(view, @"MRCImageComponentView");
    UIImageView *directImage = nil;
    for (UIView *child in view.subviews) {
        if ([child isKindOfClass:UIImageView.class]) {
            directImage = (UIImageView *)child;
            break;
        }
    }
    if (!imageComponent || !directImage || !directImage.image) return NO;
    if (!FBOLEDHasDescendantNamed(imageComponent, @"MRCAnimatedImageView", 0)) return NO;

    CGFloat imageWidth = fabs(directImage.bounds.size.width);
    CGFloat imageHeight = fabs(directImage.bounds.size.height);
    if (fabs(imageWidth - width) > 2.0 || fabs(imageHeight - height) > 2.0) return NO;

    return YES;
}

// Immediate path for variant C. The scanner remains the fallback, but these two
// setters cover both construction orders: image first / hierarchy second, or
// hierarchy first / image second. This prevents the square frame from being shown.
static void FBOLEDApplyImmediateCompositeAvatarClip(UIView *candidate) {
    if (!candidate) return;
    if (![NSStringFromClass(candidate.class) isEqualToString:@"FBPassthroughView"]) return;

    BOOL darkNow = gFBOLEDModeKnown
        ? gFBOLEDDarkMode
        : (candidate.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    if (!darkNow) return;
    if (!FBOLEDIsCompositeCommunityAvatarVariant(candidate)) return;

    if (!candidate.layer.masksToBounds) {
        candidate.layer.masksToBounds = YES;
        objc_setAssociatedObject(candidate, kFBOLEDAvatarMaskKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

@interface UIView (FBOLEDImmediateAvatar)
- (void)fboled_avatar_addSubview:(UIView *)view;
@end

@implementation UIView (FBOLEDImmediateAvatar)
- (void)fboled_avatar_addSubview:(UIView *)view {
    [self fboled_avatar_addSubview:view];
    FBOLEDApplyImmediateCompositeAvatarClip(self);
    FBOLEDApplyImmediateCompositeAvatarClip(view);
}
@end

@interface UIImageView (FBOLEDImmediateAvatar)
- (void)fboled_avatar_setImage:(UIImage *)image;
@end

@implementation UIImageView (FBOLEDImmediateAvatar)
- (void)fboled_avatar_setImage:(UIImage *)image {
    [self fboled_avatar_setImage:image];

    UIView *node = self;
    for (NSUInteger depth = 0; node && depth < 6; depth++, node = node.superview) {
        FBOLEDApplyImmediateCompositeAvatarClip(node);
    }
}
@end

static void FBOLEDInstallImmediateAvatarHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method addSubviewOriginal = class_getInstanceMethod(UIView.class, @selector(addSubview:));
        Method addSubviewReplacement = class_getInstanceMethod(UIView.class, @selector(fboled_avatar_addSubview:));
        if (addSubviewOriginal && addSubviewReplacement) {
            method_exchangeImplementations(addSubviewOriginal, addSubviewReplacement);
        }

        Method setImageOriginal = class_getInstanceMethod(UIImageView.class, @selector(setImage:));
        Method setImageReplacement = class_getInstanceMethod(UIImageView.class, @selector(fboled_avatar_setImage:));
        if (setImageOriginal && setImageReplacement) {
            method_exchangeImplementations(setImageOriginal, setImageReplacement);
        }
    });
}

static void FBOLEDUpdateAvatarClip(UIView *view) {
    BOOL changedByFBOLED = [objc_getAssociatedObject(view, kFBOLEDAvatarMaskKey) boolValue];
    BOOL target = gFBOLEDDarkMode &&
                  (FBOLEDIsUnmaskedAvatarVariant(view) ||
                   FBOLEDIsCompositeCommunityAvatarVariant(view));
'''

if needle not in s:
    raise SystemExit("Expected FBOLEDUpdateAvatarClip block not found")
s = s.replace(needle, insert, 1)

constructor_needle = '''        FBOLEDInstallInstantSetter();
        dispatch_async(dispatch_get_main_queue(), ^{
'''
constructor_replacement = '''        FBOLEDInstallInstantSetter();
        FBOLEDInstallImmediateAvatarHooks();
        dispatch_async(dispatch_get_main_queue(), ^{
'''
if constructor_needle not in s:
    raise SystemExit("Expected constructor install point not found")
s = s.replace(constructor_needle, constructor_replacement, 1)

required = [
    "FBOLED 0.2.4 TEST",
    "FBOLEDIsCompositeCommunityAvatarVariant",
    "FBOLEDApplyImmediateCompositeAvatarClip",
    "FBOLEDInstallImmediateAvatarHooks",
    "fboled_avatar_addSubview:",
    "fboled_avatar_setImage:",
    'FDSTouchStateComponentView',
    '_FBMaskedRoundedCornerView',
    'MRCImageComponentView',
    'MRCAnimatedImageView',
    'FBOLEDIsUnmaskedAvatarVariant(view) ||',
]
for marker in required:
    if marker not in s:
        raise SystemExit(f"Missing marker after patch: {marker}")

p.write_text(s, encoding="utf-8")
print("Prepared FBOLED 0.2.4 no-flash test from validated 0.2.2 source")
