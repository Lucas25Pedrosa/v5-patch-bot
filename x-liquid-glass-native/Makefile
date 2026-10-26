TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := GlassX
GlassX_FILES := XLiquidGlassUI.m XLiquidGlass1238Engine.m XLiquidGlassDistributionCredits.m XLiquidGlassTabTint.m
GlassX_FRAMEWORKS := Foundation UIKit
GlassX_CFLAGS := -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter -DXLiquidGlassSettingsViewController=XLiquidGlassNativeSettingsViewController

include $(THEOS_MAKE_PATH)/tweak.mk
