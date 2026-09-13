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

legacy_pattern = re.compile(
    r"(static NSDictionary<NSString \*, NSString \*> \*IQFPortugueseUIStrings\(void\) \{.*?translations = @\{)(.*?)(\n        \};)",
    flags=re.S,
)
legacy_match = legacy_pattern.search(legacy)
if not legacy_match:
    raise RuntimeError("could not locate legacy Nexus translation dictionary")

updated = legacy[:legacy_match.start(2)] + new_body + legacy[legacy_match.end(2):]

# Guard a representative set of iQFace 1.1-only strings so we cannot silently
# fall back to the older 1.0 translation table again.
required = [
    '@"Block in-stream video ads": @"Bloquear anúncios em vídeos"',
    '@"Hide suggested posts": @"Ocultar publicações sugeridas"',
    '@"Ghost mode in stories": @"Modo fantasma nos stories"',
    '@"Separate buttons": @"Botões separados"',
    '@"Hide creator information": @"Ocultar informações do criador"',
    '@"Confirm sending a message": @"Confirmar envio de mensagens"',
]
for marker in required:
    if marker not in updated:
        raise RuntimeError(f"missing iQFace 1.1 translation: {marker}")

legacy_path.write_text(updated, encoding="utf-8")
