from pathlib import Path
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
s = src.read_text(encoding="utf-8")

old = '''        dispatch_async(dispatch_get_main_queue(), ^{
            IQFOLEDStartEngine();
            IQFOLEDTryInstallSettingsHook();
        });'''
assert old in s
s = s.replace(old, '''        dispatch_async(dispatch_get_main_queue(), ^{
            IQFOLEDStartEngine();
        });''', 1)

s += '''\n\nid NexusOLEDCreateModeSetting(void) {\n    return IQFOLEDCreateNativeIconRow(@"OLED Mode", @"circle.lefthalf.filled");\n}\nid NexusOLEDCreateSeparatorSetting(void) {\n    return IQFOLEDCreateNativeIconRow(@"Feed separators", @"line.3.horizontal");\n}\nvoid NexusOLEDPrepareSettingsCell(void) {\n    IQFOLEDTryInstallAccessorySwitchHook();\n}\n'''

out.write_text(s, encoding="utf-8")
