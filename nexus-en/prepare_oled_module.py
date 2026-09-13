from pathlib import Path
import shutil
import subprocess
import sys

root = Path.cwd()
work = Path(sys.argv[1])
shutil.copy2(root / "iqface-oled" / "Tweak.m", work / "Tweak.m")

def run(script):
    subprocess.check_call(["python3", str(script)], cwd=work)

run(root / "iqface-oled-en" / "prepare_oled_en.py")
run(root / "iqface-oled-en" / "prepare_separator_en.py")
subprocess.check_call(["python3", str(root / "nexus-en" / "englishize_oled.py"), str(work / "Tweak.m")])
run(root / "iqface-oled" / "adapt_iqface11.py")
run(root / "iqface-oled" / "adapt_iqface11_native_icon_switches.py")
subprocess.check_call(["python3", str(root / "nexus-en" / "englishize_oled.py"), str(work / "Tweak.m")])
subprocess.check_call(["python3", str(root / "nexus" / "prepare_oled.py"), str(work / "Tweak.m"), str(work / "OLEDTweak.m")])
subprocess.check_call(["python3", str(root / "nexus-en" / "englishize_oled.py"), str(work / "OLEDTweak.m")])
(work / "Tweak.m").unlink()
