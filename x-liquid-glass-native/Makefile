TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := XLiquidGlassB1X1238
XLiquidGlassB1X1238_FILES := XLiquidGlassUI.m XLiquidGlass1238Engine.m XLiquidGlassDistributionCredits.m XLiquidGlassTabTint.m
XLiquidGlassB1X1238_FRAMEWORKS := Foundation UIKit
XLiquidGlassB1X1238_CFLAGS := -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
