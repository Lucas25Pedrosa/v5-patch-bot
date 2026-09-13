from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
s = s.replace("static void IQFOpenSettings(void) {", "void IQFOpenSettings(void) {", 1)
pattern = r"static void IQFAttachLongPress\(UIView \*view\) \{.*?\n\}"
replacement = '''static void IQFAttachLongPress(UIView *view) {
    (void)view;
    (void)IQFLongPressDuration;
}'''
s, n = re.subn(pattern, replacement, s, count=1, flags=re.S)
assert n == 1
old_hooks = '''        if (!IQFSafeModeEnabled()) {
            IQFInstallNavigationItemHooks();
            IQFInstallTabBarHooks();
        }'''
assert old_hooks in s
s = s.replace(old_hooks, '''        (void)IQFSafeModeEnabled();''', 1)
assert 'IQFInstallNavigationItemHooks();' not in s
assert 'IQFInstallTabBarHooks();' not in s
p.write_text(s, encoding="utf-8")
