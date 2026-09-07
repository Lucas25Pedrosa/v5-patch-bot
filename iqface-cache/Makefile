ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = iQFaceCache

iQFaceCache_FILES = Tweak.m
iQFaceCache_FRAMEWORKS = Foundation UIKit
iQFaceCache_CFLAGS = -fobjc-arc -Wall -Wextra
iQFaceCache_LDFLAGS = -Wl,-install_name,@rpath/iQFaceCache.dylib
iQFaceCache_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
