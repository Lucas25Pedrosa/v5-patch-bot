TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Facebook

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := FBOLEDViewMapper
FBOLEDViewMapper_FILES := FBOLEDViewMapper.m
FBOLEDViewMapper_FRAMEWORKS := Foundation UIKit QuartzCore
FBOLEDViewMapper_CFLAGS := -fobjc-arc -Wall -Wextra -Wno-unused-parameter
FBOLEDViewMapper_LDFLAGS := -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
