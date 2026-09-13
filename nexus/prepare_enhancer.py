from pathlib import Path
import re
import sys

tweak = Path(sys.argv[1])
translation = Path(sys.argv[2])

s = tweak.read_text(encoding="utf-8")
old = "static void IQFOpenSettings(void) {"
assert old in s
s = s.replace(old, "void IQFOpenSettings(void) {", 1)
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
new_hooks = '''        IQFInstallNavigationItemHooks();'''
assert old_hooks in s
s = s.replace(old_hooks, new_hooks, 1)
assert 'IQFFindSymbol("IQFPresentSettings")' in s
assert 'IQFPresentLauncherMenu' not in s
assert 'IQFInstallNavigationItemHooks();' in s
assert 'IQFInstallTabBarHooks();' not in s
tweak.write_text(s, encoding="utf-8")

ts = translation.read_text(encoding="utf-8")
assert 'MSHookMessageEx' in ts
assert '@selector(viewDidLayoutSubviews)' in ts
assert '@selector(viewDidAppear:)' in ts
