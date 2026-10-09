from pathlib import Path
import sys
# Keep the source Makefile argument for workflow compatibility, but generate a
# deterministic Nexus library definition so legacy iQFace4in1 names cannot leak.
Path(sys.argv[1]).read_text(encoding='utf-8')
s='''ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = Nexus

Nexus_FILES = IconsTweak.m IconsPicker.m CacheTweak.m AdaptiveBackground.m Nexus2.m NexusAvatarFix.m
Nexus_FRAMEWORKS = Foundation UIKit QuartzCore
Nexus_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-unused-function -Wno-deprecated-declarations
Nexus_LDFLAGS = -Wl,-install_name,@rpath/Nexus.dylib
Nexus_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
'''
Path(sys.argv[2]).write_text(s,encoding='utf-8')
assert 'AdaptiveBackground.m' in s
assert 'OLEDTweak.m' not in s
assert 'FacebookPlusOLED.m' not in s
assert '@rpath/Nexus.dylib' in s
