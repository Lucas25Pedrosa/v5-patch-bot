TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := XLiquidGlassCommentsProbe
XLiquidGlassCommentsProbe_FILES := XLiquidGlassCommentsProbe.m
XLiquidGlassCommentsProbe_FRAMEWORKS := Foundation UIKit QuartzCore
XLiquidGlassCommentsProbe_CFLAGS := -fno-objc-arc -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
