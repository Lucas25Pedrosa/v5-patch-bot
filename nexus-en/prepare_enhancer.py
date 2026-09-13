from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

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
assert 'IQFFindSymbol("IQFPresentSettings")' in s
assert 'IQFPresentLauncherMenu' not in s
p.write_text(s, encoding="utf-8")
