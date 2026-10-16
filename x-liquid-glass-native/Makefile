TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := XLiquidGlassNative
XLiquidGlassNative_FILES := XLiquidGlassNative.m XLiquidGlassDistributionCredits.m XLiquidGlassTabTint.m
XLiquidGlassNative_FRAMEWORKS := Foundation UIKit
XLiquidGlassNative_CFLAGS := -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
