TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := XLiquidGlassBlurProbe
XLiquidGlassBlurProbe_FILES := XLiquidGlassBlurProbe.m
XLiquidGlassBlurProbe_FRAMEWORKS := Foundation UIKit QuartzCore
XLiquidGlassBlurProbe_CFLAGS := -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
