from pathlib import Path
import shutil
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
s = src.read_text(encoding="utf-8")

root = Path(__file__).resolve().parents[1]
avatar_src = root / "nexus" / "NexusAvatarFix.m"
avatar_dst = out.parent / "NexusAvatarFix.m"
shutil.copyfile(avatar_src, avatar_dst)

s = s.replace("LIBRARY_NAME = iQFace4in1", "LIBRARY_NAME = Nexus")
s = s.replace(
    "iQFace4in1_FILES = EnhancerTweak.m EnhancerPicker.m IconsTweak.m IconsPicker.m CacheTweak.m OLEDTweak.m",
    "Nexus_FILES = EnhancerTweak.m WordmarkActivation.m IconsTweak.m IconsPicker.m CacheTweak.m OLEDTweak.m NexusSettings.m NexusAvatarFix.m",
)
s = s.replace("iQFace4in1_FRAMEWORKS", "Nexus_FRAMEWORKS")
s = s.replace("iQFace4in1_CFLAGS", "Nexus_CFLAGS")
s = s.replace("iQFace4in1_LDFLAGS", "Nexus_LDFLAGS")
s = s.replace("iQFace4in1_INSTALL_PATH", "Nexus_INSTALL_PATH")
s = s.replace("@rpath/iQFace4in1.dylib", "@rpath/Nexus.dylib")
s = s.replace("-Wno-deprecated-declarations", "-Wno-deprecated-declarations -Wno-error=sign-compare -Wno-error=unused-function", 1)

assert "HideButton11.m" not in s
assert "Translation.m" not in s
assert "NexusAvatarFix.m" in s
assert avatar_dst.exists()
out.write_text(s, encoding="utf-8")
