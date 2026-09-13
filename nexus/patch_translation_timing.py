from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")

replacements = {
    "IQFPTOriginalViewDidAppear": "IQFPTOriginalViewWillAppear",
    "IQFPTAppearHookInstalled": "IQFPTWillAppearHookInstalled",
    "IQFSettingsViewDidAppear": "IQFSettingsViewWillAppear",
    "viewDidAppear:": "viewWillAppear:",
}

for old, new in replacements.items():
    if old not in s:
        raise RuntimeError(f"missing expected translation hook token: {old}")
    s = s.replace(old, new)

if "viewDidAppear:" in s:
    raise RuntimeError("late translation hook still present")
if "viewWillAppear:" not in s:
    raise RuntimeError("pre-visible translation hook missing")

p.write_text(s, encoding="utf-8")
