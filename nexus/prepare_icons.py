from pathlib import Path
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
s = src.read_text(encoding="utf-8")

old = '''        dispatch_async(dispatch_get_main_queue(), ^{
            IQFIconsTryInstallHook();
        });'''
assert old in s
s = s.replace(old, '''        // Nexus owns the single IQFTweakSettings sections hook.''', 1)
s += '''\n\nid NexusIconsCreateSetting(void) { return IQFIconsCreateNavigationSetting(); }\n'''

out.write_text(s, encoding="utf-8")
