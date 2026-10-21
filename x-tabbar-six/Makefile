ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = XTabBarSix
XTabBarSix_FILES = Tweak.m
XTabBarSix_FRAMEWORKS = Foundation UIKit
XTabBarSix_CFLAGS = -fobjc-arc -Wall -Wextra
XTabBarSix_LDFLAGS = -Wl,-install_name,@rpath/XTabBarSix.dylib

include $(THEOS_MAKE_PATH)/library.mk
