#!/usr/bin/env python3
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
s = path.read_text(encoding="utf-8")

old_open = "static void IQFOpenSettings(void) {"
assert old_open in s
s = s.replace(old_open, "void IQFOpenSettings(void) {", 1)

pattern = r"static void IQFAttachLongPress\(UIView \*view\) \{.*?\n\}"
replacement = "static void IQFAttachLongPress(UIView *view) {\n    (void)view;\n    (void)IQFGestureAssociationKey;\n    (void)IQFLongPressDuration;\n}"
s, count = re.subn(pattern, replacement, s, count=1, flags=re.S)
assert count == 1

needle = "        if (!IQFSafeModeEnabled()) {\n            IQFInstallNavigationItemHooks();\n            IQFInstallTabBarHooks();\n        }\n"
assert needle in s
guard = "        IQFReplaceMethod(UIView.class, @selector(addSubview:), (IMP)&IQFAddSubview, (IMP *)&IQFOriginalAddSubview);\n\n"
s = s.replace(needle, guard + needle, 1)

assert 'IQFFindSymbol("IQFPresentSettings")' in s
assert 'IQFPresentLauncherMenu' not in s
assert '@"iQFace"' in s and '@"iqf_tapped"' in s

path.write_text(s, encoding="utf-8")
