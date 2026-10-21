ARCHS = arm64
TARGET = iphone:clang:latest:15.0
include $(THEOS)/makefiles/common.mk
LIBRARY_NAME = XTabBarCapacityProbe
XTabBarCapacityProbe_FILES = Probe.m
XTabBarCapacityProbe_FRAMEWORKS = Foundation UIKit
XTabBarCapacityProbe_CFLAGS = -fobjc-arc -Wall -Wextra
XTabBarCapacityProbe_LDFLAGS = -Wl,-install_name,@rpath/XTabBarCapacityProbe.dylib
include $(THEOS_MAKE_PATH)/library.mk
