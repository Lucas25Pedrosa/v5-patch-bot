from pathlib import Path
import re
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
s = src.read_text(encoding="utf-8")

s = s.replace("// iQFaceCache 0.2.1", "// Nexus Cache module 0.2.2", 1)
s, n = re.subn(
    r'static BOOL IQFCCacheUsesPortuguese\(void\) \{.*?\n\}',
    'static BOOL IQFCCacheUsesPortuguese(void) {\n    return YES;\n}',
    s,
    count=1,
    flags=re.S,
)
assert n == 1

pattern = re.compile(
    r'\s*NSArray<NSString \*> \*options = IQFCCacheUsesPortuguese\(\)\s*'
    r'\?\s*@\[@"Desativado",\s*@"Diariamente",\s*@"Semanalmente",\s*@"Mensalmente"\]\s*'
    r':\s*@\[@"Disabled",\s*@"Daily",\s*@"Weekly",\s*@"Monthly"\];'
)
replacement = '''
    NSArray<NSDictionary<NSString *, id> *> *options = @[
        @{@"value": @0, @"title": @"Desativado"},
        @{@"value": @1, @"title": @"Diariamente"},
        @{@"value": @2, @"title": @"Semanalmente"},
        @{@"value": @3, @"title": @"Mensalmente"}
    ];'''
s, n = pattern.subn(replacement, s, count=1)
assert n == 1

old = "            IQFCCacheTryInstallHook();\n            IQFCCacheStartAutomaticScheduler();"
assert old in s
s = s.replace(old, "            IQFCCacheStartAutomaticScheduler();", 1)
s += '''\n\nid NexusCacheCreateManualSetting(void) { return IQFCCacheCreateManualSetting(); }\nid NexusCacheCreateAutomaticSetting(void) { return IQFCCacheCreateAutomaticSetting(); }\n'''

out.write_text(s, encoding="utf-8")
