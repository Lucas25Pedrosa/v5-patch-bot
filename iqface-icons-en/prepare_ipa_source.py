from pathlib import Path

path = Path("Tweak.m")
text = path.read_text(encoding="utf-8")

old = 'IPA Souce'
new = 'IPA Source'
count = text.count(old)
if count != 2:
    raise SystemExit(f"expected exactly 2 occurrences of {old!r}, found {count}")

path.write_text(text.replace(old, new), encoding="utf-8")
print("Corrected IPA Vault credit to IPA Source")
