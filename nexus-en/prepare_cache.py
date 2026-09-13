from pathlib import Path
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
s = src.read_text(encoding="utf-8")
old = '''        dispatch_async(dispatch_get_main_queue(), ^{
            IQFCCacheTryInstallHook();
            IQFCCacheStartAutomaticScheduler();
        });'''
assert old in s
s = s.replace(old, '''        dispatch_async(dispatch_get_main_queue(), ^{
            IQFCCacheStartAutomaticScheduler();
        });''', 1)
s += '\n\nid NexusCacheCreateManualSetting(void) { return IQFCCacheCreateManualSetting(); }\nid NexusCacheCreateAutomaticSetting(void) { return IQFCCacheCreateAutomaticSetting(); }\n'
out.write_text(s, encoding="utf-8")
