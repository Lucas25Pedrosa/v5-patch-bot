ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = XLoginProbe
XLoginProbe_FILES = XLoginProbe.m
XLoginProbe_FRAMEWORKS = Foundation UIKit
XLoginProbe_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
XLoginProbe_LDFLAGS = -Wl,-install_name,@rpath/XLoginProbe.dylib
XLoginProbe_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
