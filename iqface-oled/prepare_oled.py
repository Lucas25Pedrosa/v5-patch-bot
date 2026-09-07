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
    "// iQFaceOLED 0.1.4",
    "version",
)

replace_once(
    "static NSString *IQFOLEDStatusText(void) {",
    "__attribute__((unused)) static NSString *IQFOLEDStatusText(void) {",
    "legacy status text",
)

replace_once(
    "static void IQFOLEDPresentControlMenu(UIViewController *controller) {",
    "__attribute__((unused)) static void IQFOLEDPresentControlMenu(UIViewController *controller) {",
    "legacy alert",
)

old_create_row = '''static id IQFOLEDCreateNativeRow(UIViewController *controller) {
    SEL selector = NSSelectorFromString(@"valueRowWithTitle:icon:detail:tap:");
    if (controller == nil || ![controller respondsToSelector:selector]) return nil;

    __weak UIViewController *weakController = controller;
    void (^tapBlock)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = weakController;
            if (presenter == nil) return;
            IQFOLEDPresentControlMenu(presenter);
        });
    };

    typedef id (*IQFOLEDNativeRowBuilder)(id, SEL, id, id, id, id);
    IQFOLEDNativeRowBuilder builder = (IQFOLEDNativeRowBuilder)(void *)objc_msgSend;
    return builder(controller,
                   selector,
                   @"Modo OLED",
                   @"circle.lefthalf.filled",
                   IQFOLEDStatusText(),
                   [tapBlock copy]);
}
'''

new_create_row = '''static id IQFOLEDCreateNativeRow(UIViewController *controller) {
    SEL selector = NSSelectorFromString(@"rowWithTitle:icon:key:def:onChange:");
    if (controller == nil || ![controller respondsToSelector:selector]) return nil;

    // The native iQFace row owns the UISwitch and the preference key.  Keep the
    // callback argument-free so it remains ABI-safe whether iQFace invokes the
    // block with no explicit argument or supplies the new switch state.
    void (^onChange)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            IQFOLEDSetEnabled(!gIQFOLEDEnabled, nil);
        });
    };

    typedef id (*IQFOLEDNativeToggleBuilder)(id, SEL, id, id, id, BOOL, id);
    IQFOLEDNativeToggleBuilder builder = (IQFOLEDNativeToggleBuilder)(void *)objc_msgSend;
    return builder(controller,
                   selector,
                   @"Modo OLED",
                   @"circle.lefthalf.filled",
                   IQFOLEDPreferenceKey,
                   gIQFOLEDEnabled,
                   [onChange copy]);
}
'''

replace_once(old_create_row, new_create_row, "native toggle row")

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
print("Prepared iQFaceOLED 0.1.4 native iQFace toggle from validated 0.1.1 base")
