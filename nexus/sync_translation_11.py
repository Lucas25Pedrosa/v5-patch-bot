from pathlib import Path
import re
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: sync_translation_11.py <legacy Translation.m> <Localization11.m>")

legacy_path = Path(sys.argv[1])
new_path = Path(sys.argv[2])
legacy = legacy_path.read_text(encoding="utf-8")
new = new_path.read_text(encoding="utf-8")

# Extract only the dictionary body from the iQFace 1.1 localization source.
# We deliberately keep the proven legacy translation hooks and lifecycle, then
# replace only the string table so Nexus 1.0.1 PT-BR gets the complete 1.1 set.
new_match = re.search(
    r"static NSDictionary<NSString \*, NSString \*> \*IQF11Translations\(void\) \{.*?translations = @\{(.*?)\n        \};",
    new,
    flags=re.S,
)
if not new_match:
    raise RuntimeError("could not locate iQFace 1.1 translation dictionary")
new_body = new_match.group(1)

# Nexus PT-BR uses a few compact labels where the literal iQFace 1.1
# translation is wider than the switch cell. Keep the meaning intact while
# avoiding truncation in the native settings layout.
compact_overrides = {
    '@"Confirm friend requests": @"Confirmar solicitações de amizade"':
        '@"Confirm friend requests": @"Confirmar pedidos de amizade"',
    '@"Confirm follow and join": @"Confirmar ações de seguir e entrar"':
        '@"Confirm follow and join": @"Confirmar seguir e entrar"',
    '@"Confirm posting a comment": @"Confirmar publicação do comentário"':
        '@"Confirm posting a comment": @"Confirmar comentário"',
    '@"Hide Reels screen elements": @"Ocultar elementos da tela de Reels"':
        '@"Hide Reels screen elements": @"Ocultar elementos dos Reels"',
    '@"Show Reels screen elements": @"Mostrar elementos da tela de Reels"':
        '@"Show Reels screen elements": @"Mostrar elementos dos Reels"',
    '@"Hide \\\"People You May Know\\\"": @"Ocultar \\\"Pessoas que você talvez conheça\\\""':
        '@"Hide \\\"People You May Know\\\"": @"Ocultar pessoas sugeridas"',
}
for old, new_value in compact_overrides.items():
    if old not in new_body:
        raise RuntimeError(f"missing source translation for compact override: {old}")
    new_body = new_body.replace(old, new_value, 1)

legacy_pattern = re.compile(
    r"(static NSDictionary<NSString \*, NSString \*> \*IQFPortugueseUIStrings\(void\) \{.*?translations = @\{)(.*?)(\n        \};)",
    flags=re.S,
)
legacy_match = legacy_pattern.search(legacy)
if not legacy_match:
    raise RuntimeError("could not locate legacy Nexus translation dictionary")

updated = legacy[:legacy_match.start(2)] + new_body + legacy[legacy_match.end(2):]

# Guard a representative set of iQFace 1.1-only strings and the compact labels
# so the build cannot silently fall back to the previous wording.
required = [
    '@"Block in-stream video ads": @"Bloquear anúncios em vídeos"',
    '@"Hide suggested posts": @"Ocultar publicações sugeridas"',
    '@"Ghost mode in stories": @"Modo fantasma nos stories"',
    '@"Separate buttons": @"Botões separados"',
    '@"Hide creator information": @"Ocultar informações do criador"',
    '@"Confirm sending a message": @"Confirmar envio de mensagens"',
    '@"Confirm friend requests": @"Confirmar pedidos de amizade"',
    '@"Confirm follow and join": @"Confirmar seguir e entrar"',
    '@"Confirm posting a comment": @"Confirmar comentário"',
    '@"Hide Reels screen elements": @"Ocultar elementos dos Reels"',
    '@"Hide \\\"People You May Know\\\"": @"Ocultar pessoas sugeridas"',
]
for marker in required:
    if marker not in updated:
        raise RuntimeError(f"missing iQFace 1.1 translation: {marker}")

legacy_path.write_text(updated, encoding="utf-8")
