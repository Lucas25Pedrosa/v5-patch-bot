from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

# Nexus 2 only supplies enable mode + replacement color.
# The detection/restoration engine remains the Nexus 1.0.2 engine.
import_marker = '#import <objc/message.h>\n'
if 'extern NSString *Nexus2Localized(NSString *key);' not in s:
    if import_marker not in s:
        raise SystemExit("import marker not found")
    s = s.replace(import_marker, import_marker + '\nextern NSString *Nexus2Localized(NSString *key);\n', 1)

pref_marker = 'static NSString *const IQFOLEDPreferenceKey = @"iQFaceOLEDEnabled";\n'
if pref_marker not in s:
    raise SystemExit("OLED preference marker not found")

helpers = r'''
static NSString *const Nexus2BackgroundModeKey = @"NexusBackgroundMode";
static NSString *const Nexus2BackgroundColorKey = @"NexusCustomBackgroundColor";

static NSInteger Nexus2BackgroundMode(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:Nexus2BackgroundModeKey];
    if (value == nil) return 1;
    return MAX(0, MIN(2, [value integerValue]));
}

static UIColor *Nexus2BackgroundColorFromHex(NSString *hex) {
    if (![hex isKindOfClass:NSString.class] || hex.length == 0) return UIColor.blackColor;
    NSString *clean = [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    unsigned long long raw = 0;
    if (![[NSScanner scannerWithString:clean] scanHexLongLong:&raw]) return UIColor.blackColor;
    if (clean.length == 6) raw = (raw << 8) | 0xFF;
    if (clean.length != 8) return UIColor.blackColor;
    return [UIColor colorWithRed:((raw >> 24) & 0xFF) / 255.0
                           green:((raw >> 16) & 0xFF) / 255.0
                            blue:((raw >> 8) & 0xFF) / 255.0
                           alpha:(raw & 0xFF) / 255.0];
}

static UIColor *Nexus2TargetBackgroundColor(void) {
    if (Nexus2BackgroundMode() != 2) return UIColor.blackColor;
    NSString *hex = [NSUserDefaults.standardUserDefaults stringForKey:Nexus2BackgroundColorKey];
    return Nexus2BackgroundColorFromHex(hex ?: @"#000000FF");
}
'''
s = s.replace(pref_marker, pref_marker + helpers, 1)

# Keep the 1.0.2 engine enabled state, but source it from Nexus mode.
s, n = re.subn(
    r'gIQFOLEDEnabled = IQFOLEDLoadEnabledPreference\(\);',
    'gIQFOLEDEnabled = (Nexus2BackgroundMode() != 0);',
    s,
)
if n < 2:
    raise SystemExit(f"expected constructor + live refresh replacements, found {n}")

# 1.0.2 detection principle: dark mode is established by Facebook's mapped
# dark anchors. Do not use the iOS trait as a fallback.
old_fallback = '''    } else if (!gIQFOLEDModeKnown) {
        for (UIWindow *window in windows) {
            if (window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                gIQFOLEDDarkMode = YES;
                gIQFOLEDModeKnown = YES;
                break;
            }
        }
    }'''
new_fallback = '''    } else {
        gIQFOLEDDarkMode = NO;
        gIQFOLEDModeKnown = NO;
    }'''
if old_fallback not in s:
    raise SystemExit("theme fallback marker not found")
s = s.replace(old_fallback, new_fallback, 1)

# Preserve 1.0.2 detection/restoration semantics. Only change the transformed
# output color from literal black to Nexus target color.
old_black = '''static BOOL IQFOLEDIsBlack(uint32_t rgba) {
    return rgba == 0x000000FF;
}'''
new_black = '''static BOOL IQFOLEDIsBlack(uint32_t rgba) {
    return rgba == IQFOLEDRGBA(Nexus2TargetBackgroundColor(), nil);
}'''
if old_black not in s:
    raise SystemExit("IQFOLEDIsBlack marker not found")
s = s.replace(old_black, new_black, 1)

split_marker = '@interface UIView (iQFaceOLEDInstant)'
if split_marker not in s:
    raise SystemExit("UIView instant marker not found")
head, tail = s.split(split_marker, 1)
if tail.count('UIColor.blackColor') < 3:
    raise SystemExit("expected 1.0.2 engine blackColor uses")
tail = tail.replace('UIColor.blackColor', 'Nexus2TargetBackgroundColor()')
s = head + split_marker + tail

# Diagnostics only; do not alter the engine.
setter_marker = 'static void IQFOLEDInstallInstantSetter(void) {'
if setter_marker not in s:
    raise SystemExit("setter marker missing")
s = s.replace(
    setter_marker,
    '''static BOOL gNexus2BackgroundHookInstalled = NO;

__attribute__((used, visibility("default")))
BOOL Nexus2BackgroundHookInstalled(void) {
    return gNexus2BackgroundHookInstalled;
}

__attribute__((used, visibility("default")))
NSInteger Nexus2BackgroundCurrentMode(void) {
    return Nexus2BackgroundMode();
}

__attribute__((used, visibility("default")))
BOOL Nexus2BackgroundEffectActive(void) {
    return Nexus2BackgroundMode() != 0 && gIQFOLEDModeKnown && gIQFOLEDDarkMode;
}

static void IQFOLEDInstallInstantSetter(void) {''',
    1,
)

exchange = 'method_exchangeImplementations(original, replacement);'
if exchange not in s:
    raise SystemExit("setter exchange marker missing")
s = s.replace(exchange, exchange + '\n            gNexus2BackgroundHookInstalled = YES;', 1)

# Localize separator row without changing OLED mechanics.
s = s.replace(
    'return [title isEqualToString:@"Separadores no feed"] ||\n           [title isEqualToString:@"Feed separators"];',
    'return [title isEqualToString:@"Separadores no feed"] ||\n'
    '           [title isEqualToString:@"Feed separators"] ||\n'
    '           [title isEqualToString:Nexus2Localized(@"Feed separators")];',
    1,
)
s = s.replace(
    'return IQFOLEDCreateNativeIconRow(@"Separadores no feed", @"line.3.horizontal");',
    'return IQFOLEDCreateNativeIconRow(Nexus2Localized(@"Feed separators"), @"line.3.horizontal");',
    1,
)

required = [
    'Nexus2BackgroundModeKey',
    'Nexus2TargetBackgroundColor',
    'IQFOLEDIsMappedDark',
    'IQFOLEDCountThemeAnchors',
    'gIQFOLEDDarkMode',
    'gIQFOLEDEnabled = (Nexus2BackgroundMode() != 0);',
    'Nexus2BackgroundHookInstalled',
    'Nexus2BackgroundEffectActive',
]
for marker in required:
    if marker not in s:
        raise SystemExit(f"missing R6 marker: {marker}")

for forbidden in [
    'IQFRefreshOLED',
    'IQFApplyForcedAppearance',
    'IQFKeyOLEDDarkMode',
    'overrideUserInterfaceStyle',
]:
    if forbidden in s:
        raise SystemExit(f"forbidden theme-control marker in OLED engine: {forbidden}")

p.write_text(s, encoding="utf-8")
print("Prepared Nexus 2.0 Beta 2 R6 from Nexus 1.0.2 OLED engine")
