TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := TeraBox

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := TeraBoxStorageDiagnostic
TeraBoxStorageDiagnostic_FILES := TeraBoxStorageDiagnostic.m
TeraBoxStorageDiagnostic_FRAMEWORKS := Foundation UIKit
TeraBoxStorageDiagnostic_CFLAGS := -fobjc-arc -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
