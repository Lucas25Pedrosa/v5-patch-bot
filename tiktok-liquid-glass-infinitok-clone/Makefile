TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := TikTok

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := TikTokLiquidGlassInfinitok
TikTokLiquidGlassInfinitok_FILES := TikTokLiquidGlassInfinitok.m
TikTokLiquidGlassInfinitok_FRAMEWORKS := Foundation UIKit
TikTokLiquidGlassInfinitok_CFLAGS := -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
