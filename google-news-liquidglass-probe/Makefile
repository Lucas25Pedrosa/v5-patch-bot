ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = GoogleNewsLiquidGlassProbe

GoogleNewsLiquidGlassProbe_FILES = Tweak.m
GoogleNewsLiquidGlassProbe_CFLAGS = -fobjc-arc -O2 -Wall -Wextra -Wno-error=deprecated-declarations
GoogleNewsLiquidGlassProbe_FRAMEWORKS = Foundation UIKit CoreFoundation
GoogleNewsLiquidGlassProbe_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
