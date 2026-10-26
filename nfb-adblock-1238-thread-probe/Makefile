TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := NFBAdBlock1238ThreadProbe
NFBAdBlock1238ThreadProbe_FILES := NFBAdBlock1238ThreadProbe.m
NFBAdBlock1238ThreadProbe_FRAMEWORKS := Foundation UIKit
NFBAdBlock1238ThreadProbe_CFLAGS := -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
