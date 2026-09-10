from pathlib import Path

path = Path("Tweak.m")
text = path.read_text(encoding="utf-8")


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly 1 match, found {count}")
    text = text.replace(old, new, 1)


replace_once(
    "// iQFaceOLED 0.1.1",
    "// iQFaceOLED 0.1.5",
    "version",
)

replace_once(
    "static const void *kIQFOLEDOriginalLayerColorKey = &kIQFOLEDOriginalLayerColorKey;\nstatic const void *kIQFOLEDRowInstalledKey = &kIQFOLEDRowInstalledKey;",
    "static const void *kIQFOLEDOriginalLayerColorKey = &kIQFOLEDOriginalLayerColorKey;\nstatic const void *kIQFOLEDAvatarMaskKey = &kIQFOLEDAvatarMaskKey;\nstatic const void *kIQFOLEDRowInstalledKey = &kIQFOLEDRowInstalledKey;",
    "avatar associated key",
)

avatar_fix = r'''// Avatar fix integrated from validated FBOLED 0.2.2 --------------------------
// Diagnostics showed two Facebook avatar implementations:
//   A) FBPassthroughView -> _FBMaskedRoundedCornerView -> MRC... (already correct)
//   B) FBPassthroughView -> MRCImageComponentView + UIImageView (unmasked variant)
// Only B is clipped. A is intentionally left untouched.

static BOOL IQFOLEDHasDirectChildNamed(UIView *view, NSString *className) {
    if (!view || !className.length) return NO;
    for (UIView *child in view.subviews) {
        if ([NSStringFromClass(child.class) isEqualToString:className]) return YES;
    }
    return NO;
}

static UIView *IQFOLEDDirectChildNamed(UIView *view, NSString *className) {
    if (!view || !className.length) return nil;
    for (UIView *child in view.subviews) {
        if ([NSStringFromClass(child.class) isEqualToString:className]) return child;
    }
    return nil;
}

static BOOL IQFOLEDHasDescendantNamed(UIView *view, NSString *className, NSUInteger depth) {
    if (!view || !className.length || depth > 5) return NO;
    for (UIView *child in view.subviews) {
        if ([NSStringFromClass(child.class) isEqualToString:className]) return YES;
        if (IQFOLEDHasDescendantNamed(child, className, depth + 1)) return YES;
    }
    return NO;
}

static BOOL IQFOLEDIsUnmaskedAvatarVariant(UIView *view) {
    if (!view) return NO;
    if (![NSStringFromClass(view.class) isEqualToString:@"FBPassthroughView"]) return NO;

    CGRect bounds = view.bounds;
    CGFloat width = fabs(bounds.size.width);
    CGFloat height = fabs(bounds.size.height);
    if (!isfinite(width) || !isfinite(height)) return NO;
    if (width < 24.0 || height < 24.0 || width > 64.0 || height > 64.0) return NO;
    if (fabs(width - height) > 2.0) return NO;

    CGFloat minimum = MIN(width, height);
    CGFloat radius = view.layer.cornerRadius;
    if (radius < minimum * 0.45 || radius > minimum * 0.55) return NO;

    // Variant A already owns its correct circular masking view. Never touch it.
    if (IQFOLEDHasDirectChildNamed(view, @"_FBMaskedRoundedCornerView")) return NO;

    // Variant B seen in the mapper has these direct children.
    UIView *imageComponent = IQFOLEDDirectChildNamed(view, @"MRCImageComponentView");
    UIImageView *directImage = nil;
    for (UIView *child in view.subviews) {
        if ([child isKindOfClass:UIImageView.class]) {
            directImage = (UIImageView *)child;
            break;
        }
    }
    if (!imageComponent || !directImage || !directImage.image) return NO;

    if (!IQFOLEDHasDescendantNamed(imageComponent, @"MRCAnimatedImageView", 0)) return NO;

    CGFloat imageWidth = fabs(directImage.bounds.size.width);
    CGFloat imageHeight = fabs(directImage.bounds.size.height);
    if (fabs(imageWidth - width) > 2.0 || fabs(imageHeight - height) > 2.0) return NO;

    return YES;
}

static void IQFOLEDUpdateAvatarClip(UIView *view) {
    BOOL changedByIQFOLED = [objc_getAssociatedObject(view, kIQFOLEDAvatarMaskKey) boolValue];
    BOOL target = gIQFOLEDEnabled && gIQFOLEDDarkMode && IQFOLEDIsUnmaskedAvatarVariant(view);

    if (target) {
        if (!view.layer.masksToBounds) {
            view.layer.masksToBounds = YES;
            objc_setAssociatedObject(view,
                                     kIQFOLEDAvatarMaskKey,
                                     @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    // Facebook reuses cells. Restore only a value changed by iQFaceOLED itself.
    if (changedByIQFOLED) {
        view.layer.masksToBounds = NO;
        objc_setAssociatedObject(view,
                                 kIQFOLEDAvatarMaskKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

'''

replace_once(
    "static void IQFOLEDTransformView(UIView *view) {",
    avatar_fix + "static void IQFOLEDTransformView(UIView *view) {",
    "avatar fix insertion",
)

replace_once(
    "static void IQFOLEDTransformView(UIView *view) {\n    if (view.hidden || view.alpha < 0.01) return;\n\n    UIColor *original = objc_getAssociatedObject(view, kIQFOLEDOriginalViewColorKey);",
    "static void IQFOLEDTransformView(UIView *view) {\n    if (view.hidden || view.alpha < 0.01) return;\n\n    IQFOLEDUpdateAvatarClip(view);\n\n    UIColor *original = objc_getAssociatedObject(view, kIQFOLEDOriginalViewColorKey);",
    "avatar fix call",
)

replace_once(
    "static NSString *IQFOLEDStatusText(void) {",
    "__attribute__((unused)) static NSString *IQFOLEDStatusText(void) {",
    "legacy status text",
)

replace_once(
    "static void IQFOLEDPresentControlMenu(UIViewController *controller) {",
    "__attribute__((unused)) static void IQFOLEDPresentControlMenu(UIViewController *controller) {",
    "legacy alert",
)

old_create_row = '''static id IQFOLEDCreateNativeRow(UIViewController *controller) {
    SEL selector = NSSelectorFromString(@"valueRowWithTitle:icon:detail:tap:");
    if (controller == nil || ![controller respondsToSelector:selector]) return nil;

    __weak UIViewController *weakController = controller;
    void (^tapBlock)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = weakController;
            if (presenter == nil) return;
            IQFOLEDPresentControlMenu(presenter);
        });
    };

    typedef id (*IQFOLEDNativeRowBuilder)(id, SEL, id, id, id, id);
    IQFOLEDNativeRowBuilder builder = (IQFOLEDNativeRowBuilder)(void *)objc_msgSend;
    return builder(controller,
                   selector,
                   @"Modo OLED",
                   @"circle.lefthalf.filled",
                   IQFOLEDStatusText(),
                   [tapBlock copy]);
}
'''

new_create_row = '''static id IQFOLEDCreateNativeRow(UIViewController *controller) {
    SEL selector = NSSelectorFromString(@"rowWithTitle:icon:key:def:onChange:");
    if (controller == nil || ![controller respondsToSelector:selector]) return nil;

    // The native iQFace row owns the UISwitch and preference key.
    void (^onChange)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            IQFOLEDSetEnabled(!gIQFOLEDEnabled, nil);
        });
    };

    typedef id (*IQFOLEDNativeToggleBuilder)(id, SEL, id, id, id, BOOL, id);
    IQFOLEDNativeToggleBuilder builder = (IQFOLEDNativeToggleBuilder)(void *)objc_msgSend;
    return builder(controller,
                   selector,
                   @"Modo OLED",
                   @"circle.lefthalf.filled",
                   IQFOLEDPreferenceKey,
                   gIQFOLEDEnabled,
                   [onChange copy]);
}
'''

replace_once(old_create_row, new_create_row, "native toggle row")

replace_once(
    '''        IQFOLEDRefreshSettingsRow(controller);
        return;
    }

    id toolsSection = IQFOLEDFindToolsSection(sections);''',
    '''        return;
    }

    id toolsSection = IQFOLEDFindToolsSection(sections);''',
    "existing row path",
)

path.write_text(text, encoding="utf-8")
print("Prepared iQFaceOLED 0.1.5 with native iQFace toggle and validated avatar fix")
