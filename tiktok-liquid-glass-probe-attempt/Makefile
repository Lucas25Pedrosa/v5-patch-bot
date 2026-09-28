TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := TikTok

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := TikTokLiquidGlass
TikTokLiquidGlass_FILES := TikTokLiquidGlass.m
TikTokLiquidGlass_FRAMEWORKS := Foundation UIKit
TikTokLiquidGlass_CFLAGS := -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
