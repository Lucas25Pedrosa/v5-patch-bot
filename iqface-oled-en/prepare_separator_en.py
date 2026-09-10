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
    "// iQFaceOLED 0.1.6 EN",
    "// iQFaceOLED 0.2.0 EN",
    "version",
)

replace_once(
    'static NSString *const IQFOLEDPreferenceKey = @"iQFaceOLEDEnabled";',
    'static NSString *const IQFOLEDPreferenceKey = @"iQFaceOLEDEnabled";\n'
    'static NSString *const IQFOLEDSeparatorsPreferenceKey = @"iQFaceOLEDFeedSeparatorsEnabled";',
    "separator preference key",
)

replace_once(
    "static const void *kIQFOLEDAvatarMaskKey = &kIQFOLEDAvatarMaskKey;\n"
    "static const void *kIQFOLEDRowInstalledKey = &kIQFOLEDRowInstalledKey;",
    "static const void *kIQFOLEDAvatarMaskKey = &kIQFOLEDAvatarMaskKey;\n"
    "static const void *kIQFOLEDSeparatorManagedKey = &kIQFOLEDSeparatorManagedKey;\n"
    "static const void *kIQFOLEDRowInstalledKey = &kIQFOLEDRowInstalledKey;",
    "separator associated key",
)

replace_once(
    "static BOOL gIQFOLEDEnabled = YES;",
    "static BOOL gIQFOLEDEnabled = YES;\nstatic BOOL gIQFOLEDSeparatorsEnabled = NO;",
    "separator state",
)

preference_helpers = r'''
static BOOL IQFOLEDLoadSeparatorsPreference(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:IQFOLEDSeparatorsPreferenceKey] == nil) return NO;
    return [defaults boolForKey:IQFOLEDSeparatorsPreferenceKey];
}

static void IQFOLEDSaveSeparatorsPreference(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:IQFOLEDSeparatorsPreferenceKey];
}
'''

replace_once(
    '''static void IQFOLEDSaveEnabledPreference(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:IQFOLEDPreferenceKey];
}
''',
    '''static void IQFOLEDSaveEnabledPreference(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:IQFOLEDPreferenceKey];
}
''' + preference_helpers,
    "separator preference helpers",
)

separator_fix = r'''// Optional feed separator ----------------------------------------------------
// FBOLED_ViewMap.csv measured the post divider as:
// FBLineComponentInternalView, 393 x 2 pt, source color #101011FF.
// No new hook is used here. The existing OLED pass recolors only that signature.

static BOOL IQFOLEDIsFeedSeparator(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.01) return NO;
    if (![NSStringFromClass(view.class) isEqualToString:@"FBLineComponentInternalView"]) return NO;

    CGRect bounds = view.bounds;
    CGFloat width = fabs(bounds.size.width);
    CGFloat height = fabs(bounds.size.height);
    if (!isfinite(width) || !isfinite(height)) return NO;

    CGFloat screenWidth = fabs(UIScreen.mainScreen.bounds.size.width);
    CGFloat minimumWidth = MAX(240.0, screenWidth * 0.85);
    if (width < minimumWidth) return NO;
    if (height < 0.5 || height > 3.0) return NO;

    UIColor *savedSource = objc_getAssociatedObject(view, kIQFOLEDOriginalViewColorKey);
    UIColor *source = savedSource ?: view.backgroundColor;
    uint32_t rgba = IQFOLEDRGBA(source, view.traitCollection);

    return rgba == 0x101011FF ||
           [objc_getAssociatedObject(view, kIQFOLEDSeparatorManagedKey) boolValue];
}

static UIColor *IQFOLEDFeedSeparatorColor(void) {
    return UIColor.whiteColor;
}

static BOOL IQFOLEDUpdateFeedSeparator(UIView *view) {
    BOOL managed = [objc_getAssociatedObject(view, kIQFOLEDSeparatorManagedKey) boolValue];
    BOOL target = IQFOLEDIsFeedSeparator(view);
    BOOL shouldShow = gIQFOLEDEnabled && gIQFOLEDDarkMode &&
                      gIQFOLEDSeparatorsEnabled && target;

    if (shouldShow) {
        UIColor *source = objc_getAssociatedObject(view, kIQFOLEDOriginalViewColorKey);
        if (!source && view.backgroundColor) {
            source = view.backgroundColor;
            if (IQFOLEDRGBA(source, view.traitCollection) == 0x101011FF) {
                objc_setAssociatedObject(view,
                                         kIQFOLEDOriginalViewColorKey,
                                         source,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }

        if (view.backgroundColor) {
            [view iqfoled_setBackgroundColor:IQFOLEDFeedSeparatorColor()];
        } else if (view.layer.backgroundColor) {
            view.layer.backgroundColor = IQFOLEDFeedSeparatorColor().CGColor;
        }

        objc_setAssociatedObject(view,
                                 kIQFOLEDSeparatorManagedKey,
                                 @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    }

    if (managed) {
        UIColor *source = objc_getAssociatedObject(view, kIQFOLEDOriginalViewColorKey);

        if (view.backgroundColor) {
            if (gIQFOLEDEnabled && gIQFOLEDDarkMode) {
                [view iqfoled_setBackgroundColor:UIColor.blackColor];
            } else if (source) {
                [view iqfoled_setBackgroundColor:source];
            }
        } else if (view.layer.backgroundColor) {
            UIColor *layerOriginal = objc_getAssociatedObject(view.layer,
                                                               kIQFOLEDOriginalLayerColorKey);
            if (gIQFOLEDEnabled && gIQFOLEDDarkMode) {
                view.layer.backgroundColor = UIColor.blackColor.CGColor;
            } else if (layerOriginal) {
                view.layer.backgroundColor = layerOriginal.CGColor;
            }
        }

        objc_setAssociatedObject(view,
                                 kIQFOLEDSeparatorManagedKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    return NO;
}

'''

replace_once(
    "static void IQFOLEDTransformView(UIView *view) {",
    separator_fix + "static void IQFOLEDTransformView(UIView *view) {",
    "separator implementation",
)

replace_once(
    '''static void IQFOLEDTransformView(UIView *view) {
    if (view.hidden || view.alpha < 0.01) return;

    IQFOLEDUpdateAvatarClip(view);

    UIColor *original = objc_getAssociatedObject(view, kIQFOLEDOriginalViewColorKey);

    if (gIQFOLEDEnabled && gIQFOLEDDarkMode) {''',
    '''static void IQFOLEDTransformView(UIView *view) {
    if (view.hidden || view.alpha < 0.01) return;

    IQFOLEDUpdateAvatarClip(view);
    BOOL separatorHandled = IQFOLEDUpdateFeedSeparator(view);

    UIColor *original = objc_getAssociatedObject(view, kIQFOLEDOriginalViewColorKey);

    if (!separatorHandled && gIQFOLEDEnabled && gIQFOLEDDarkMode) {''',
    "separator pass integration",
)

replace_once(
    '''    } else if (original) {
        view.backgroundColor = original;
        objc_setAssociatedObject(view,
                                 kIQFOLEDOriginalViewColorKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!view.backgroundColor && view.layer.backgroundColor) {''',
    '''    } else if (!separatorHandled && original) {
        view.backgroundColor = original;
        objc_setAssociatedObject(view,
                                 kIQFOLEDOriginalViewColorKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!separatorHandled && !view.backgroundColor && view.layer.backgroundColor) {''',
    "separator color guard",
)

separator_row = r'''
static id IQFOLEDCreateSeparatorRow(UIViewController *controller) {
    SEL selector = NSSelectorFromString(@"rowWithTitle:icon:key:def:onChange:");
    if (controller == nil || ![controller respondsToSelector:selector]) return nil;

    void (^onChange)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            gIQFOLEDSeparatorsEnabled = !gIQFOLEDSeparatorsEnabled;
            IQFOLEDSaveSeparatorsPreference(gIQFOLEDSeparatorsEnabled);

            UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
            [feedback selectionChanged];

            IQFOLEDRunPass();
        });
    };

    typedef id (*IQFOLEDNativeToggleBuilder)(id, SEL, id, id, id, BOOL, id);
    IQFOLEDNativeToggleBuilder builder = (IQFOLEDNativeToggleBuilder)(void *)objc_msgSend;
    return builder(controller,
                   selector,
                   @"Feed separators",
                   @"line.3.horizontal",
                   IQFOLEDSeparatorsPreferenceKey,
                   gIQFOLEDSeparatorsEnabled,
                   [onChange copy]);
}
'''

replace_once(
    "static void IQFOLEDInstallSettingsRow(UIViewController *controller) {",
    separator_row + "\nstatic void IQFOLEDInstallSettingsRow(UIViewController *controller) {",
    "separator native row",
)

replace_once(
    '''    id nativeRow = IQFOLEDCreateNativeRow(controller);
    Class rowClass = NSClassFromString(@"IQFRow");
    if (nativeRow == nil || rowClass == Nil || ![nativeRow isKindOfClass:rowClass]) {
        NSLog(@"[iQFaceOLED] native IQFRow builder unavailable");
        return;
    }

    NSMutableArray *updatedRows = [rows mutableCopy];''',
    '''    id nativeRow = IQFOLEDCreateNativeRow(controller);
    id separatorRow = IQFOLEDCreateSeparatorRow(controller);
    Class rowClass = NSClassFromString(@"IQFRow");
    if (nativeRow == nil || rowClass == Nil || ![nativeRow isKindOfClass:rowClass]) {
        NSLog(@"[iQFaceOLED] native IQFRow builder unavailable");
        return;
    }

    BOOL separatorRowValid = separatorRow != nil && [separatorRow isKindOfClass:rowClass];

    NSMutableArray *updatedRows = [rows mutableCopy];''',
    "separator row creation",
)

replace_once(
    '''    [updatedRows insertObject:nativeRow atIndex:MIN(insertionIndex, updatedRows.count)];

    @try {''',
    '''    NSUInteger oledIndex = MIN(insertionIndex, updatedRows.count);
    [updatedRows insertObject:nativeRow atIndex:oledIndex];
    if (separatorRowValid) {
        [updatedRows insertObject:separatorRow atIndex:MIN(oledIndex + 1, updatedRows.count)];
    }

    @try {''',
    "separator row placement",
)

replace_once(
    "        gIQFOLEDEnabled = IQFOLEDLoadEnabledPreference();\n        IQFOLEDInstallInstantSetter();",
    "        gIQFOLEDEnabled = IQFOLEDLoadEnabledPreference();\n"
    "        gIQFOLEDSeparatorsEnabled = IQFOLEDLoadSeparatorsPreference();\n"
    "        IQFOLEDInstallInstantSetter();",
    "separator startup preference",
)

path.write_text(text, encoding="utf-8")
print("Prepared iQFaceOLED 0.2.0 English with white feed separators")
