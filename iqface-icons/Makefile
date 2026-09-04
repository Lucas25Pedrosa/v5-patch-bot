ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = iQFaceIcons

iQFaceIcons_FILES = Tweak.m IconPicker.m
iQFaceIcons_FRAMEWORKS = Foundation UIKit QuartzCore
iQFaceIcons_CFLAGS = -fobjc-arc -Wall -Wextra
iQFaceIcons_LDFLAGS = -Wl,-install_name,@rpath/iQFaceIcons.dylib
iQFaceIcons_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
