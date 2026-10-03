from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

if 'extern NSString *Nexus2Localized(NSString *key);' not in s:
    marker = '#import <objc/message.h>\n'
    if marker not in s:
        marker = '#import <objc/runtime.h>\n'
    if marker not in s:
        raise SystemExit("import marker not found")
    s = s.replace(marker, marker + '\nextern NSString *Nexus2Localized(NSString *key);\n', 1)

pref_marker = 'static NSString *const IQFOLEDPreferenceKey = @"iQFaceOLEDEnabled";\n'
if pref_marker not in s:
    raise SystemExit("OLED preference marker not found")

helpers = r'''
static NSString *const Nexus2BackgroundModeKey = @"NexusBackgroundMode";
static NSString *const Nexus2BackgroundColorKey = @"NexusCustomBackgroundColor";

static NSInteger Nexus2BackgroundMode(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:Nexus2BackgroundModeKey];
    if (value == nil) return 1; // Preserve the historical Nexus OLED default.
    NSInteger mode = [value integerValue];
    return MAX(0, MIN(2, mode));
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

old_black = '''static BOOL IQFOLEDIsBlack(uint32_t rgba) {
    return rgba == 0x000000FF;
}'''
new_black = '''static BOOL IQFOLEDIsBlack(uint32_t rgba) {
    return rgba == IQFOLEDRGBA(Nexus2TargetBackgroundColor(), nil);
}'''
if old_black not in s:
    raise SystemExit("IQFOLEDIsBlack marker not found")
s = s.replace(old_black, new_black, 1)

black_count = s.count('UIColor.blackColor')
if black_count < 3:
    raise SystemExit(f"expected at least 3 blackColor uses, found {black_count}")
# Leave helper fallback/default blackColor uses intact by replacing only occurrences after UIView category begins.
split_marker = '@interface UIView (iQFaceOLEDInstant)'
head, tail = s.split(split_marker, 1)
tail_count = tail.count('UIColor.blackColor')
if tail_count < 3:
    raise SystemExit(f"expected >=3 engine blackColor uses, found {tail_count}")
tail = tail.replace('UIColor.blackColor', 'Nexus2TargetBackgroundColor()')
s = head + split_marker + tail

# The transformed iQFace 1.2 engine refreshes the legacy bool every pass.
s, n = re.subn(
    r'gIQFOLEDEnabled = IQFOLEDLoadEnabledPreference\(\);',
    'gIQFOLEDEnabled = (Nexus2BackgroundMode() != 0);',
    s,
)
if n < 2:
    raise SystemExit(f"expected constructor + live refresh replacements, found {n}")

# Instant setter must follow the new mode even before the first periodic pass.
s = s.replace(
    'if (gIQFOLEDEnabled && IQFOLEDIsMappedDark(rgba)) {',
    'if (Nexus2BackgroundMode() != 0 && IQFOLEDIsMappedDark(rgba)) {',
    1,
)

# Expose the real background hook state to Nexus Diagnostics.
setter_marker = 'static void IQFOLEDInstallInstantSetter(void) {'
if setter_marker not in s:
    raise SystemExit("instant setter marker not found")
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

static void IQFOLEDInstallInstantSetter(void) {''',
    1,
)

exchange_marker = 'method_exchangeImplementations(original, replacement);'
if exchange_marker not in s:
    raise SystemExit("background exchange marker not found")
s = s.replace(
    exchange_marker,
    exchange_marker + '\n            gNexus2BackgroundHookInstalled = YES;',
    1,
)

# Localize the retained separator control for every iQFace 1.2 language.
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
    'Nexus2Localized(@"Feed separators")',
    'gIQFOLEDEnabled = (Nexus2BackgroundMode() != 0);',
    'Nexus2BackgroundHookInstalled',
    'Nexus2BackgroundCurrentMode',
]
for marker in required:
    if marker not in s:
        raise SystemExit(f"missing Nexus 2 marker: {marker}")

p.write_text(s, encoding="utf-8")
print("Prepared Nexus 2.0 background modes and localized separator")
