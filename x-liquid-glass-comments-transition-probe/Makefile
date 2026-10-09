ARCHS = arm64
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XLiquidGlassCommentsTransitionProbe
XLiquidGlassCommentsTransitionProbe_FILES = XLiquidGlassCommentsTransitionProbe.m
XLiquidGlassCommentsTransitionProbe_FRAMEWORKS = Foundation UIKit QuartzCore
XLiquidGlassCommentsTransitionProbe_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-unused-function

# Transition-focused diagnostic build 0.6
include $(THEOS_MAKE_PATH)/tweak.mk
