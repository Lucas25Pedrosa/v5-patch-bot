TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := GlassXDE
GlassXDE_FILES := XLiquidGlassUI.m XLiquidGlass1238Engine.m XLiquidGlassDistributionCredits.m
GlassXDE_FRAMEWORKS := Foundation UIKit
GlassXDE_CFLAGS := -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter -DXLiquidGlassSettingsViewController=XLiquidGlassNativeSettingsViewController
GlassXDE_LDFLAGS += -Wl,-install_name,/Library/MobileSubstrate/DynamicLibraries/GlassXDE.dylib

include $(THEOS_MAKE_PATH)/tweak.mk
