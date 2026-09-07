TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Facebook

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := FBCacheCleaner
FBCacheCleaner_FILES := FBCacheCleaner.m
FBCacheCleaner_FRAMEWORKS := Foundation UIKit
FBCacheCleaner_CFLAGS := -fobjc-arc -Wall -Wextra -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
