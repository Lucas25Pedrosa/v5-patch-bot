ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = iQFaceOLED

iQFaceOLED_FILES = Tweak.m OLEDPicker.m
iQFaceOLED_FRAMEWORKS = Foundation UIKit QuartzCore
iQFaceOLED_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
iQFaceOLED_LDFLAGS = -Wl,-install_name,@rpath/iQFaceOLED.dylib
iQFaceOLED_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
