ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = NexusLiquidGlassProbe

NexusLiquidGlassProbe_FILES = Tweak.m
NexusLiquidGlassProbe_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-error=deprecated-declarations
NexusLiquidGlassProbe_FRAMEWORKS = Foundation UIKit

NexusLiquidGlassProbe_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
