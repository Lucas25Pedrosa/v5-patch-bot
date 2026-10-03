TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := XLiquidGlassGrokHide
XLiquidGlassGrokHide_FILES := XLiquidGlassGrokHide.m
XLiquidGlassGrokHide_FRAMEWORKS := Foundation UIKit
XLiquidGlassGrokHide_CFLAGS := -fobjc-arc -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
