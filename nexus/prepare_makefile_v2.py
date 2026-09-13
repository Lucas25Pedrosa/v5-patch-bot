from pathlib import Path
import shutil
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
s = src.read_text(encoding="utf-8")

avatar_src = Path(__file__).with_name("NexusAvatarFix.m")
avatar_dst = out.parent / "NexusAvatarFix.m"
shutil.copyfile(avatar_src, avatar_dst)

version_src = Path(__file__).with_name("NexusVersion102.m")
version_dst = out.parent / "NexusVersion102.m"
shutil.copyfile(version_src, version_dst)

s = s.replace("LIBRARY_NAME = iQFace4in1", "LIBRARY_NAME = Nexus")
s = s.replace(
    "iQFace4in1_FILES = EnhancerTweak.m EnhancerPicker.m IconsTweak.m IconsPicker.m CacheTweak.m OLEDTweak.m",
    "Nexus_FILES = EnhancerTweak.m WordmarkActivation.m Translation.m HideButton11.m IconsTweak.m IconsPicker.m CacheTweak.m OLEDTweak.m NexusSettings.m NexusAvatarFix.m NexusVersion102.m",
)
s = s.replace("iQFace4in1_FRAMEWORKS", "Nexus_FRAMEWORKS")
s = s.replace("iQFace4in1_CFLAGS", "Nexus_CFLAGS")
s = s.replace("iQFace4in1_LDFLAGS", "Nexus_LDFLAGS")
s = s.replace("iQFace4in1_INSTALL_PATH", "Nexus_INSTALL_PATH")
s = s.replace("@rpath/iQFace4in1.dylib", "@rpath/Nexus.dylib")
s = s.replace(
    "-Wno-deprecated-declarations",
    "-Wno-deprecated-declarations -Wno-error=sign-compare -Wno-error=unused-function",
    1,
)

assert "LIBRARY_NAME = Nexus" in s
assert "NexusSettings.m" in s
assert "NexusAvatarFix.m" in s
assert "NexusVersion102.m" in s
assert avatar_dst.exists()
assert version_dst.exists()
assert "@rpath/Nexus.dylib" in s
assert "-Wno-error=sign-compare" in s
assert "-Wno-error=unused-function" in s
out.write_text(s, encoding="utf-8")
