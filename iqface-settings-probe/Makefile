ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = iQFaceSettingsProbe

iQFaceSettingsProbe_FILES = Probe.m IconPicker.m
iQFaceSettingsProbe_FRAMEWORKS = Foundation UIKit QuartzCore
iQFaceSettingsProbe_CFLAGS = -fobjc-arc -Wall -Wextra
iQFaceSettingsProbe_LDFLAGS = -Wl,-install_name,@rpath/iQFaceSettingsProbe.dylib
iQFaceSettingsProbe_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
