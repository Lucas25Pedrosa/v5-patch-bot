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
    "// iQFaceOLED 0.1.4 EN",
    "version",
)

replace_once(
    '''static NSString *IQFOLEDStatusText(void) {
    return gIQFOLEDEnabled ? @"Ativado" : @"Desativado";
}''',
    '''__attribute__((unused)) static NSString *IQFOLEDStatusText(void) {
    return gIQFOLEDEnabled ? @"Enabled" : @"Disabled";
}''',
    "legacy status text",
)

replace_once(
    "static void IQFOLEDPresentControlMenu(UIViewController *controller) {",
    "__attribute__((unused)) static void IQFOLEDPresentControlMenu(UIViewController *controller) {",
    "legacy alert",
)

replace_once(
    '@"O modo OLED está ativado." : @"O modo OLED está desativado."',
    '@"OLED mode is enabled." : @"OLED mode is disabled."',
    "legacy alert message",
)

replace_once('@"Cancelar"', '@"Cancel"', "legacy cancel")
replace_once('@"Desativar" : @"Ativar"', '@"Disable" : @"Enable"', "legacy action")

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

    // Native iQFace row: iQFace owns the UISwitch and the preference key.
    void (^onChange)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            IQFOLEDSetEnabled(!gIQFOLEDEnabled, nil);
        });
    };

    typedef id (*IQFOLEDNativeToggleBuilder)(id, SEL, id, id, id, BOOL, id);
    IQFOLEDNativeToggleBuilder builder = (IQFOLEDNativeToggleBuilder)(void *)objc_msgSend;
    return builder(controller,
                   selector,
                   @"OLED Mode",
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

text = text.replace('[iQFaceOLED] linha Modo OLED adicionada (%@)', '[iQFaceOLED] OLED Mode row added (%@)')
text = text.replace('[iQFaceOLED] seção Ferramentas não encontrada; tela mantida intacta', '[iQFaceOLED] Tools section not found; settings left unchanged')
text = text.replace('[iQFaceOLED] construtor nativo de IQFRow indisponível', '[iQFaceOLED] native IQFRow builder unavailable')
text = text.replace('[iQFaceOLED] não foi possível adicionar a linha; tela mantida intacta', '[iQFaceOLED] could not add row; settings left unchanged')

path.write_text(text, encoding="utf-8")
print("Prepared iQFaceOLED 0.1.4 English native iQFace toggle from validated 0.1.1 base")
