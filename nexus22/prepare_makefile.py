from pathlib import Path
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
s = src.read_text(encoding="utf-8")
s = s.replace("LIBRARY_NAME = iQFace4in1", "LIBRARY_NAME = Nexus")
s = s.replace(
    "iQFace4in1_FILES = EnhancerTweak.m EnhancerPicker.m IconsTweak.m IconsPicker.m CacheTweak.m OLEDTweak.m",
    "Nexus_FILES = IconsTweak.m IconsPicker.m CacheTweak.m FacebookPlusOLED.m Nexus2.m NexusAvatarFix.m",
)
s = s.replace("iQFace4in1_FRAMEWORKS", "Nexus_FRAMEWORKS")
s = s.replace("iQFace4in1_CFLAGS", "Nexus_CFLAGS")
s = s.replace("iQFace4in1_LDFLAGS", "Nexus_LDFLAGS")
s = s.replace("iQFace4in1_INSTALL_PATH", "Nexus_INSTALL_PATH")
s = s.replace("@rpath/iQFace4in1.dylib", "@rpath/Nexus.dylib")
s = s.replace("-Wno-deprecated-declarations", "-Wno-deprecated-declarations -Wno-error=sign-compare -Wno-error=unused-function -Wno-error=deprecated-declarations", 1)
for marker in ["FacebookPlusOLED.m", "Nexus2.m", "NexusAvatarFix.m", "@rpath/Nexus.dylib"]:
    assert marker in s
assert "OLEDTweak.m" not in s
assert "EnhancerTweak.m" not in s
out.write_text(s, encoding="utf-8")
print("Prepared Nexus 2.2 Beta 1 Makefile")
