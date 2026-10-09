TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := XLiquidGlassCommentsEffectProbe
XLiquidGlassCommentsEffectProbe_FILES := XLiquidGlassCommentsEffectProbe.m
XLiquidGlassCommentsEffectProbe_FRAMEWORKS := Foundation UIKit QuartzCore
XLiquidGlassCommentsEffectProbe_CFLAGS := -fobjc-arc -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
