from pathlib import Path
import re
import sys

# argv: tweak_path translation_path

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

# Nexus PT-BR: block the original iQFace settings launcher before its first
# rendered frame. The navigation/addSubview hook uses the Enhancer's exact
# matcher (UIButton + accessibilityLabel "iQFace" + action "iqf_tapped").
# Keep the broader tab-bar hooks disabled; the scanner remains fallback only.
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

s = translation.read_text(encoding="utf-8")
marker = '__attribute__((used, visibility("default"))) NSString * const IQFEnhancerTranslationVersion = @"1.1-core-ptbr";\n\n'
needle = '#import <string.h>\n\n'
assert needle in s
s = s.replace(needle, needle + marker, 1)
s = s.replace('@"Follow system": @"Seguir idioma do sistema",', '@"Follow system": @"Seguir sistema",')
s = s.replace('@"Join Telegram channel": @"Entrar no canal do Telegram",', '@"Join Telegram channel": @"Canal do Telegram",')
old_last = '@"iQFace Settings": @"Ajustes do iQFace"\n'
assert old_last in s
additions = '''@"iQFace Settings": @"Ajustes do iQFace",\n            @"General": @"Geral",\n            @"Stories": @"Stories",\n            @"Reels": @"Reels",\n            @"FEATURES": @"RECURSOS",\n            @"Appearance": @"Aparência",\n            @"APPEARANCE": @"APARÊNCIA",\n            @"DEV": @"DEV",\n            @"ABOUT": @"SOBRE",\n            @"Open links in Safari": @"Abrir no Safari",\n            @"Block in-stream video ads": @"Bloquear anúncios em vídeos",\n            @"Hide suggested posts": @"Ocultar posts sugeridos",\n            @"Hide stories": @"Ocultar stories",\n            @"Ghost mode in stories": @"Modo fantasma",\n            @"Watch stories locally (grey ring)": @"Assistir localmente",\n            @"Auto-advance": @"Avanço automático",\n            @"Hide Reels screen elements": @"Ocultar elementos",\n            @"Show Reels screen elements": @"Mostrar elementos",\n            @"Separate buttons": @"Botões separados",\n            @"Reels controls": @"Controles do Reels",\n            @"Button layout": @"Layout dos botões",\n            @"One iQ button": @"Um botão iQ",\n            @"Hold for Reels menu": @"Segure para menu",\n            @"Reels overlay": @"Sobreposição do Reels",\n            @"Hide action rail": @"Ocultar ações",\n            @"Hide Likes": @"Ocultar curtidas",\n            @"Hide Comments": @"Ocultar comentários",\n            @"Hide Share": @"Ocultar compartilhamento",\n            @"Hide creator information": @"Ocultar criador",\n            @"Hide description": @"Ocultar descrição",\n            @"Hide video buttons": @"Ocultar botões do vídeo",\n            @"Show video buttons": @"Mostrar botões do vídeo",\n            @"Auto-advance on": @"Avanço automático ativado",\n            @"Auto-advance off": @"Avanço automático desativado",\n            @"Save photo": @"Salvar foto",\n            @"Save full-resolution photo": @"Salvar foto original"\n'''
s = s.replace(old_last, additions, 1)
assert 'MSHookMessageEx' in s
assert '@selector(viewDidLayoutSubviews)' in s
assert '@selector(viewDidAppear:)' in s
translation.write_text(s, encoding="utf-8")
