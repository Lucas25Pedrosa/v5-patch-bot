ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = FacebookWordmarkLauncherBeta

FacebookWordmarkLauncherBeta_FILES = Tweak.m
FacebookWordmarkLauncherBeta_FRAMEWORKS = Foundation UIKit
FacebookWordmarkLauncherBeta_CFLAGS = -fobjc-arc -Wall -Wextra
FacebookWordmarkLauncherBeta_LDFLAGS = -Wl,-install_name,@rpath/FacebookWordmarkLauncherBeta.dylib
FacebookWordmarkLauncherBeta_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
