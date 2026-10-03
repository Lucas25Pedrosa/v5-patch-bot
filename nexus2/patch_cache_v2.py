from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

marker = '#import <objc/message.h>\n'
if marker not in s:
    raise SystemExit("import marker missing")
s = s.replace(marker, marker + '\nextern NSString *Nexus2Localized(NSString *key);\n', 1)

s, n = re.subn(
    r'static BOOL IQFCCacheUsesPortuguese\(void\) \{.*?\n\}',
    'static BOOL IQFCCacheUsesPortuguese(void) { return NO; }',
    s, count=1, flags=re.S
)
if n != 1:
    raise SystemExit("cache language function not found")

s, n = re.subn(
    r'static NSString \*IQFCCacheText\(NSString \*portuguese, NSString \*english\) \{.*?\n\}',
    '''static NSString *IQFCCacheText(NSString *portuguese, NSString *english) {
    (void)portuguese;
    if ([english isEqualToString:@"Clear cache automatically"]) {
        return Nexus2Localized(@"Automatic cache clearing");
    }
    if ([english isEqualToString:@"✓ Cache cleared"]) {
        return Nexus2Localized(@"Cache cleared");
    }
    if ([english isEqualToString:@"%@ freed"]) {
        return [NSString stringWithFormat:@"%%@ %@", Nexus2Localized(@"freed")];
    }
    return Nexus2Localized(english);
}''',
    s, count=1, flags=re.S
)
if n != 1:
    raise SystemExit("cache text function not found")

# prepare_cache.py converts this to structured options with Portuguese titles.
pattern = re.compile(
    r'NSArray<NSDictionary<NSString \*, id> \*> \*options = @\[\s*'
    r'@\{@"value": @0, @"title": @"Desativado"\},\s*'
    r'@\{@"value": @1, @"title": @"Diariamente"\},\s*'
    r'@\{@"value": @2, @"title": @"Semanalmente"\},\s*'
    r'@\{@"value": @3, @"title": @"Mensalmente"\}\s*'
    r'\];'
)
replacement = '''NSArray<NSDictionary<NSString *, id> *> *options = @[
        @{@"value": @0, @"title": Nexus2Localized(@"Disabled")},
        @{@"value": @1, @"title": Nexus2Localized(@"Daily")},
        @{@"value": @2, @"title": Nexus2Localized(@"Weekly")},
        @{@"value": @3, @"title": Nexus2Localized(@"Monthly")}
    ];'''
s, n = pattern.subn(replacement, s, count=1)
if n != 1:
    raise SystemExit("cache options block not found")

for required in [
    'Nexus2Localized(english)',
    'Nexus2Localized(@"Disabled")',
    'Nexus2Localized(@"Automatic cache clearing")',
]:
    if required not in s:
        raise SystemExit(f"missing marker {required}")

p.write_text(s, encoding="utf-8")
print("Localized Nexus 2.0 cache module")
