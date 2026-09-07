ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = iQFaceToggleProbe

iQFaceToggleProbe_FILES = ToggleProbe.m
iQFaceToggleProbe_FRAMEWORKS = Foundation UIKit
iQFaceToggleProbe_CFLAGS = -fobjc-arc -Wall -Wextra -Werror
iQFaceToggleProbe_LDFLAGS = -Wl,-install_name,@rpath/iQFaceToggleProbe.dylib
iQFaceToggleProbe_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
