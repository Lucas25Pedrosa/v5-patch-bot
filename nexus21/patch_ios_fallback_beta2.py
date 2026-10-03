from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

key_anchor = 'static NSString *const IQFOLEDSeparatorsPreferenceKey = @"iQFaceOLEDFeedSeparatorsEnabled";'
if key_anchor not in s:
    raise SystemExit("separator preference key anchor not found")
s = s.replace(
    key_anchor,
    key_anchor + '\nstatic NSString *const IQFOLEDIOSFallbackPreferenceKey = @"NexusOLEDUseIOSFallback";',
    1,
)

resolve_old = '''static void IQFOLEDResolveMode(NSArray<UIWindow *> *windows) {
    NSUInteger dark = 0;
    NSUInteger light = 0;

    for (UIWindow *window in windows) {
        IQFOLEDCountThemeAnchors(window, &dark, &light);
    }

    if (dark > light) {
        gIQFOLEDDarkMode = YES;
        gIQFOLEDModeKnown = YES;
    } else if (light > dark) {
        gIQFOLEDDarkMode = NO;
        gIQFOLEDModeKnown = YES;
    } else if (!gIQFOLEDModeKnown) {
        for (UIWindow *window in windows) {
            if (window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                gIQFOLEDDarkMode = YES;
                gIQFOLEDModeKnown = YES;
                break;
            }
        }
    }
}'''

resolve_new = '''static BOOL IQFOLEDLoadIOSFallbackPreference(void) {
    Class prefs = NSClassFromString(@"IQFPrefs");
    SEL selector = NSSelectorFromString(@"boolForKey:defaultValue:");
    if (prefs != Nil && [prefs respondsToSelector:selector]) {
        typedef BOOL (*Getter)(id, SEL, id, BOOL);
        return ((Getter)(void *)objc_msgSend)(prefs, selector, IQFOLEDIOSFallbackPreferenceKey, NO);
    }

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:IQFOLEDIOSFallbackPreferenceKey] == nil) return NO;
    return [defaults boolForKey:IQFOLEDIOSFallbackPreferenceKey];
}

static void IQFOLEDResolveMode(NSArray<UIWindow *> *windows) {
    NSUInteger dark = 0;
    NSUInteger light = 0;

    for (UIWindow *window in windows) {
        IQFOLEDCountThemeAnchors(window, &dark, &light);
    }

    if (dark > light) {
        gIQFOLEDDarkMode = YES;
        gIQFOLEDModeKnown = YES;
    } else if (light > dark) {
        gIQFOLEDDarkMode = NO;
        gIQFOLEDModeKnown = YES;
    } else if (!IQFOLEDLoadIOSFallbackPreference()) {
        // Facebook-only mode: no evidence means unknown, never inherit iOS.
        gIQFOLEDDarkMode = NO;
        gIQFOLEDModeKnown = NO;
    } else if (!gIQFOLEDModeKnown) {
        // Optional compatibility path: exact run #52 iOS fallback.
        for (UIWindow *window in windows) {
            if (window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                gIQFOLEDDarkMode = YES;
                gIQFOLEDModeKnown = YES;
                break;
            }
        }
    }
}'''

if s.count(resolve_old) != 1:
    raise SystemExit(f"run52 resolver expected exactly once, found {s.count(resolve_old)}")
s = s.replace(resolve_old, resolve_new, 1)

for marker in [
    'IQFOLEDIOSFallbackPreferenceKey = @"NexusOLEDUseIOSFallback"',
    'IQFOLEDLoadIOSFallbackPreference',
    'return ((Getter)(void *)objc_msgSend)(prefs, selector, IQFOLEDIOSFallbackPreferenceKey, NO);',
    'else if (!IQFOLEDLoadIOSFallbackPreference())',
    'window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark',
]:
    if marker not in s:
        raise SystemExit(f"missing Beta 2 marker: {marker}")

p.write_text(s, encoding="utf-8")
print("Patched Nexus 2.1 Beta 2 optional iOS fallback; default=OFF")
