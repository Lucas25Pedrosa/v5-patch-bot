TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := XLiquidGlassMultiAccountProbe
XLiquidGlassMultiAccountProbe_FILES := XLiquidGlassMultiAccountProbe.m
XLiquidGlassMultiAccountProbe_FRAMEWORKS := Foundation UIKit QuartzCore
XLiquidGlassMultiAccountProbe_CFLAGS := -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
