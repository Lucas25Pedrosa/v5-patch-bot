ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = VitrineCompatibilityFix

VitrineCompatibilityFix_FILES = Tweak.m
VitrineCompatibilityFix_FRAMEWORKS = Foundation UIKit
VitrineCompatibilityFix_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
VitrineCompatibilityFix_LDFLAGS = -Wl,-install_name,@rpath/VitrineCompatibilityFix.dylib
VitrineCompatibilityFix_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
