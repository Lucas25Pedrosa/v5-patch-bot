ARCHS = arm64
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XLiquidGlassCommentsDirectionProbe
XLiquidGlassCommentsDirectionProbe_FILES = XLiquidGlassCommentsDirectionProbe.m
XLiquidGlassCommentsDirectionProbe_FRAMEWORKS = Foundation UIKit QuartzCore
XLiquidGlassCommentsDirectionProbe_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-unused-function

include $(THEOS_MAKE_PATH)/tweak.mk
