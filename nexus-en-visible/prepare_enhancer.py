from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

# Keep the original iQFace launcher visible in this dedicated variant.
s = s.replace("static void IQFOpenSettings(void) {", "void IQFOpenSettings(void) {", 1)

# Disable the long-press launcher path from Nexus itself; the native iQFace
# launcher remains the only entry point.
pattern = r"static void IQFAttachLongPress\(UIView \*view\) \{.*?\n\}"
replacement = '''static void IQFAttachLongPress(UIView *view) {
    (void)view;
    (void)IQFLongPressDuration;
}'''
s, n = re.subn(pattern, replacement, s, count=1, flags=re.S)
assert n == 1

# Do not install the immediate launcher-hiding hooks used by the normal Nexus.
old_hooks = '''        if (!IQFSafeModeEnabled()) {
            IQFInstallNavigationItemHooks();
            IQFInstallTabBarHooks();
        }'''
assert old_hooks in s
s = s.replace(old_hooks, '''        (void)IQFSafeModeEnabled();''', 1)

# The frozen Enhancer also has a delayed "safe scanner" that periodically
# removes the same iQFace launcher after startup / returning from settings.
# This visible-icon variant must neutralize that cleanup too.
clean_pattern = r"static void IQFCleanVisibleSettingsItems\(void\) \{.*?\n\}"
clean_replacement = '''static void IQFCleanVisibleSettingsItems(void) {
    // Intentionally disabled in Nexus English visible-icon variant.
}'''
s, n = re.subn(clean_pattern, clean_replacement, s, count=1, flags=re.S)
assert n == 1

scanner_pattern = r"static void IQFStartSafeScanner\(void\) \{.*?\n\}"
scanner_replacement = '''static void IQFStartSafeScanner(void) {
    // Intentionally disabled in Nexus English visible-icon variant.
}'''
s, n = re.subn(scanner_pattern, scanner_replacement, s, count=1, flags=re.S)
assert n == 1

assert 'IQFInstallNavigationItemHooks();' not in s
assert 'IQFInstallTabBarHooks();' not in s
assert 'static void IQFCleanVisibleSettingsItems(void) {\n    // Intentionally disabled' in s
assert 'static void IQFStartSafeScanner(void) {\n    // Intentionally disabled' in s

p.write_text(s, encoding="utf-8")
