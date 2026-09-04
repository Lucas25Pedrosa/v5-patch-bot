ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = FacebookWordmarkProbe

FacebookWordmarkProbe_FILES = Tweak.m
FacebookWordmarkProbe_FRAMEWORKS = Foundation UIKit
FacebookWordmarkProbe_CFLAGS = -fobjc-arc -Wall -Wextra
FacebookWordmarkProbe_LDFLAGS = -Wl,-install_name,@rpath/FacebookWordmarkProbe.dylib
FacebookWordmarkProbe_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
