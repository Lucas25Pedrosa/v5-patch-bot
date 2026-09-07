from pathlib import Path

path = Path("Tweak.m")
text = path.read_text(encoding="utf-8")


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly 1 match, found {count}")
    text = text.replace(old, new, 1)


replace_once(
    "// iQFaceOLED 0.1.1",
    "// iQFaceOLED 0.1.3",
    "version",
)

replace_once(
    "#import <math.h>\n",
    "#import <math.h>\n\nextern void IQFOLEDPresentModePickerFromViewController(UIViewController *presenter);\n",
    "picker declaration",
)

set_enabled_block = '''static void IQFOLEDSetEnabled(BOOL enabled, UIViewController *controller) {
    if (gIQFOLEDEnabled == enabled) return;

    gIQFOLEDEnabled = enabled;
    IQFOLEDSaveEnabledPreference(enabled);

    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];

    IQFOLEDRefreshSettingsRow(controller);
    IQFOLEDRunPass();
}
'''

set_enabled_with_api = set_enabled_block + '''
BOOL IQFOLEDGetEnabled(void) {
    return gIQFOLEDEnabled;
}

void IQFOLEDSetEnabledFromPicker(BOOL enabled) {
    IQFOLEDSetEnabled(enabled, nil);
}
'''

replace_once(set_enabled_block, set_enabled_with_api, "picker engine API")

replace_once(
    "static void IQFOLEDPresentControlMenu(UIViewController *controller) {",
    "__attribute__((unused)) static void IQFOLEDPresentControlMenu(UIViewController *controller) {",
    "legacy alert",
)

replace_once(
    "            IQFOLEDPresentControlMenu(presenter);",
    "            IQFOLEDPresentModePickerFromViewController(presenter);",
    "row tap",
)

replace_once(
    '''                   IQFOLEDStatusText(),
                   [tapBlock copy]);''',
    '''                   @"",
                   [tapBlock copy]);''',
    "static row detail",
)

replace_once(
    '''        IQFOLEDRefreshSettingsRow(controller);
        return;
    }

    id toolsSection = IQFOLEDFindToolsSection(sections);''',
    '''        return;
    }

    id toolsSection = IQFOLEDFindToolsSection(sections);''',
    "existing row path",
)

path.write_text(text, encoding="utf-8")
print("Prepared iQFaceOLED 0.1.3 from validated 0.1.1 base")
