ARCHS = arm64
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XLiquidGlassCommentsXColorProbe
XLiquidGlassCommentsXColorProbe_FILES = XLiquidGlassCommentsXColorProbe.m
XLiquidGlassCommentsXColorProbe_FRAMEWORKS = Foundation UIKit QuartzCore
XLiquidGlassCommentsXColorProbe_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
