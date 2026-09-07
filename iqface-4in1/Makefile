ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = iQFace4in1

iQFace4in1_FILES = EnhancerTweak.m EnhancerPicker.m IconsTweak.m IconsPicker.m CacheTweak.m OLEDTweak.m
iQFace4in1_FRAMEWORKS = Foundation UIKit QuartzCore
iQFace4in1_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
iQFace4in1_LDFLAGS = -Wl,-install_name,@rpath/iQFace4in1.dylib
iQFace4in1_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
