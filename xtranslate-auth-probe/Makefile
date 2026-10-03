TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := XTranslateAuthProbe
XTranslateAuthProbe_FILES := XTranslateAuthProbe.m
XTranslateAuthProbe_FRAMEWORKS := Foundation UIKit
XTranslateAuthProbe_CFLAGS := -fobjc-arc -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk

# CI PR trigger Grok Private Bridge Fix 0.12 Beta 1
