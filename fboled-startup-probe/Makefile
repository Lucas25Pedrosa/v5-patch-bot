TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Facebook

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := NexusOLEDStartupProbe
NexusOLEDStartupProbe_FILES := NexusOLEDStartupProbe.m
NexusOLEDStartupProbe_FRAMEWORKS := Foundation UIKit QuartzCore
NexusOLEDStartupProbe_CFLAGS := -fobjc-arc -Wall -Wextra -Wno-unused-parameter
NexusOLEDStartupProbe_LDFLAGS := -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
