from pathlib import Path

path = Path("Tweak.m")
text = path.read_text(encoding="utf-8")


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly 1 match, found {count}")
    text = text.replace(old, new, 1)


# Keep the validated 0.1.7 behavior and only apply the requested 0.2.0 polish.
replace_once(
    "// iQFaceOLED 0.1.7",
    "// iQFaceOLED 0.2.0",
    "version",
)

replace_once(
    '@"Mostrar separadores no feed"',
    '@"Separadores no feed"',
    "short separator toggle title",
)

replace_once(
    "return [UIColor colorWithWhite:1.0 alpha:0.14];",
    "return UIColor.whiteColor;",
    "pure white separator color",
)

text = text.replace(
    "// On true black this renders as a restrained dark-gray divider (~14% white).",
    "// Requested 0.2.0 style: pure white divider on the OLED background.",
)

path.write_text(text, encoding="utf-8")
print("Finalized iQFaceOLED 0.2.0: white divider and shorter Portuguese toggle title")
