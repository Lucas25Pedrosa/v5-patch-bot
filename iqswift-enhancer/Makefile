ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = iQSwiftEnhancer

iQSwiftEnhancer_FILES = Tweak.m
iQSwiftEnhancer_FRAMEWORKS = Foundation UIKit
iQSwiftEnhancer_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-deprecated-declarations
iQSwiftEnhancer_LDFLAGS = -Wl,-install_name,@rpath/iQSwiftEnhancer.dylib
iQSwiftEnhancer_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
