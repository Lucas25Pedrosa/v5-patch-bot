from pathlib import Path
import shutil
import subprocess
import sys

root = Path.cwd()
work = Path(sys.argv[1])
oled_source = Path(sys.argv[2])

subprocess.check_call([
    "python3", str(root / "nexus-en" / "prepare_oled.py"),
    str(oled_source), str(work / "OLEDTweak.m")
])

shutil.copy2(root / "nexus" / "NexusSettings.m", work / "NexusSettings.m")
subprocess.check_call([
    "python3", str(root / "nexus" / "patch_presentation_v2.py"),
    str(work / "NexusSettings.m")
])
subprocess.check_call([
    "python3", str(root / "nexus-en" / "patch_settings.py"),
    str(work / "NexusSettings.m")
])
subprocess.check_call([
    "python3", str(root / "nexus-en" / "prepare_makefile.py"),
    str(root / "iqface-4in1" / "Makefile"), str(work / "Makefile")
])

makefile = (work / "Makefile").read_text(encoding="utf-8")
if "Translation.m" in makefile:
    raise SystemExit("English Nexus must not include Translation.m")

required = {
    work / "OLEDTweak.m": ["OLED Mode", "Feed separators"],
    work / "IconsTweak.m": ["IPA Vault", "Exclusive Nexus Distributor"],
    work / "CacheTweak.m": ["Clear cache", "Clear cache automatically"],
    work / "NexusSettings.m": ["Nexus Developer", "NexusIconsCreateIPAVaultSetting"],
}
for path, markers in required.items():
    text = path.read_text(encoding="utf-8")
    for marker in markers:
        if marker not in text:
            raise SystemExit(f"Missing {marker} in {path.name}")
