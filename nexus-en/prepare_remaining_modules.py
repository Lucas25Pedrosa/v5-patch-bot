from pathlib import Path
import shutil
import subprocess
import sys

root = Path.cwd()
work = Path(sys.argv[1])

subprocess.check_call(["python3", str(root / "nexus-en" / "prepare_oled_module.py"), str(work)])
shutil.copy2(root / "nexus" / "NexusSettings.m", work / "NexusSettings.m")
subprocess.check_call(["python3", str(root / "nexus" / "patch_presentation_v2.py"), str(work / "NexusSettings.m")])
subprocess.check_call(["python3", str(root / "nexus-en" / "patch_settings.py"), str(work / "NexusSettings.m")])
subprocess.check_call(["python3", str(root / "nexus-en" / "prepare_makefile.py"), str(root / "iqface-4in1" / "Makefile"), str(work / "Makefile")])

if "Translation.m" in (work / "Makefile").read_text(encoding="utf-8"):
    raise SystemExit("English Nexus must not include Translation.m")
