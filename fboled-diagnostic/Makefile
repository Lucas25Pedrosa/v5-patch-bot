TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Facebook

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := FBOLEDDiagnostic
FBOLEDDiagnostic_FILES := FBOLEDDiagnostic.mm
FBOLEDDiagnostic_FRAMEWORKS := Foundation UIKit
FBOLEDDiagnostic_CFLAGS := -fobjc-arc -Wall -Wextra -Wno-unused-parameter
FBOLEDDiagnostic_LDFLAGS := -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
