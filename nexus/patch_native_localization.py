from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

# Install the existing native localization path immediately before settings
# are opened. This makes the translated text available while iQFace creates
# and measures its rows.
needle = 'void IQFOpenSettings(void) {\n    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;'
replacement = 'void IQFOpenSettings(void) {\n    IQFInstallLocalizationHook();\n    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;'
if needle not in s:
    raise RuntimeError('IQFOpenSettings marker not found')
s = s.replace(needle, replacement, 1)

# Keep the native dictionary aligned with the shorter strings already used by
# the PT-BR UI fallback.
replacements = {
    '@"Follow system": @"Seguir idioma do sistema"': '@"Follow system": @"Seguir sistema"',
    '@"Hide group suggestions": @"Ocultar sugestões de grupos"': '@"Hide group suggestions": @"Ocultar grupos sugeridos"',
    '@"Join Telegram channel": @"Entrar no canal do Telegram"': '@"Join Telegram channel": @"Canal do Telegram"',
    '@"Confirm posting a comment": @"Confirmar publicação do comentário"': '@"Confirm posting a comment": @"Confirmar comentário"',
    '@"Confirm friend requests": @"Confirmar solicitações de amizade"': '@"Confirm friend requests": @"Confirmar amizades"',
    '@"Confirm follow and join": @"Confirmar ações de seguir e entrar"': '@"Confirm follow and join": @"Confirmar seguir/entrar"',
    '@"Confirm sending a message": @"Confirmar envio de mensagens"': '@"Confirm sending a message": @"Confirmar mensagem"',
}
for old, new in replacements.items():
    if old not in s:
        raise RuntimeError(f'missing native translation: {old}')
    s = s.replace(old, new, 1)

marker = '            @"English": @"Inglês",\n'
if marker not in s:
    raise RuntimeError('native dictionary marker not found')
extra = '''            @"General": @"Geral",
            @"Stories": @"Stories",
            @"Reels": @"Reels",
            @"FEATURES": @"RECURSOS",
            @"Appearance": @"Aparência",
            @"APPEARANCE": @"APARÊNCIA",
            @"DEV": @"DEV",
            @"ABOUT": @"SOBRE",
            @"Open links in Safari": @"Abrir no Safari",
            @"Block in-stream video ads": @"Bloquear anúncios em vídeos",
            @"Hide suggested posts": @"Ocultar posts sugeridos",
            @"Hide stories": @"Ocultar stories",
            @"Ghost mode in stories": @"Modo fantasma",
            @"Watch stories locally (grey ring)": @"Assistir localmente",
            @"Hide Reels screen elements": @"Ocultar elementos",
            @"Show Reels screen elements": @"Mostrar elementos",
            @"Separate buttons": @"Botões separados",
            @"Reels controls": @"Controles do Reels",
            @"Button layout": @"Layout dos botões",
            @"One iQ button": @"Um botão iQ",
            @"Hold for Reels menu": @"Segure para menu",
            @"Reels overlay": @"Sobreposição do Reels",
            @"Hide action rail": @"Ocultar ações",
            @"Hide Likes": @"Ocultar curtidas",
            @"Hide Comments": @"Ocultar comentários",
            @"Hide Share": @"Ocultar compartilhamento",
            @"Hide creator information": @"Ocultar criador",
            @"Hide description": @"Ocultar descrição",
            @"Save photo": @"Salvar foto",
            @"Save full-resolution photo": @"Salvar foto original",
'''
s = s.replace(marker, marker + extra, 1)

if 'IQFInstallLocalizationHook();' not in s:
    raise RuntimeError('native localization install missing')
if '@"Separate buttons": @"Botões separados"' not in s:
    raise RuntimeError('extended native translations missing')

p.write_text(s, encoding='utf-8')
