TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := XTranslateProbe
XTranslateProbe_FILES := XTranslateProbe.m
XTranslateProbe_FRAMEWORKS := Foundation UIKit
XTranslateProbe_CFLAGS := -fobjc-arc -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
