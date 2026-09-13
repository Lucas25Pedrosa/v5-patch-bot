from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

# Nexus EN must never enable the PT-BR overlay just because the device/app
# language is Portuguese (or because an old force-Portuguese preference is set).
# Keep the iQFace 1.1 core on its original English strings for this build.
pt_pattern = r"static BOOL IQFShouldUsePortuguese\(void\) \{.*?\n\}"
pt_replacement = '''static BOOL IQFShouldUsePortuguese(void) {
    return NO;
}'''
s, n = re.subn(pt_pattern, pt_replacement, s, count=1, flags=re.S)
assert n == 1

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

# Nexus EN: prevent the original iQFace settings launcher from ever reaching
# the first rendered frame. Reuse the Enhancer's exact matcher
# (UIButton + accessibilityLabel "iQFace" + action "iqf_tapped") and keep
# the broader tab-bar hooks disabled.
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
assert 'static BOOL IQFShouldUsePortuguese(void) {\n    return NO;\n}' in s
assert 'IQFEnhancerForcePortuguese' not in s
p.write_text(s, encoding="utf-8")
