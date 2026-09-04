ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = iQFaceEnhancer

iQFaceEnhancer_FILES = Tweak.m
iQFaceEnhancer_FRAMEWORKS = Foundation UIKit
iQFaceEnhancer_CFLAGS = -fobjc-arc -Wall -Wextra
iQFaceEnhancer_LDFLAGS = -Wl,-install_name,@rpath/iQFaceEnhancer.dylib
iQFaceEnhancer_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
