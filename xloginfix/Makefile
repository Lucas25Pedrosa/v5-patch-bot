TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES := Twitter

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := XLoginFix
XLoginFix_FILES := XLoginFix.m
XLoginFix_FRAMEWORKS := Foundation UIKit WebKit
XLoginFix_CFLAGS := -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
