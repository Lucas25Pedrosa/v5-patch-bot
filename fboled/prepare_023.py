from pathlib import Path

p = Path("FBOLED.m")
s = p.read_text(encoding="utf-8")

s = s.replace("// FBOLED 0.2.2", "// FBOLED 0.2.3 TEST", 1)
s = s.replace(
    "// 0.2.2 fixes only the unmasked avatar variant discovered by diagnostics.",
    "// 0.2.3 keeps the validated 0.2.2 avatar fix and adds the diagnosed community/group composite variant.",
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

static void FBOLEDUpdateAvatarClip(UIView *view) {
    BOOL changedByFBOLED = [objc_getAssociatedObject(view, kFBOLEDAvatarMaskKey) boolValue];
    BOOL target = gFBOLEDDarkMode &&
                  (FBOLEDIsUnmaskedAvatarVariant(view) ||
                   FBOLEDIsCompositeCommunityAvatarVariant(view));
'''

if needle not in s:
    raise SystemExit("Expected FBOLEDUpdateAvatarClip block not found")
s = s.replace(needle, insert, 1)

required = [
    "FBOLED 0.2.3 TEST",
    "FBOLEDIsCompositeCommunityAvatarVariant",
    'FDSTouchStateComponentView',
    'cornerRadius',
    '_FBMaskedRoundedCornerView',
    'MRCImageComponentView',
    'MRCAnimatedImageView',
    'FBOLEDIsUnmaskedAvatarVariant(view) ||',
]
for marker in required:
    if marker not in s:
        raise SystemExit(f"Missing marker after patch: {marker}")

p.write_text(s, encoding="utf-8")
print("Prepared FBOLED 0.2.3 test from validated 0.2.2 source")
