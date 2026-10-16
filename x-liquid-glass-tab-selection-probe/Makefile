TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := XLiquidGlassTabSelectionProbe
XLiquidGlassTabSelectionProbe_FILES := XLiquidGlassTabSelectionProbe.m
XLiquidGlassTabSelectionProbe_FRAMEWORKS := Foundation UIKit
XLiquidGlassTabSelectionProbe_CFLAGS := -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
