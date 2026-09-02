TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Facebook

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := FBOLEDSafeDiagnostic
FBOLEDSafeDiagnostic_FILES := FBOLEDDiagnosticSafe.m
FBOLEDSafeDiagnostic_FRAMEWORKS := Foundation UIKit
FBOLEDSafeDiagnostic_CFLAGS := -fobjc-arc -Wall -Wextra -Wno-unused-parameter
FBOLEDSafeDiagnostic_LDFLAGS := -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
