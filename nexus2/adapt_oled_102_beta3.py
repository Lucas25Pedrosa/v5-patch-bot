from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

# Beta 3 keeps the Nexus 1.0.2 OLED enable/detection/restoration engine intact.
# Custom color only changes the replacement color. It is not a third mode.
import_marker = '#import <objc/message.h>\n'
if 'extern NSString *Nexus2Localized(NSString *key);' not in s:
    if import_marker not in s:
        raise SystemExit("import marker not found")
    s = s.replace(import_marker, import_marker + '\nextern NSString *Nexus2Localized(NSString *key);\n', 1)

pref_marker = 'static NSString *const IQFOLEDPreferenceKey = @"iQFaceOLEDEnabled";\n'
if pref_marker not in s:
    raise SystemExit("OLED preference marker not found")

helpers = r'''
static NSString *const Nexus2BackgroundColorKey = @"NexusCustomBackgroundColor";
static NSString *const Nexus2LegacyBackgroundModeKey = @"NexusBackgroundMode";
static NSString *const Nexus2Beta3MigrationKey = @"NexusBeta3BackgroundMigrated";

static void Nexus2WriteOLEDPreference(BOOL enabled) {
    Class prefs = NSClassFromString(@"IQFPrefs");
    SEL selector = NSSelectorFromString(@"setBool:forKey:");
    if (prefs != Nil && [prefs respondsToSelector:selector]) {
        typedef void (*Setter)(id, SEL, BOOL, id);
        ((Setter)(void *)objc_msgSend)(prefs, selector, enabled, IQFOLEDPreferenceKey);
    } else {
        [NSUserDefaults.standardUserDefaults setBool:enabled forKey:IQFOLEDPreferenceKey];
        [NSUserDefaults.standardUserDefaults synchronize];
    }
}

static void Nexus2MigrateLegacyBackgroundModeIfNeeded(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:Nexus2Beta3MigrationKey]) return;

    id oldValue = [defaults objectForKey:Nexus2LegacyBackgroundModeKey];
    if (oldValue != nil) {
        NSInteger oldMode = MAX(0, MIN(2, [oldValue integerValue]));
        Nexus2WriteOLEDPreference(oldMode != 0);

        // Old "OLED" and "Standard" become the classic pure-black OLED target.
        // Only the old Custom mode carries its selected color into Beta 3.
        if (oldMode != 2) {
            [defaults setObject:@"#000000FF" forKey:Nexus2BackgroundColorKey];
        }
        [defaults removeObjectForKey:Nexus2LegacyBackgroundModeKey];
    }

    [defaults setBool:YES forKey:Nexus2Beta3MigrationKey];
    [defaults synchronize];
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
    NSString *hex = [NSUserDefaults.standardUserDefaults stringForKey:Nexus2BackgroundColorKey];
    return Nexus2BackgroundColorFromHex(hex ?: @"#000000FF");
}
'''
s = s.replace(pref_marker, pref_marker + helpers, 1)

# Make migration run before the original 1.0.2 preference is read.
load_marker = 'static BOOL IQFOLEDLoadEnabledPreference(void) {\n'
if load_marker not in s:
    raise SystemExit("OLED load preference marker not found")
s = s.replace(load_marker,
              load_marker + '    Nexus2MigrateLegacyBackgroundModeIfNeeded();\n',
              1)

# Keep the original 1.0.2 dark detection and enabled toggle exactly as generated.
# Only reinterpret "replacement black" as the selected target color.
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
    raise SystemExit("expected classic 1.0.2 engine blackColor uses")
tail = tail.replace('UIColor.blackColor', 'Nexus2TargetBackgroundColor()')
s = head + split_marker + tail

# Diagnostics and immediate refresh helpers. They do not change the theme.
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
    return IQFOLEDLoadEnabledPreference() ? 1 : 0;
}

__attribute__((used, visibility("default")))
BOOL Nexus2BackgroundEffectActive(void) {
    return gIQFOLEDEnabled && gIQFOLEDDarkMode;
}

static void IQFOLEDInstallInstantSetter(void) {''',
    1,
)

exchange = 'method_exchangeImplementations(original, replacement);'
if exchange not in s:
    raise SystemExit("setter exchange marker missing")
s = s.replace(exchange, exchange + '\n            gNexus2BackgroundHookInstalled = YES;', 1)

# Export two safe helpers so a color change can restore the old replacement
# before applying the newly selected color.
run_marker = 'static void IQFOLEDStartEngine(void) {'
if run_marker not in s:
    raise SystemExit("engine start marker missing")
helpers2 = r'''
__attribute__((used, visibility("default")))
void Nexus2BackgroundPrepareColorChange(void) {
    if (!NSThread.isMainThread) return;

    BOOL oldEnabled = gIQFOLEDEnabled;
    gIQFOLEDEnabled = NO;
    for (UIWindow *window in IQFOLEDWindows()) {
        IQFOLEDTransformView(window);
    }
    gIQFOLEDEnabled = oldEnabled;
}

__attribute__((used, visibility("default")))
void Nexus2BackgroundRefreshNow(void) {
    IQFOLEDRunPass();
}

'''
s = s.replace(run_marker, helpers2 + run_marker, 1)

# Localize the retained separator control without touching OLED behavior.
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
    'IQFOLEDPreferenceKey = @"iQFaceOLEDEnabled"',
    'Nexus2BackgroundColorKey',
    'Nexus2MigrateLegacyBackgroundModeIfNeeded',
    'IQFOLEDIsMappedDark',
    'IQFOLEDCountThemeAnchors',
    'window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark',
    'gIQFOLEDEnabled = IQFOLEDLoadEnabledPreference();',
    'Nexus2BackgroundHookInstalled',
    'Nexus2BackgroundEffectActive',
    'Nexus2BackgroundPrepareColorChange',
    'Nexus2BackgroundRefreshNow',
]
for marker in required:
    if marker not in s:
        raise SystemExit(f"missing Beta 3 marker: {marker}")

for forbidden in [
    'IQFRefreshOLED',
    'IQFApplyForcedAppearance',
    'IQFKeyOLEDDarkMode',
    'overrideUserInterfaceStyle',
]:
    if forbidden in s:
        raise SystemExit(f"forbidden theme-control marker in OLED engine: {forbidden}")

p.write_text(s, encoding="utf-8")
print("Prepared Nexus 2.0 Beta 3: classic 1.0.2 OLED toggle + custom replacement color")
