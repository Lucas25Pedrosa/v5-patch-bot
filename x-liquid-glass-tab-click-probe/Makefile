TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := XLiquidGlassTabClickProbe
XLiquidGlassTabClickProbe_FILES := XLiquidGlassTabClickProbe.m
XLiquidGlassTabClickProbe_FRAMEWORKS := Foundation UIKit QuartzCore
XLiquidGlassTabClickProbe_CFLAGS := -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
